const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const imgui = @import("imgui");
const mailbox = @import("mailbox");
const math = @import("math");
const renderite = @import("renderite");
const SharedMemoryAccessor = renderite.SharedMemoryAccessor;
const InitSettings = renderite.InitSettings;
const sdl3 = @import("sdl3");
const tracy = @import("tracy");
const xr_t = @import("xr");

const Assets = @import("Assets.zig");
const graphics = @import("graphics.zig");
const Input = @import("Input.zig");
const Texture = @import("Texture.zig");

pub const MessagingHost = renderite.MessagingHost(*App);
const log = std.log.scoped(.app);

const App = @This();

const XrData = struct {
    backend: *xr_t.Backend,

    pub fn deinit(self: XrData, gpa: std.mem.Allocator) void {
        self.backend.deinit(gpa);
    }
};

pub const FenceManager = graphics.FenceManager(&.{Assets.TextureReadyFenceHandler});

const GraphicsData = struct {
    device: gpu.Device,
    sampler_supported_formats: std.enums.EnumSet(renderite.Shared.TextureFormat),
    cubemap_supported_formats: std.enums.EnumSet(renderite.Shared.TextureFormat),

    primary_transfer_buffer_pool: graphics.TransferBufferPool,
    background_transfer_buffer_pool: graphics.TransferBufferPool,

    fence_manager: FenceManager,

    pub fn deinit(self: *GraphicsData, gpa: std.mem.Allocator) void {
        self.fence_manager.deinit(gpa);

        self.primary_transfer_buffer_pool.deinit(gpa);
        self.background_transfer_buffer_pool.deinit(gpa);

        self.device.deinit();
    }
};

const WindowData = struct {
    window: sdl3.video.Window,
    swapchain_format: gpu.TextureFormat,

    fullscreen: bool,
    focus: bool,

    pub fn deinit(self: WindowData) void {
        self.window.deinit();
    }
};

pub const ToRenderMailbox = mailbox.MailBox(ToRenderLetter);

pub const ToRenderLetter = union(enum) {
    renderer_command: struct {
        command: renderite.ParsedCommand,
        queue_type: MessagingHost.QueueManager.Type,
    },
    handle_output_state: renderite.Shared.OutputState,
};

pub const ToEngineMailbox = mailbox.MailBox(ToEngineLetter);

pub const ToEngineLetter = union(enum) {
    renderer_command: renderite.ParsedCommand,
};

const MessagingData = struct {
    host: MessagingHost,
    accessor: ?SharedMemoryAccessor,
    shmem_prefix: std.BoundedArray(u8, 128),

    to_render: ToRenderMailbox,
    to_render_envelope_pool: std.heap.MemoryPool(ToRenderMailbox.Envelope),

    letter_allocation_mutex: std.Thread.Mutex,

    pub fn deinit(self: *MessagingData, gpa: std.mem.Allocator) void {
        self.host.primary.send(.{ .RendererShutdownRequest = .{} }) catch {};
        self.host.deinit();

        if (self.accessor) |*accessor| accessor.deinit(gpa);

        var envelopes = self.to_render.close();
        while (envelopes) |envelope| {
            switch (envelope.letter) {
                .renderer_command => |renderer_command| {
                    renderer_command.command.arena.deinit();
                },
                .handle_output_state => {},
            }

            envelopes = envelope.next;
        }

        self.to_render_envelope_pool.deinit();

        log.debug("messaging data deinit", .{});
    }
};

const ImGuiData = struct {
    context: imgui.Context,

    assets_open: bool,
    loadstate_open: bool,

    pub fn deinit(self: ImGuiData) void {
        imgui.gpu.shutdown();
        imgui.sdl3.shutdown();
        self.context.destroy();
    }
};

// TODO: warn when we need to update this (when this differs on full load)
const total_load_phases = 25;

const LoadPhase = struct {
    phase_index: u8,
    phase_name: std.BoundedArray(u8, 128),
    sub_phase_name: std.BoundedArray(u8, 128),
};

const LoadState = struct {
    phase: LoadPhase,
    init: bool,
    full_init: bool,
};

const GameData = struct {
    run_loop: bool,
    exiting: bool,
    head_output_device: renderite.Shared.HeadOutputDevice,
    main_process_pid: ?i32,
    load_state: LoadState,
    last_frame_index: i32,
    engine_thread: ?std.Thread,
    engine_thread_cancellation: std.Thread.ResetEvent,
    engine_thread_ready_for_begin_frame: std.Thread.ResetEvent,
    to_engine_mailbox: ToEngineMailbox,
    to_engine_envelope_pool: std.heap.MemoryPool(ToEngineMailbox.Envelope),

    displays: std.ArrayListUnmanaged(renderite.Shared.DisplayState),

    held_keys: std.ArrayListUnmanaged(renderite.Shared.Key),
    type_delta: std.ArrayListUnmanaged(u16),

    pub fn deinit(self: *GameData, gpa: std.mem.Allocator) void {
        if (self.engine_thread) |engine_thread| {
            self.engine_thread_cancellation.set();

            engine_thread.join();
        }

        self.to_engine_envelope_pool.deinit();

        self.displays.deinit(gpa);
        self.held_keys.deinit(gpa);
    }
};

gpa: std.mem.Allocator,

game: GameData,
xr: ?XrData,
graphics_data: GraphicsData,
window: WindowData,
messaging: MessagingData,
imgui_data: ?ImGuiData,
assets: Assets,

pub fn init(gpa: std.mem.Allocator, settings: InitSettings) !*App {
    const app = try gpa.create(App);
    errdefer gpa.destroy(app);

    const messaging_data: MessagingData = create_messaging_data: {
        const host = MessagingHost.init(settings.queue_name.constSlice(), settings.queue_length, messagingCallback, app) catch |err| debug_queue: {
            log.warn("Failed to initialize messaging manager from command line arguments: {s}, setting up dummy queue", .{@errorName(err)});
            break :debug_queue try MessagingHost.init("gloopie", 8388608, messagingCallback, app);
        };
        errdefer host.deinit();

        break :create_messaging_data .{
            .host = host,
            .accessor = null,
            .shmem_prefix = .{},
            .to_render = .{},
            .to_render_envelope_pool = .init(gpa),
            .letter_allocation_mutex = .{},
        };
    };

    const xr_data: ?XrData = create_xr_data: {
        const xr_backend: ?*xr_t.Backend = xr_t.init(gpa) catch |err| backend_create_fail: {
            log.err("Got error {s} when trying to initialize XR backend.", .{@errorName(err)});

            break :backend_create_fail null;
        };
        errdefer if (xr_backend) |backend| backend.deinit(gpa);

        if (xr_backend) |_| {
            log.info("Initialized XR backend {s}", .{xr_t.name});
        } else {
            log.warn("Failed to initialize XR backend {s}, will be starting in desktop-only mode. Restart will be required to begin a VR session.", .{xr_t.name});
        }

        break :create_xr_data if (xr_backend) |backend| .{ .backend = backend } else null;
    };
    errdefer if (xr_data) |xr| xr.deinit(gpa);

    var window_data: WindowData = create_window_data: {
        const window_ret = try sdl3.video.Window.initWithProperties(.{
            .width = 1600,
            .height = 900,
            // TODO: only enable this when using the vulkan backend
            .vulkan = true,
            .title = "gloobie",
        });
        const window, const properties = .{ window_ret.window, window_ret.properties };
        properties.deinit();
        errdefer window.deinit();

        break :create_window_data .{
            .window = window,
            .swapchain_format = undefined,
            .fullscreen = false,
            .focus = false,
        };
    };
    errdefer window_data.deinit();

    var graphics_data: GraphicsData = create_graphics_data: {
        const gpu_device = if (xr_data) |xr| xr.backend.getGpuDevice() else try gpu.Device.initWithProperties(.{
            .debug_mode = build_options.safety,
            // TODO: Once we get the ability to transpile to other shader types, specify them here!
            .shaders_spirv = true,
        });
        errdefer if (xr_data == null) gpu_device.deinit();

        var sampler_supported_formats: std.EnumSet(renderite.Shared.TextureFormat) = .initEmpty();
        var cubemap_supported_formats: std.EnumSet(renderite.Shared.TextureFormat) = .initEmpty();
        for (std.enums.values(renderite.Shared.TextureFormat)) |renderite_format| {
            const srgb_gpu_format = Texture.renderiteFormatToGpuFormat(renderite_format, .sRGB) orelse continue;
            const linear_gpu_format = Texture.renderiteFormatToGpuFormat(renderite_format, .Linear) orelse continue;

            if (gpu_device.textureSupportsFormat(
                srgb_gpu_format,
                .two_dimensional,
                .{ .sampler = true },
            ) and gpu_device.textureSupportsFormat(
                linear_gpu_format,
                .two_dimensional,
                .{ .sampler = true },
            )) {
                sampler_supported_formats.insert(renderite_format);
                log.debug("GPU supports {s}/{s} for samplers", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
            } else {
                log.debug("GPU does not support {s}/{s} for samplers", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
            }

            if (gpu_device.textureSupportsFormat(
                srgb_gpu_format,
                .cube,
                .{ .sampler = true },
            ) and gpu_device.textureSupportsFormat(
                linear_gpu_format,
                .cube,
                .{ .sampler = true },
            )) {
                cubemap_supported_formats.insert(renderite_format);
                log.debug("GPU supports {s}/{s} for cubemaps", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
            } else {
                log.debug("GPU does not support {s}/{s} for cubemaps", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
            }
        }

        // SAFETY: this call never fails if we pass a valid GPU device handle, which we should always have
        log.info("Acquired OpenXR GPU device with driver {s}", .{gpu_device.getDriver() catch unreachable});

        break :create_graphics_data .{
            .device = gpu_device,
            .sampler_supported_formats = sampler_supported_formats,
            .cubemap_supported_formats = cubemap_supported_formats,
            .primary_transfer_buffer_pool = .init(gpu_device),
            .background_transfer_buffer_pool = .init(gpu_device),
            .fence_manager = .init(gpu_device),
        };
    };
    errdefer graphics_data.deinit(gpa);

    try graphics_data.device.claimWindow(window_data.window);

    const composition_mode: gpu.SwapchainComposition = .sdr_linear;
    const present_mode_preference: []const gpu.PresentMode = &.{
        .mailbox,
        .immediate,
        .vsync,
    };

    if (!graphics_data.device.windowSupportsSwapchainComposition(window_data.window, composition_mode)) {
        log.err("Window does not support the composition mode ({s}) we want. Cannot continue.", .{@tagName(composition_mode)});
        return error.UnsupportCompositionMode;
    }

    for (present_mode_preference) |present_mode| {
        if (graphics_data.device.windowSupportsPresentMode(window_data.window, present_mode)) {
            try graphics_data.device.setSwapchainParameters(window_data.window, composition_mode, present_mode);

            break;
        }
    } else {
        log.err("Window supports none of our wanted present modes. VR performance may be impacted strongly.", .{});
    }

    window_data.swapchain_format = graphics_data.device.getSwapchainTextureFormat(window_data.window);

    log.debug("Using window swapchain format {s}", .{@tagName(window_data.swapchain_format)});

    // TODO: make ImGui an optional build dependency
    const maybe_imgui_data: ?ImGuiData = create_imgui_data: {
        const context = try imgui.Context.create(null);
        errdefer context.destroy();

        context.setCurrent();

        const style = imgui.getStyle();
        // Go through every colour and convert it to linear
        // This is because ImGui uses linear colours but we are using sRGB
        // This is a simple approximation of the conversion
        for (0..imgui.c.ImGuiCol_COUNT) |i| {
            const col = &style.Colors[i];
            col.x = math.srgbToLinear(f32, col.x);
            col.y = math.srgbToLinear(f32, col.y);
            col.z = math.srgbToLinear(f32, col.z);
        }

        try imgui.sdl3.initForOther(window_data.window);
        errdefer imgui.sdl3.shutdown();

        log.info("Initialized ImGui SDL3 backend", .{});

        try imgui.gpu.init(.{
            .color_target_format = window_data.swapchain_format,
            .device = graphics_data.device,
            .msaa_samples = .no_multisampling,
        });
        errdefer imgui.gpu.shutdown();

        log.info("Initialized ImGui GPU backend", .{});

        break :create_imgui_data .{
            .context = context,
            .assets_open = true,
            .loadstate_open = true,
        };
    };
    errdefer if (maybe_imgui_data) |imgui_data| imgui_data.deinit();

    const game_data = create_game_data: {
        const held_keys: std.ArrayListUnmanaged(renderite.Shared.Key) = try .initCapacity(gpa, std.enums.values(renderite.Shared.Key).len);
        errdefer gpa.free(held_keys);

        var game_data: GameData = .{
            .run_loop = true,
            .exiting = false,
            .head_output_device = .UNKNOWN,
            .main_process_pid = null,
            .load_state = .{
                .phase = .{
                    .phase_index = 0,
                    .phase_name = .{ .buffer = @splat(0) },
                    .sub_phase_name = .{ .buffer = @splat(0) },
                },
                .init = false,
                .full_init = false,
            },
            .last_frame_index = 0,
            .engine_thread = null,
            .engine_thread_cancellation = .{},
            .engine_thread_ready_for_begin_frame = .{},
            .to_engine_mailbox = .{},
            .to_engine_envelope_pool = .init(gpa),
            .displays = .empty,
            .held_keys = held_keys,
            .type_delta = .empty,
        };

        // SAFETY: this is way smaller than the maximum of 128, and we've just created these arrays
        game_data.load_state.phase.phase_name.appendSlice("Awaiting engine...") catch unreachable;

        break :create_game_data game_data;
    };

    app.* = .{
        .gpa = gpa,
        .xr = xr_data,
        .graphics_data = graphics_data,
        .window = window_data,
        .messaging = messaging_data,
        .imgui_data = maybe_imgui_data,
        .game = game_data,
        .assets = .empty,
    };

    return app;
}

pub fn deinit(self: *App) void {
    const gpa = self.gpa;

    self.game.deinit(gpa);
    self.messaging.deinit(gpa);
    if (self.imgui_data) |imgui_data| imgui_data.deinit();
    if (self.xr) |xr| xr.deinit(gpa);
    self.assets.deinit(gpa, self.graphics_data.device);
    self.graphics_data.deinit(gpa);
    self.window.deinit();

    gpa.destroy(self);
}

fn beginExit(self: *App) void {
    if (self.game.load_state.full_init) {
        self.game.exiting = true;
        self.messaging.host.primary.send(.{ .RendererShutdownRequest = .{} }) catch {
            log.warn("Failed to send shutdown request, exiting without waiting for engine", .{});
            self.game.run_loop = false;
        };
    } else {
        self.game.run_loop = false;
    }
}

fn handleRendererCommand(
    self: *App,
    renderer_command: renderite.ParsedCommand,
    frame_context: *graphics.FrameContext,
    queue_type: MessagingHost.QueueManager.Type,
) !void {
    _ = queue_type;

    // NOTE: this could be called from multiple threads!!! be aware of threading here
    // any command which _could be sent from both queues_ needs to have some kind of locking!

    defer renderer_command.arena.deinit();

    const command = renderer_command.command;

    switch (command) {
        .RendererInitData => |renderer_init_data| {
            var title_buf: [128]u8 = undefined;
            const title = std.fmt.bufPrintZ(&title_buf, "Gloobie (running {f})", .{std.unicode.fmtUtf16Le(renderer_init_data.windowTitle)}) catch "Gloobie (running [truncated])";

            log.debug("Setting window title to {s}", .{title});

            try self.window.window.setTitle(title);

            self.game.head_output_device = renderer_init_data.outputDevice;
            self.game.main_process_pid = renderer_init_data.mainProcessId;

            log.debug("Head output device updated to {s}", .{@tagName(self.game.head_output_device)});
            log.debug("Main process PID {d}", .{renderer_init_data.mainProcessId});

            const formats = comptime std.enums.values(renderite.Shared.TextureFormat);

            const supported_formats = self.graphics_data.sampler_supported_formats.unionWith(self.graphics_data.cubemap_supported_formats);
            const supported_formats_len = supported_formats.count();

            var supported_formats_buf: [formats.len]renderite.Shared.TextureFormat = undefined;
            var i: usize = 0;
            for (formats) |format| {
                if (supported_formats.contains(format)) {
                    log.debug("Sending format {s} as supported", .{@tagName(format)});
                    supported_formats_buf[i] = format;
                    i += 1;
                }
            }

            var shmem_prefix = &self.messaging.shmem_prefix;

            shmem_prefix.len = try std.unicode.utf16LeToUtf8(&shmem_prefix.buffer, renderer_init_data.sharedMemoryPrefix);
            self.messaging.accessor = try SharedMemoryAccessor.init(self.gpa, self.messaging.shmem_prefix.constSlice());

            log.debug("Set shmem prefix to {s} (len {d})", .{ shmem_prefix.constSlice(), shmem_prefix.len });

            try self.messaging.host.primary.send(.{
                .RendererInitResult = .{
                    .actualOutputDevice = self.game.head_output_device,
                    .stereoRenderingMode = std.unicode.utf8ToUtf16LeStringLiteral("MultiPass"), // out of MultiPass, SinglePass, SinglePassInstanced, SinglePassMultiView
                    .rendererIdentifier = std.unicode.utf8ToUtf16LeStringLiteral("Gloobie"),
                    .mainWindowHandlePtr = 0,
                    .isGPUTexturePOTByteAligned = true, // TODO: determine this by if we support VK_FORMAT_R8G8B8_UNORM and other such formats
                    .maxTextureSize = 16384, // TODO: determine this from GPU code
                    .supportedTextureFormats = supported_formats_buf[0..supported_formats_len],
                },
            });

            self.game.load_state.init = true;
        },
        .RendererInitProgressUpdate => |renderer_init_progress_update| {
            self.game.load_state.phase.phase_index = @intCast(renderer_init_progress_update.phaseIndex);

            const phase = &self.game.load_state.phase;

            phase.phase_name.len = try std.unicode.utf16LeToUtf8(phase.phase_name.buffer[0 .. phase.phase_name.buffer.len - 1], renderer_init_progress_update.phase);
            phase.sub_phase_name.len = try std.unicode.utf16LeToUtf8(phase.sub_phase_name.buffer[0 .. phase.sub_phase_name.buffer.len - 1], renderer_init_progress_update.subPhase);

            // null terminate strings
            phase.phase_name.buffer[phase.phase_name.len] = 0;
            phase.sub_phase_name.buffer[phase.sub_phase_name.len] = 0;
        },
        .RendererShutdown => |_| {
            log.debug("Engine is requesting that we shut down, beginning exit", .{});
            self.game.run_loop = false;
        },
        .RendererInitFinalizeData => |_| {
            self.game.load_state.full_init = true;
            log.info("Engine is fully loaded!", .{});
        },
        .SetTexture2DProperties => |set_texture_2d_properties| {
            try self.assets.setTexture2dPropertiesOrCreate(self.gpa, frame_context, set_texture_2d_properties);
        },
        .SetTexture2DFormat => |set_texture_2d_format| {
            try self.assets.setTexture2dFormat(self.gpa, frame_context, set_texture_2d_format);
        },
        .SetTexture2DData => |set_texture_2d_data| {
            if (self.messaging.accessor) |*accessor| {
                try self.assets.setTexture2dData(
                    self.gpa,
                    frame_context,
                    set_texture_2d_data,
                    accessor,
                );
            } else {
                std.debug.panic("Got texture command before shared memory accessor was initialized!", .{});
            }
        },
        .SetTexture3DProperties => |set_texture_3d_properties| {
            try self.assets.setTexture3dPropertiesOrCreate(self.gpa, frame_context, set_texture_3d_properties);
        },
        .SetTexture3DFormat => |set_texture_3d_format| {
            try self.assets.setTexture3dFormat(self.gpa, frame_context, set_texture_3d_format);
        },
        .SetTexture3DData => |set_texture_3d_data| {
            if (self.messaging.accessor) |*accessor| {
                try self.assets.setTexture3dData(
                    self.gpa,
                    frame_context,
                    set_texture_3d_data,
                    accessor,
                );
            } else {
                std.debug.panic("Got texture command before shared memory accessor was initialized!", .{});
            }
        },
        .SetCubemapProperties => |set_cubemap_properties| {
            try self.assets.setCubemapPropertiesOrCreate(self.gpa, frame_context, set_cubemap_properties);
        },
        .SetCubemapFormat => |set_cubemap_format| {
            try self.assets.setCubemapFormat(self.gpa, frame_context, set_cubemap_format);
        },
        .SetCubemapData => |set_cubemap_data| {
            if (self.messaging.accessor) |*accessor| {
                try self.assets.setCubemapData(
                    self.gpa,
                    frame_context,
                    set_cubemap_data,
                    accessor,
                );
            } else {
                std.debug.panic("Got texture command before shared memory accessor was initialized!", .{});
            }
        },
        inline .UnloadTexture2D, .UnloadTexture3D, .UnloadCubemap => |unload_texture, tag| {
            try self.assets.unloadTexture(.{
                .id = .from(unload_texture.assetId),
                .type = switch (tag) {
                    .UnloadTexture2D => .Texture2D,
                    .UnloadTexture3D => .Texture3D,
                    .UnloadCubemap => .Cubemap,
                    else => @compileError("Unhandled usecase"),
                },
            }, self.gpa, self.graphics_data.device);
        },
        .MeshUploadData => |mesh_upload_data| {
            if (self.messaging.accessor) |*accessor| {
                try self.assets.uploadMeshData(self.gpa, frame_context, accessor, mesh_upload_data);
            } else {
                std.debug.panic("Got mesh upload before accessor was created.", .{});
            }
        },
        .MeshUnload => |mesh_unload| {
            try self.assets.unloadMesh(.from(mesh_unload.assetId), self.gpa, self.graphics_data.device);
        },
        .FrameSubmitData => {
            std.debug.panic("This should be handled by the other thread!", .{});
        },
        else => {
            log.warn("Unhandled command type {s}", .{@tagName(command)});
        },
    }
}

fn handleMessages(self: *App, frame_context: *graphics.FrameContext) !void {
    const trace = tracy.traceNamed(@src(), "Handle messages");
    defer trace.end();

    while (true) {
        const envelope = self.messaging.to_render.receive(0) catch |err| {
            if (err == error.Timeout) {
                break;
            }

            return err;
        };

        // destroy the sent envelope to allow the memory to be re-used
        defer {
            self.messaging.letter_allocation_mutex.lock();
            defer self.messaging.letter_allocation_mutex.unlock();

            self.messaging.to_render_envelope_pool.destroy(envelope);
        }

        // process the letter in the envelope
        switch (envelope.letter) {
            .renderer_command => |renderer_command| {
                try self.handleRendererCommand(
                    renderer_command.command,
                    frame_context,
                    renderer_command.queue_type,
                );
            },
            .handle_output_state => |output_state| {
                try self.applyOutputState(output_state);
            },
        }
    }
}

fn messagingCallback(self: *App, queue_type: MessagingHost.QueueManager.Type, message: renderite.ParsedCommand) void {
    log.debug("Got message {s} on queue {s}", .{ @tagName(message.command), @tagName(queue_type) });

    switch (queue_type) {
        // messages coming in the primary queue need to be processed ASAP by the main thread
        .primary => {
            // frame submit messages go to the engine thread!
            if (message.command == .FrameSubmitData) {
                self.sendLetterToEngine(.{
                    .renderer_command = message,
                }) catch |err| std.debug.panic("Failed to send letter: {any}", .{err});
            } else {
                self.sendLetterToMain(.{
                    .renderer_command = .{ .command = message, .queue_type = queue_type },
                }) catch |err| std.debug.panic("Failed to send letter: {any}", .{err});
            }
        },
        .background => {
            // FIXME: push resource uploads onto another thread!
            var frame_context: graphics.FrameContext = .init(
                self.graphics_data.device,
                &self.graphics_data.background_transfer_buffer_pool,
                &self.assets,
                &self.graphics_data.fence_manager,
                &self.messaging.host,
            );
            defer frame_context.end(self.gpa) catch |err| std.debug.panic("Failed to end frame context: {s}", .{@errorName(err)});

            self.handleRendererCommand(message, &frame_context, queue_type) catch |err| {
                std.debug.panic("Failed to handle background command got err {s}", .{@errorName(err)});
            };
        },
    }
}

/// Sends an envelope to the render thread
pub fn sendLetterToMain(self: *App, letter: ToRenderLetter) !void {
    self.messaging.letter_allocation_mutex.lock();
    defer self.messaging.letter_allocation_mutex.unlock();

    const envelope = try self.messaging.to_render_envelope_pool.create();
    errdefer self.messaging.to_render_envelope_pool.destroy(envelope);

    envelope.* = .{ .letter = letter };

    try self.messaging.to_render.send(envelope);
}

/// Sends an envelope to the engine thread
pub fn sendLetterToEngine(self: *App, letter: ToEngineLetter) !void {
    self.messaging.letter_allocation_mutex.lock();
    defer self.messaging.letter_allocation_mutex.unlock();

    const envelope = try self.game.to_engine_envelope_pool.create();
    errdefer self.game.to_engine_envelope_pool.destroy(envelope);

    envelope.* = .{ .letter = letter };

    try self.game.to_engine_mailbox.send(envelope);
}

fn imguiFillTextures(self: *App, texture_type: Texture.Type) void {
    var texture_iter = self.assets.textures.iterator();
    while (texture_iter.next()) |texture_entry| {
        if (texture_entry.value_ptr.properties.type != texture_type) {
            continue;
        }

        defer imgui.separator();

        const handle, const texture = .{ texture_entry.key_ptr.*, texture_entry.value_ptr };

        imgui.c.igText("%s %d", @tagName(handle.type).ptr, @intFromEnum(handle.id));
        imgui.c.igText("Filter Mode: %s", @tagName(texture.properties.filter_mode).ptr);
        imgui.c.igText("Anisotropicsy Level: %d", texture.properties.aniso_level);
        imgui.c.igText("Wrap U/V: %s/%s", @tagName(texture.properties.wrap_u).ptr, @tagName(texture.properties.wrap_v).ptr);
        imgui.c.igText("Mipmap bias: %f", texture.properties.mipmap_bias);
        // NOTE: we're pulling a reference because we need a stable pointer to `.binding`!!!
        if (texture.graphics_data) |*graphics_data| {
            imgui.c.igText("Extents: %ux%ux%u", graphics_data.width, graphics_data.height, graphics_data.depth);
            imgui.c.igText("Format/Color Profile: %s %s", @tagName(graphics_data.texture_format).ptr, @tagName(graphics_data.profile).ptr);
            imgui.c.igText("Mipmap count: %u", graphics_data.mipmap_count);

            if (graphics_data.ready) {
                const render_scale = 512.0 / @as(f32, @floatFromInt(graphics_data.height));

                const width = render_scale * @as(f32, @floatFromInt(graphics_data.width));
                _ = width; // autofix
                const height = render_scale * @as(f32, @floatFromInt(graphics_data.height));
                _ = height; // autofix

                // FIXME: make this `binding` pointer stable somehow!
                // imgui.image(&graphics_data.binding, width, height);
            }
        } else {
            imgui.c.igText("No graphics data");
        }
    }
}

fn engineHandleMessage(self: *App, message: renderite.ParsedCommand) !void {
    defer message.arena.deinit();

    // SAFETY: only this message should be sent to the engine thread
    const frame_submit_data = message.command.FrameSubmitData;

    if (frame_submit_data.outputState) |output_state| {
        try self.sendLetterToMain(.{ .handle_output_state = output_state });
    }

    self.game.last_frame_index = frame_submit_data.frameIndex;
    log.debug("Frame {d} completion", .{frame_submit_data.frameIndex});

    for (frame_submit_data.renderSpaces) |render_space| {
        if (render_space.reflectionProbeSH2Taks) |sh2_tasks_descriptor| {
            const sh2_tasks_slice = try self.messaging.accessor.?.getOrCreate(self.gpa, sh2_tasks_descriptor.tasks) orelse continue;
            defer sh2_tasks_slice.release(&self.messaging.accessor.?);

            const sh2_tasks: []align(1) renderite.Shared.ReflectionProbeSH2Task = @ptrCast(sh2_tasks_slice.data);
            for (sh2_tasks) |*task| {
                task.result = .Failed;
            }
        }
    }

    self.game.engine_thread_ready_for_begin_frame.set();
}

fn engineLoop(self: *App) !void {
    self.game.engine_thread_ready_for_begin_frame.set();

    while (!self.game.engine_thread_cancellation.isSet()) {
        const message = self.game.to_engine_mailbox.receive(std.time.ns_per_s * 1) catch |err| {
            // Timeouts are nonfatal.
            if (err == error.Timeout) {
                log.debug("Engine wait timeout", .{});
                continue;
            }

            return err;
        };

        defer {
            self.messaging.letter_allocation_mutex.lock();
            defer self.messaging.letter_allocation_mutex.unlock();

            self.game.to_engine_envelope_pool.destroy(message);
        }

        switch (message.letter) {
            .renderer_command => |renderer_command| {
                try self.engineHandleMessage(renderer_command);
            },
        }
    }
}

fn updateDisplays(self: *App) !void {
    self.game.displays.clearRetainingCapacity();

    const displays = try sdl3.video.getDisplays();
    defer sdl3.free(displays);

    try self.game.displays.ensureUnusedCapacity(self.gpa, displays.len);

    const primary_display = try sdl3.video.Display.getPrimaryDisplay();

    for (displays, 0..) |display, index| {
        const bounds = try display.getBounds();

        // According to SDL documentation, DPI is approximated by multiplying
        // SDL_GetWindowDisplayScale() times 160 on iPhone and Android, and 96 on other platforms
        const dpi_scale =
            if (builtin.os.tag == .ios)
                120
            else if (builtin.abi.isAndroid())
                120
            else
                96;

        const dpi: f32 = try display.getContentScale() * dpi_scale;

        const natural_orientation: sdl3.video.DisplayOrientation = display.getNaturalOrientation() orelse .landscape;
        const current_orientation: sdl3.video.DisplayOrientation = display.getCurrentOrientation() orelse .landscape;

        const renderite_orientation: renderite.Shared.RectOrientation = switch (natural_orientation) {
            .landscape => switch (current_orientation) {
                .landscape => .Default,
                .landscape_flipped => .UpsideDown180,
                .portrait => .Clockwise90,
                .portrait_flipped => .CounterClockwise90,
            },
            .landscape_flipped => switch (current_orientation) {
                .landscape => .UpsideDown180,
                .landscape_flipped => .Default,
                .portrait => .CounterClockwise90,
                .portrait_flipped => .Clockwise90,
            },
            .portrait => switch (current_orientation) {
                .landscape => .CounterClockwise90,
                .landscape_flipped => .Clockwise90,
                .portrait => .Default,
                .portrait_flipped => .UpsideDown180,
            },
            .portrait_flipped => switch (current_orientation) {
                .landscape => .Clockwise90,
                .landscape_flipped => .CounterClockwise90,
                .portrait => .UpsideDown180,
                .portrait_flipped => .Default,
            },
        };

        const display_mode = try display.getDesktopMode();

        const renderite_display: renderite.Shared.DisplayState = .{
            .offset = .{ .x = bounds.x, .y = bounds.y },
            .displayIndex = @intCast(index),
            .dpi = .{ .x = dpi, .y = dpi },
            .isPrimary = display.value == primary_display.value,
            .orientation = renderite_orientation,
            .refreshRate = display_mode.refresh_rate orelse 60,
            .resolution = .{ .x = @intCast(display_mode.width), .y = @intCast(display_mode.height) },
        };
        try self.game.displays.append(self.gpa, renderite_display);

        log.debug("Got display {d} with size {d}x{d}", .{ index, display_mode.width, display_mode.height });
    }
}

fn updateWindowState(self: *App) !void {
    self.game.window_state = .{
        .isFullscreen = self.window.fullscreen,
    };
}

fn applyOutputState(self: *App, output_state: renderite.Shared.OutputState) !void {
    if (sdl3.keyboard.textInputActive(self.window.window) != output_state.keyboardInputActive) {
        if (output_state.keyboardInputActive) {
            try sdl3.keyboard.startTextInput(self.window.window);
            log.debug("Starting text input", .{});
        } else {
            try sdl3.keyboard.stopTextInput(self.window.window);
            log.debug("Stopping text input", .{});
        }
    }
}

pub fn frameLoop(self: *App) !void {
    self.game.engine_thread = try .spawn(.{}, engineLoop, .{self});

    try self.messaging.host.start(self.gpa);

    self.updateDisplays() catch |err| {
        log.err("Failed to update displays, got err {s}", .{@errorName(err)});
    };

    while (self.game.run_loop) {
        tracy.frameMark();

        {
            const trace = tracy.traceNamed(@src(), "Poll SDL events");
            defer trace.end();

            // Poll SDL3 events
            while (sdl3.events.poll()) |event| {
                if (self.imgui_data != null) {
                    // ignore ret, doesnt help us
                    _ = imgui.sdl3.processEvent(event);
                }

                switch (event) {
                    .quit => {
                        // try not to send duplicate quit messages.
                        // this event usually comes after we've triggered an exit from window_close_requested
                        // if we send 2 quit messages, the engine will force-exit unsafely.
                        if (!self.game.exiting) {
                            self.beginExit();
                        }
                    },
                    .window_close_requested => |window| {
                        // SAFETY: getId error is unreachable if window is valid, which it always should be at this point
                        if (window.id == self.window.window.getId() catch unreachable) {
                            self.beginExit();
                        }
                    },
                    .display_added,
                    .display_content_scale_changed,
                    .display_current_mode_changed,
                    .display_desktop_mode_changed,
                    .display_moved,
                    .display_orientation,
                    .display_removed,
                    => {
                        self.updateDisplays() catch |err| {
                            log.err("Failed to update displays, got err {s}", .{@errorName(err)});
                        };
                    },
                    .window_enter_fullscreen => |window| if (window.id == self.window.window.getId() catch unreachable) {
                        self.window.fullscreen = true;
                    },
                    .window_leave_fullscreen => |window| if (window.id == self.window.window.getId() catch unreachable) {
                        self.window.fullscreen = false;
                    },
                    .window_focus_gained => |window| if (window.id == self.window.window.getId() catch unreachable) {
                        self.window.focus = true;
                    },
                    .window_focus_lost => |window| if (window.id == self.window.window.getId() catch unreachable) {
                        self.window.focus = false;
                    },
                    .key_down => |key_down| {
                        if (key_down.window_id == self.window.window.getId() catch unreachable and !key_down.repeat) {
                            if (key_down.key) |keycode| {
                                if (Input.sdlKeycodeToRenderiteKey(keycode)) |key| {
                                    self.game.held_keys.appendAssumeCapacity(key);
                                }
                            }
                        }
                    },
                    .key_up => |key_up| {
                        if (key_up.window_id == self.window.window.getId() catch unreachable) {
                            if (key_up.key) |keycode| {
                                if (Input.sdlKeycodeToRenderiteKey(keycode)) |key| {
                                    for (self.game.held_keys.items, 0..) |held_key, i| {
                                        if (held_key == key) {
                                            _ = self.game.held_keys.swapRemove(i);
                                        }
                                    }
                                }
                            }
                        }
                    },
                    // convert to UTF-16 and append to the delta
                    .text_input => |text_input| {
                        var iter: std.unicode.Utf8Iterator = .{
                            .i = 0,
                            .bytes = text_input.text,
                        };

                        while (iter.nextCodepoint()) |codepoint| {
                            if (codepoint < 0x10000) {
                                try self.game.type_delta.append(self.gpa, @intCast(codepoint));
                            } else {
                                const high = @as(u16, @intCast((codepoint - 0x10000) >> 10)) + 0xD800;
                                const low = @as(u16, @intCast(codepoint & 0x3FF)) + 0xDC00;

                                try self.game.type_delta.appendSlice(self.gpa, &.{ @intCast(high), @intCast(low) });
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        if (self.xr) |xr| {
            const trace = tracy.traceNamed(@src(), "XR event handling");
            defer trace.end();

            try xr.backend.handleEvents();
        }

        // tick the fence manager, since we're about to start a new frame
        try self.graphics_data.fence_manager.tick();

        const command_buffer = try self.graphics_data.device.acquireCommandBuffer();

        {
            errdefer command_buffer.cancel() catch std.debug.panic("failed to cancel cmdbuf", .{});

            var frame_context: graphics.FrameContext = .initMain(
                self.graphics_data.device,
                &self.graphics_data.primary_transfer_buffer_pool,
                &self.assets,
                command_buffer,
                &self.graphics_data.fence_manager,
                &self.messaging.host,
            );

            var begin_new_frame = true;
            self.game.engine_thread_ready_for_begin_frame.timedWait(std.time.ns_per_ms * 100) catch |err| {
                if (err == error.Timeout) {
                    begin_new_frame = false;
                    log.debug("Engine running really slow, no new frame :(", .{});
                } else {
                    return err;
                }
            };

            // handle any messages from the queues, happens before processing most of the frame/rendering
            try handleMessages(self, &frame_context);

            const swapchain_texture_result = acquire_swapchain_texture: {
                const trace = tracy.traceNamed(@src(), "Acquire Swapchain Texture");
                defer trace.end();

                break :acquire_swapchain_texture try command_buffer.acquireSwapchainTexture(self.window.window);
            };
            const maybe_swapchain_texture, const swapchain_width, const swapchain_height = .{ swapchain_texture_result.texture, swapchain_texture_result.width, swapchain_texture_result.height };

            // send a frame start if the engine thread is waiting for us to do so
            if (self.game.load_state.full_init and begin_new_frame) {
                try self.messaging.host.primary.send(.{
                    .FrameStartData = .{
                        .lastFrameIndex = self.game.last_frame_index,
                        .inputs = .{
                            .displays = self.game.displays.items,
                            .gamepads = &.{},
                            .keyboard = .{
                                .heldKeys = self.game.held_keys.items,
                                .typeDelta = self.game.type_delta.items,
                            },
                            .mouse = null,
                            .touches = &.{},
                            .vr = null,
                            .window = .{
                                .isFullscreen = self.window.fullscreen,
                                .isWindowFocused = self.window.focus,
                                .dragAndDropEvent = null,
                                // TODO: should this be window size or swapchain size?
                                .windowResolution = .{
                                    .x = @intCast(swapchain_width),
                                    .y = @intCast(swapchain_height),
                                },
                                .resolutionSettingsApplied = false,
                            },
                        },
                        .performance = null,
                        .renderedReflectionProbes = &.{},
                    },
                });

                if (self.game.type_delta.items.len > 0) {
                    log.debug("Sent string {f} to engine", .{std.unicode.fmtUtf16Le(self.game.type_delta.items)});
                }
                self.game.type_delta.clearRetainingCapacity();

                log.debug("Sent frame {d} start", .{self.game.last_frame_index + 1});

                self.game.engine_thread_ready_for_begin_frame.reset();
            }

            // end frame context, frame is over
            try frame_context.end(self.gpa);

            // tick assets
            self.assets.mainThreadTick(self.gpa, self.graphics_data.device);

            if (self.imgui_data) |*imgui_data| {
                const trace = tracy.traceNamed(@src(), "ImGui start frame");
                defer trace.end();

                // imgui new frame
                imgui.gpu.newFrame();
                imgui.sdl3.newFrame();
                imgui.newFrame();

                {
                    const assets_render = imgui.begin("Assets", &imgui_data.assets_open, 0);
                    defer imgui.end();
                    if (assets_render) {
                        self.assets.lock.lockShared();
                        defer self.assets.lock.unlockShared();

                        {
                            if (imgui.collapsingHeader("Texture 2Ds", 0)) {
                                self.imguiFillTextures(.Texture2D);
                            }
                        }

                        {
                            if (imgui.collapsingHeader("Texture 3Ds", 0)) {
                                self.imguiFillTextures(.Texture3D);
                            }
                        }

                        {
                            if (imgui.collapsingHeader("Cubemaps", 0)) {
                                self.imguiFillTextures(.Cubemap);
                            }
                        }

                        {
                            if (imgui.collapsingHeader("Meshes", 0)) {
                                var mesh_iter = self.assets.meshes.iterator();
                                while (mesh_iter.next()) |mesh_entry| {
                                    const asset_id, const mesh = .{ mesh_entry.key_ptr.*, mesh_entry.value_ptr };
                                    defer imgui.separator();

                                    imgui.c.igText("Mesh %d", asset_id.to());
                                    imgui.c.igText("Vertex Buffer Capacity: %u", mesh.vertex_buffer_capacity);
                                    imgui.c.igText("Index Buffer Capacity: %u", mesh.index_buffer_capacity);
                                    imgui.c.igText(
                                        "Buffer Present: %s/%s",
                                        if (mesh.vertex_buffer == null) "false".ptr else "true".ptr,
                                        if (mesh.index_buffer == null) "false".ptr else "true".ptr,
                                    );

                                    var name_buf: [64]u8 = undefined;
                                    // SAFETY: it's big enough
                                    const attributes_header = std.fmt.bufPrintZ(&name_buf, "Attributes##{d}", .{
                                        asset_id.to(),
                                    }) catch unreachable;

                                    if (imgui.collapsingHeader(attributes_header, 0)) {
                                        for (mesh.vertex_attributes, 0..) |attribute, i| {
                                            imgui.c.igText(
                                                "Attribute %d, %s/%s",
                                                @as(i32, @intCast(i)),
                                                @tagName(attribute.format).ptr,
                                                @tagName(attribute.type).ptr,
                                            );
                                        }
                                    }

                                    const submeshes_header = std.fmt.bufPrintZ(&name_buf, "Sub Meshes##{d}", .{
                                        asset_id.to(),
                                    }) catch unreachable;

                                    if (imgui.collapsingHeader(submeshes_header, 0)) {
                                        for (mesh.submeshes, 0..) |submesh, i| {
                                            imgui.c.igText(
                                                "Submesh %d, %s, %u/%u, %fx%fx%f/%fx%fx%f",
                                                @as(i32, @intCast(i)),
                                                @tagName(submesh.topology).ptr,
                                                submesh.index_start,
                                                submesh.index_count,
                                                submesh.bounds.center.x,
                                                submesh.bounds.center.y,
                                                submesh.bounds.center.z,
                                                submesh.bounds.extents.x,
                                                submesh.bounds.extents.y,
                                                submesh.bounds.extents.z,
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (!self.game.load_state.full_init) {
                    const phase = &self.game.load_state.phase;
                    const loadstate_render = imgui.begin("Loading...", &imgui_data.loadstate_open, 0);
                    defer imgui.end();
                    if (loadstate_render) {
                        imgui.text(phase.phase_name.buffer[0..phase.phase_name.len :0]);
                        if (phase.sub_phase_name.len != 0)
                            imgui.text(phase.sub_phase_name.buffer[0..phase.sub_phase_name.len :0]);

                        const progress: f32 = @as(f32, @floatFromInt(phase.phase_index)) / @as(f32, @floatFromInt(total_load_phases));
                        imgui.progressBar(progress, .{ .x = 0, .y = 0 }, "");
                    }
                }

                var show_demo_window: bool = true;
                imgui.showDemoWindow(&show_demo_window);

                imgui.render();
            }

            if (maybe_swapchain_texture) |swapchain_texture| {
                const render_trace = tracy.traceNamed(@src(), "Render Frame");
                defer render_trace.end();

                const imgui_draw_data = if (self.imgui_data != null) create_draw_data: {
                    const draw_data = imgui.getDrawData();
                    const is_minimized = draw_data.DisplaySize.x <= 0.0 or draw_data.DisplaySize.y <= 0.0;

                    if (!is_minimized) {
                        imgui.gpu.prepareDrawData(draw_data, command_buffer);
                    }

                    break :create_draw_data if (is_minimized) null else draw_data;
                } else null;

                const render_pass = command_buffer.beginRenderPass(&.{.{
                    .texture = swapchain_texture,
                    .clear_color = .{ .a = 1.0 },
                    .load = .clear,
                }}, null);

                if (imgui_draw_data) |draw_data| {
                    imgui.gpu.renderDrawData(
                        draw_data,
                        command_buffer,
                        render_pass,
                        null,
                    );
                }

                render_pass.end();
            }
        }
        {
            const trace = tracy.traceNamed(@src(), "Submit Command Buffer");
            defer trace.end();

            try command_buffer.submit();
        }

        // tick the buffer pools
        self.graphics_data.primary_transfer_buffer_pool.frameTick();
        self.graphics_data.background_transfer_buffer_pool.frameTick();
    }
}

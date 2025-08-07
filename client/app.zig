const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const imgui_t = @import("imgui");
const mailbox = @import("mailbox");
const math = @import("math");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");
const tracy = @import("tracy");
const xr_t = @import("xr");

const Assets = @import("Assets.zig");
const Texture = @import("Texture.zig");

const MessagingHost = renderite.MessagingHost(*App);
const SharedMemoryAccessor = renderite.SharedMemoryAccessor;

const log = std.log.scoped(.app);

const App = @This();

const XrData = struct {
    backend: *xr_t.Backend,

    pub fn deinit(self: XrData, gpa: std.mem.Allocator) void {
        self.backend.deinit(gpa);
    }
};

const GraphicsData = struct {
    device: gpu.Device,
    sampler_supported_formats: std.enums.EnumSet(renderite.Shared.TextureFormat),
    cubemap_supported_formats: std.enums.EnumSet(renderite.Shared.TextureFormat),

    pub fn deinit(self: GraphicsData) void {
        self.device.deinit();
    }
};

const WindowData = struct {
    window: sdl3.video.Window,
    swapchain_format: gpu.TextureFormat,

    pub fn deinit(self: WindowData) void {
        self.window.deinit();
    }
};

pub const ToRenderMailbox = mailbox.MailBox(ToRenderLetter);

pub const ToRenderLetter = union(enum) { renderer_command: renderite.ParsedCommand };

const MessagingData = struct {
    host: MessagingHost,
    accessor: ?*SharedMemoryAccessor,
    shmem_prefix: std.BoundedArray(u8, 128),

    to_render: ToRenderMailbox,
    to_render_envelope_pool: std.heap.MemoryPool(ToRenderMailbox.Envelope),

    letter_allocation_mutex: std.Thread.Mutex,

    pub fn deinit(self: *MessagingData) void {
        self.host.primary.send(.{ .RendererShutdownRequest = .{} }) catch {};
        self.host.deinit();

        if (self.accessor) |accessor| accessor.deinit();

        var envelopes = self.to_render.close();
        while (envelopes) |envelope| {
            switch (envelope.letter) {
                .renderer_command => |renderer_command| {
                    renderer_command.arena.deinit();
                },
            }

            envelopes = envelope.next;
        }

        self.to_render_envelope_pool.deinit();

        log.debug("messaging data deinit", .{});
    }
};

const ImGuiData = struct {
    context: imgui_t.Context,

    assets_open: bool,
    loadstate_open: bool,

    pub fn deinit(self: ImGuiData) void {
        imgui_t.gpu.shutdown();
        imgui_t.sdl3.shutdown();
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
    head_output_device: renderite.Shared.HeadOutputDevice,
    main_process_pid: ?i32,
    load_state: LoadState,
};

gpa: std.mem.Allocator,

game: GameData,
xr: ?XrData,
graphics: GraphicsData,
window: WindowData,
messaging: MessagingData,
imgui: ?ImGuiData,
assets: Assets,

pub fn init(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    errdefer gpa.destroy(app);

    const messaging_data: MessagingData = create_messaging_data: {
        const host = MessagingHost.initFromArgs(messagingCallback, app, gpa) catch |err| debug_queue: {
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
        };
    };
    errdefer window_data.deinit();

    const graphics_data: GraphicsData = create_graphics_data: {
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
        };
    };
    errdefer graphics_data.deinit();

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
    const imgui_data: ?ImGuiData = create_imgui_data: {
        const context = try imgui_t.Context.create(null);
        errdefer context.destroy();

        context.setCurrent();

        const style = imgui_t.getStyle();
        // Go through every colour and convert it to linear
        // This is because ImGui uses linear colours but we are using sRGB
        // This is a simple approximation of the conversion
        for (0..imgui_t.c.ImGuiCol_COUNT) |i| {
            const col = &style.Colors[i];
            col.x = math.srgbToLinear(f32, col.x);
            col.y = math.srgbToLinear(f32, col.y);
            col.z = math.srgbToLinear(f32, col.z);
        }

        try imgui_t.sdl3.initForOther(window_data.window);
        errdefer imgui_t.sdl3.shutdown();

        log.info("Initialized ImGui SDL3 backend", .{});

        try imgui_t.gpu.init(.{
            .color_target_format = window_data.swapchain_format,
            .device = graphics_data.device,
            .msaa_samples = .no_multisampling,
        });
        errdefer imgui_t.gpu.shutdown();

        log.info("Initialized ImGui GPU backend", .{});

        break :create_imgui_data .{
            .context = context,
            .assets_open = true,
            .loadstate_open = true,
        };
    };
    errdefer if (imgui_data) |imgui| imgui.deinit();

    var game_data: GameData = .{
        .run_loop = true,
        .head_output_device = .UNKNOWN,
        .main_process_pid = null,
        .load_state = .{
            .phase = .{
                .phase_index = 0,
                .phase_name = .{},
                .sub_phase_name = .{},
            },
            .init = false,
            .full_init = false,
        },
    };

    // SAFETY: this is way smaller than the maximum of 128, and we've just created these arrays
    game_data.load_state.phase.phase_name.appendSlice("Awaiting engine...") catch unreachable;

    app.* = .{
        .gpa = gpa,
        .xr = xr_data,
        .graphics = graphics_data,
        .window = window_data,
        .messaging = messaging_data,
        .imgui = imgui_data,
        .game = game_data,
        .assets = .empty,
    };

    return app;
}

pub fn deinit(self: *App) void {
    const gpa = self.gpa;

    self.messaging.deinit();
    if (self.imgui) |imgui| imgui.deinit();
    if (self.xr) |xr| xr.deinit(gpa);
    self.assets.deinit(gpa, self.graphics.device);
    self.graphics.deinit();
    self.window.deinit();

    gpa.destroy(self);
}

fn beginExit(self: *App) void {
    self.game.run_loop = false;
}

fn handleRendererCommand(self: *App, renderer_command: renderite.ParsedCommand) !void {
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

            const supported_formats = self.graphics.sampler_supported_formats.unionWith(self.graphics.cubemap_supported_formats);
            const supported_formats_len = supported_formats.count();

            var supported_formats_buf: [formats.len]renderite.Shared.TextureFormat = undefined;
            var i: usize = 0;
            for (formats) |format| {
                if (supported_formats.contains(format)) {
                    supported_formats_buf[i] = format;
                    i += 1;
                }
            }

            var shmem_prefix = &self.messaging.shmem_prefix;

            shmem_prefix.len = try std.unicode.utf16LeToUtf8(&shmem_prefix.buffer, renderer_init_data.sharedMemoryPrefix);
            self.messaging.accessor = try SharedMemoryAccessor.init(shmem_prefix.constSlice(), self.gpa);

            log.debug("Set shmem prefix to {s} (len {d})", .{ shmem_prefix.constSlice(), shmem_prefix.len });

            try self.messaging.host.primary.send(.{
                .RendererInitResult = .{
                    .actualOutputDevice = self.game.head_output_device,
                    .stereoRenderingMode = std.unicode.utf8ToUtf16LeStringLiteral("MultiPass"), // out of MultiPass, SinglePass, SinglePassInstanced, SinglePassMultiView
                    .rendererIdentifier = std.unicode.utf8ToUtf16LeStringLiteral("Gloobie"),
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

            log.debug("Renderer init progress update: force show: {}, phase: \"{s}\", phase index: {d}, sub phase: \"{s}\"", .{
                renderer_init_progress_update.forceShow,
                phase.phase_name.constSlice(),
                renderer_init_progress_update.phaseIndex,
                phase.sub_phase_name.constSlice(),
            });
        },
        .RendererShutdown => |_| {
            log.debug("Engine is requesting that we shut down, beginning exit", .{});
            self.beginExit();
        },
        .RendererInitFinalizeData => |_| {
            self.game.load_state.full_init = true;
            log.info("Engine is fully loaded!", .{});
        },
        .SetTexture2DProperties => |set_texture_2d_properties| {
            try self.assets.setTexture2dPropertiesOrCreate(self.gpa, set_texture_2d_properties);
        },
        .SetTexture2DFormat => |set_texture_2d_format| {
            try self.assets.setTexture2dFormat(set_texture_2d_format, self.graphics.device);
        },
        .SetTexture2DData => |set_texture_2d_data| {
            try self.assets.setTexture2dData(set_texture_2d_data, self.messaging.accessor.?, self.graphics.device);
        },
        else => {
            log.warn("Unhandled command type {s}", .{@tagName(command)});
        },
    }
}

fn handleMessages(self: *App) !void {
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
                try self.handleRendererCommand(renderer_command);
            },
        }
    }
}

fn messagingCallback(self: *App, queue_type: MessagingHost.QueueManager.Type, message: renderite.ParsedCommand) void {
    switch (queue_type) {
        // messages coming in the primary queue need to be processed ASAP by the main thread
        .primary => self.sendLetter(.{ .renderer_command = message }) catch |err| std.debug.panic("Failed to send letter: {any}", .{err}),
        .background => {
            self.handleRendererCommand(message) catch |err| {
                std.debug.panic("Failed to handle background command got err {s}", .{@errorName(err)});
            };
        },
    }
}

/// Sends an envelope to the render thread
pub fn sendLetter(self: *App, letter: ToRenderLetter) !void {
    self.messaging.letter_allocation_mutex.lock();
    defer self.messaging.letter_allocation_mutex.unlock();

    const envelope = try self.messaging.to_render_envelope_pool.create();
    errdefer self.messaging.to_render_envelope_pool.destroy(envelope);

    envelope.* = .{ .letter = letter };

    try self.messaging.to_render.send(envelope);
}

pub fn frameLoop(self: *App) !void {
    try self.messaging.host.start(self.gpa);

    while (self.game.run_loop) {
        tracy.frameMark();

        {
            const trace = tracy.traceNamed(@src(), "Poll SDL events");
            defer trace.end();

            // Poll SDL3 events
            while (sdl3.events.poll()) |event| {
                if (self.imgui != null) {
                    // ignore ret, doesnt help us
                    _ = imgui_t.sdl3.processEvent(event);
                }

                switch (event) {
                    .quit => {
                        self.beginExit();
                    },
                    .window_close_requested => |window| {
                        // SAFETY: getId error is unreachable if window is valid, which it always should be at this point
                        if (window.id == self.window.window.getId() catch unreachable) {
                            self.beginExit();
                        }
                    },
                    else => {},
                }
            }
        }

        if (self.imgui) |*imgui| {
            const trace = tracy.traceNamed(@src(), "ImGui start frame");
            defer trace.end();

            // imgui new frame
            imgui_t.gpu.newFrame();
            imgui_t.sdl3.newFrame();
            imgui_t.newFrame();

            {
                const assets_render = imgui_t.begin("Assets", &imgui.assets_open, 0);
                defer imgui_t.end();
                if (assets_render) {
                    self.assets.lock.lockShared();
                    defer self.assets.lock.unlockShared();

                    {
                        _ = imgui_t.collapsingHeader("Textures", 0);

                        var texture_iter = self.assets.texture_2ds.iterator();
                        while (texture_iter.next()) |texture_entry| {
                            defer imgui_t.separator();

                            const id, const texture = .{ texture_entry.key_ptr.*, texture_entry.value_ptr };

                            imgui_t.c.igText("Texture %d", @intFromEnum(id));
                            imgui_t.c.igText("Filter Mode: %s", @tagName(texture.filter_mode).ptr);
                            imgui_t.c.igText("Anisotropicsy Level: %d", texture.aniso_level);
                            imgui_t.c.igText("Wrap U/V: %s/%s", @tagName(texture.wrap_u).ptr, @tagName(texture.wrap_v).ptr);
                            imgui_t.c.igText("Mipmap bias: %f", texture.mipmap_bias);
                            if (texture.format) |format| {
                                imgui_t.c.igText("Extents: %ux%u", format.width, format.height);
                                imgui_t.c.igText("Format/Color Profile: %s %s", @tagName(format.texture_format).ptr, @tagName(format.profile).ptr);
                                imgui_t.c.igText("Mipmap count: %u", format.mipmap_count);
                            } else {
                                imgui_t.c.igText("No format");
                            }
                        }
                    }

                    {
                        _ = imgui_t.collapsingHeader("Meshes", 0);
                    }
                }
            }

            if (!self.game.load_state.full_init) {
                const phase = &self.game.load_state.phase;
                const loadstate_render = imgui_t.begin("Loading...", &imgui.loadstate_open, 0);
                defer imgui_t.end();
                if (loadstate_render) {
                    imgui_t.text(phase.phase_name.buffer[0..phase.phase_name.len :0]);
                    if (phase.sub_phase_name.len != 0)
                        imgui_t.text(phase.sub_phase_name.buffer[0..phase.sub_phase_name.len :0]);

                    const progress: f32 = @as(f32, @floatFromInt(phase.phase_index)) / @as(f32, @floatFromInt(total_load_phases));
                    imgui_t.progressBar(progress, .{ .x = 0, .y = 0 }, "");
                }
            }

            var show_demo_window: bool = true;
            imgui_t.showDemoWindow(&show_demo_window);
        }

        if (self.xr) |xr| {
            const trace = tracy.traceNamed(@src(), "XR event handling");
            defer trace.end();

            try xr.backend.handleEvents();
        }

        // handle any messages from the queues, happens before processing most of the frame/rendering
        try handleMessages(self);

        const command_buffer = try self.graphics.device.acquireCommandBuffer();

        const swapchain_texture_result = acquire_swapchain_texture: {
            const trace = tracy.traceNamed(@src(), "Acquire Swapchain Texture");
            defer trace.end();

            break :acquire_swapchain_texture try command_buffer.acquireSwapchainTexture(self.window.window);
        };
        const maybe_swapchain_texture, const swapchain_width, const swapchain_height = .{ swapchain_texture_result.texture, swapchain_texture_result.width, swapchain_texture_result.height };

        _ = swapchain_height;
        _ = swapchain_width;

        if (self.imgui != null) {
            const trace = tracy.traceNamed(@src(), "ImGui render");
            defer trace.end();

            imgui_t.render();
        }

        if (maybe_swapchain_texture) |swapchain_texture| {
            const render_trace = tracy.traceNamed(@src(), "Render Frame");
            defer render_trace.end();

            const imgui_draw_data = if (self.imgui != null) create_draw_data: {
                const draw_data = imgui_t.getDrawData();
                const is_minimized = draw_data.DisplaySize.x <= 0.0 or draw_data.DisplaySize.y <= 0.0;

                if (!is_minimized) {
                    imgui_t.gpu.prepareDrawData(draw_data, command_buffer);
                }

                break :create_draw_data if (is_minimized) null else draw_data;
            } else null;

            const render_pass = command_buffer.beginRenderPass(&.{.{
                .texture = swapchain_texture,
                .clear_color = .{ .a = 1.0 },
                .load = .clear,
            }}, null);

            if (imgui_draw_data) |draw_data| {
                imgui_t.gpu.renderDrawData(
                    draw_data,
                    command_buffer,
                    render_pass,
                    null,
                );
            }

            render_pass.end();
        }

        {
            const trace = tracy.traceNamed(@src(), "Submit Command Buffer");
            defer trace.end();

            try command_buffer.submit();
        }
    }
}

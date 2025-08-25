const std = @import("std");
const builtin = @import("builtin");

const bounded_array = @import("bounded_array");
const build_options = @import("options").build_options;
const gpu = @import("gpu");
const imgui = @import("imgui");
const mailbox = @import("mailbox");
const math = @import("math");
const renderite = @import("renderite");
const SharedMemoryAccessor = renderite.buffer.SharedMemoryAccessor;
const InitSettings = renderite.InitSettings;
const sdl3 = @import("sdl3");
const tracy = @import("tracy");
const xr_t = @import("xr");

const Assets = @import("assets/Assets.zig");
const Texture = @import("assets/Texture.zig");
const graphics = @import("graphics.zig");
const ImGuiManager = @import("gui/ImGuiManager.zig");
const Input = @import("Input.zig");
const Output = @import("Output.zig");
const PerformanceMonitor = @import("PerformanceMonitor.zig");
const RenderSpace = @import("render_spaces/RenderSpace.zig");
const GpuShader = @import("shaders/GpuShader.zig");
const GraphicsPipeline = @import("shaders/GraphicsPipeline.zig");

pub const MessagingHost = renderite.messaging.Host(*App);
const log = @import("logger").Scoped(.app);

const App = @This();

const XrData = struct {
    backend: *xr_t.Backend,

    pub fn deinit(self: XrData, gpa: std.mem.Allocator) void {
        self.backend.deinit(gpa);
    }
};

pub const FenceManager = graphics.FenceManager(&.{});

const GraphicsData = struct {
    device: gpu.Device,
    sampler_supported_formats: std.enums.EnumSet(renderite.shared.TextureFormat),
    cubemap_supported_formats: std.enums.EnumSet(renderite.shared.TextureFormat),

    depth_texture: ?gpu.Texture,
    depth_texture_size: math.Vector2i,

    transfer_buffer_pool: graphics.TransferBufferPool,

    fence_manager: FenceManager,

    window_test_pipeline: GraphicsPipeline,

    upload_nonce: std.atomic.Value(u64),

    pub fn deinit(
        self: *GraphicsData,
        gpa: std.mem.Allocator,
    ) void {
        if (self.depth_texture) |depth_texture| {
            self.device.releaseTexture(depth_texture);
        }
        self.fence_manager.deinit(gpa);

        self.transfer_buffer_pool.deinit(gpa);

        self.device.deinit();
    }
};

const WindowData = struct {
    window: sdl3.video.Window,
    swapchain_format: gpu.TextureFormat,
    composition_mode: gpu.SwapchainComposition,
    default_present_mode: gpu.PresentMode,
    present_mode: gpu.PresentMode,

    fullscreen: bool,
    focus: bool,
    mouse_active: bool,
    resolution_updated: bool,

    bg_max_framerate: ?u32,
    fg_max_framerate: ?u32,

    pub fn takeResolutionUpdate(self: *WindowData) bool {
        defer self.resolution_updated = false;
        return self.resolution_updated;
    }

    pub fn deinit(self: WindowData) void {
        self.window.deinit();
    }
};

pub const ToRenderMailbox = mailbox.MailBox(ToRenderLetter);

pub const ToRenderLetter = union(enum) {
    renderer_command: struct {
        command: renderite.messaging.ParsedCommand,
        queue_type: MessagingHost.QueueManager.Type,
    },
    handle_output_state: renderite.shared.OutputState,
};

pub const ToEngineMailbox = mailbox.MailBox(ToEngineLetter);

pub const ToEngineLetter = union(enum) {
    renderer_command: renderite.messaging.ParsedCommand,
};

const MessagingData = struct {
    host: MessagingHost,
    accessor: ?SharedMemoryAccessor,
    shmem_prefix: bounded_array.BoundedArray(u8, 128),

    to_render: ToRenderMailbox,
    to_render_envelope_pool: std.heap.MemoryPool(ToRenderMailbox.Envelope),

    letter_allocation_mutex: std.Thread.Mutex,

    pub fn deinit(self: *MessagingData, gpa: std.mem.Allocator) void {
        self.host.primary.sendTimeout(.{ .RendererShutdownRequest = .{} }, std.time.ns_per_s) catch {};
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

        log.trace(@src(), "messaging data deinit", .{});
    }
};

// TODO: warn when we need to update this (when this differs on full load)
pub const total_load_phases = 25;

const LoadPhase = struct {
    phase_index: u8,
    phase_name: bounded_array.BoundedArray(u8, 128),
    sub_phase_name: bounded_array.BoundedArray(u8, 128),
};

const LoadState = struct {
    phase: LoadPhase,
    init: bool,
    full_init: bool,
};

const GameData = struct {
    run_loop: bool,
    exiting: bool,
    head_output_device: renderite.shared.HeadOutputDevice,
    main_process_pid: ?i32,
    load_state: LoadState,
    last_frame_index: i32,
    engine_thread: ?std.Thread,
    engine_thread_cancellation: std.Thread.ResetEvent,
    engine_thread_ready_for_begin_frame: std.Thread.ResetEvent,
    to_engine_mailbox: ToEngineMailbox,
    to_engine_envelope_pool: std.heap.MemoryPool(ToEngineMailbox.Envelope),

    displays: std.ArrayListUnmanaged(renderite.shared.DisplayState),

    render_spaces_lock: std.Thread.RwLock,
    render_spaces: std.AutoArrayHashMapUnmanaged(RenderSpace.Id, RenderSpace),

    input: Input,
    perf: PerformanceMonitor,

    /// Vertical FOV in degrees
    desktop_fov: f32,
    near_z: f32,
    far_z: f32,
    head_output: Output,

    pub fn deinit(
        self: *GameData,
        gpa: std.mem.Allocator,
        device: gpu.Device,
    ) void {
        if (self.engine_thread) |engine_thread| {
            self.engine_thread_cancellation.set();

            engine_thread.join();
        }

        self.head_output.deinit(gpa);

        for (self.render_spaces.values()) |*render_space| {
            render_space.deinit(gpa, device);
        }
        self.render_spaces.deinit(gpa);

        self.to_engine_envelope_pool.deinit();

        self.input.deinit(gpa);
        self.displays.deinit(gpa);
    }
};

gpa: std.mem.Allocator,

game: GameData,
xr: ?XrData,
graphics_data: GraphicsData,
window: WindowData,
messaging: MessagingData,
imgui_data: ?ImGuiManager,
assets: Assets,

pub fn init(gpa: std.mem.Allocator, settings: InitSettings) !*App {
    const app = try gpa.create(App);
    errdefer gpa.destroy(app);

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const messaging_data: MessagingData = create_messaging_data: {
        const host = MessagingHost.init(settings.queue_name.constSlice(), settings.queue_length, messagingCallback, app) catch |err| debug_queue: {
            log.warn(@src(), "Failed to initialize messaging manager from command line arguments: {s}, setting up dummy queue", .{@errorName(err)});
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
            log.err(@src(), "Got error {s} when trying to initialize XR backend.", .{@errorName(err)});

            break :backend_create_fail null;
        };
        errdefer if (xr_backend) |backend| backend.deinit(gpa);

        if (xr_backend) |_| {
            log.info(@src(), "Initialized XR backend {s}", .{xr_t.name});
        } else {
            log.warn(@src(), "Failed to initialize XR backend {s}, will be starting in desktop-only mode. Restart will be required to begin a VR session.", .{xr_t.name});
        }

        break :create_xr_data if (xr_backend) |backend| .{ .backend = backend } else null;
    };
    errdefer if (xr_data) |xr| xr.deinit(gpa);

    var window_data: WindowData = create_window_data: {
        const window_ret = try sdl3.video.Window.initWithProperties(.{
            .width = 1280,
            .height = 720,
            // TODO: only enable this when using the vulkan backend
            .vulkan = true,
            .title = "Gloobie",
        });
        const window, const properties = .{ window_ret.window, window_ret.properties };
        properties.deinit();
        errdefer window.deinit();

        break :create_window_data .{
            .window = window,
            .swapchain_format = undefined,
            .fullscreen = false,
            .focus = false,
            .composition_mode = undefined,
            .present_mode = undefined,
            .default_present_mode = undefined,
            .mouse_active = false,
            .resolution_updated = false,
            .bg_max_framerate = 10,
            .fg_max_framerate = 60, // set reasonable defaults while the engine is loading
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

        var sampler_supported_formats: std.EnumSet(renderite.shared.TextureFormat) = .initEmpty();
        var cubemap_supported_formats: std.EnumSet(renderite.shared.TextureFormat) = .initEmpty();
        for (std.enums.values(renderite.shared.TextureFormat)) |renderite_format| {
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
                log.debug(@src(), "GPU supports {s}/{s} for samplers", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
            } else {
                log.debug(@src(), "GPU does not support {s}/{s} for samplers", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
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
                log.debug(@src(), "GPU supports {s}/{s} for cubemaps", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
            } else {
                log.debug(@src(), "GPU does not support {s}/{s} for cubemaps", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
            }
        }

        // SAFETY: this call never fails if we pass a valid GPU device handle, which we should always have
        log.info(@src(), "Acquired OpenXR GPU device with driver {s}", .{gpu_device.getDriver() catch unreachable});

        try gpu_device.claimWindow(window_data.window);

        const composition_mode: gpu.SwapchainComposition = .sdr_linear;
        const present_mode_preferences: []const gpu.PresentMode = &.{
            .mailbox,
            .immediate,
            .vsync,
        };

        var present_mode: gpu.PresentMode = undefined;

        if (!gpu_device.windowSupportsSwapchainComposition(window_data.window, composition_mode)) {
            log.err(@src(), "Window does not support the composition mode ({s}) we want. Cannot continue.", .{@tagName(composition_mode)});
            return error.UnsupportCompositionMode;
        }

        for (present_mode_preferences) |present_mode_preference| {
            if (gpu_device.windowSupportsPresentMode(window_data.window, present_mode_preference)) {
                try gpu_device.setSwapchainParameters(window_data.window, composition_mode, present_mode_preference);

                present_mode = present_mode_preference;
                log.debug(@src(), "Using swapchain parameters: composition={any},present={any}", .{ composition_mode, present_mode_preference });
                break;
            }
        } else {
            log.err(@src(), "Window supports none of our wanted present modes. VR performance may be impacted strongly.", .{});
        }

        window_data.swapchain_format = gpu_device.getSwapchainTextureFormat(window_data.window);
        window_data.composition_mode = composition_mode;
        window_data.present_mode = present_mode;
        window_data.default_present_mode = present_mode;

        log.debug(@src(), "Using window swapchain format {s}", .{@tagName(window_data.swapchain_format)});

        const test_vertex_shader: GpuShader = try .create(
            arena,
            gpu_device,
            @embedFile("shader-basic-vertex-spirv"),
            @embedFile("shader-basic-vertex-reflection"),
            .{ .spirv = true },
            "main",
            .vertex,
        );
        errdefer test_vertex_shader.deinit(gpu_device);

        const test_fragment_shader: GpuShader = try .create(
            arena,
            gpu_device,
            @embedFile("shader-basic-fragment-spirv"),
            @embedFile("shader-basic-fragment-reflection"),
            .{ .spirv = true },
            "main",
            .fragment,
        );
        errdefer test_fragment_shader.deinit(gpu_device);

        const window_test_pipeline: GraphicsPipeline = try .create(
            gpu_device,
            window_data.swapchain_format,
            test_vertex_shader,
            test_fragment_shader,
        );

        break :create_graphics_data .{
            .device = gpu_device,
            .sampler_supported_formats = sampler_supported_formats,
            .cubemap_supported_formats = cubemap_supported_formats,
            .transfer_buffer_pool = .init(gpu_device),
            .fence_manager = .init(gpu_device),
            .window_test_pipeline = window_test_pipeline,
            .depth_texture = null,
            .depth_texture_size = .{ .x = 0, .y = 0 },
            .upload_nonce = .init(0),
        };
    };
    errdefer graphics_data.deinit(gpa);

    // TODO: make ImGui an optional build dependency
    var maybe_imgui_data: ?ImGuiManager = create_imgui_data: {
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

        log.info(@src(), "Initialized ImGui SDL3 backend", .{});

        try imgui.gpu.init(.{
            .color_target_format = window_data.swapchain_format,
            .device = graphics_data.device,
            .msaa_samples = .no_multisampling,
        });
        errdefer imgui.gpu.shutdown();

        log.info(@src(), "Initialized ImGui GPU backend", .{});

        var io = context.getIo();
        io.ConfigFlags = io.ConfigFlags | imgui.c.ImGuiConfigFlags_NoMouseCursorChange;

        break :create_imgui_data .init(context, app);
    };
    errdefer if (maybe_imgui_data) |*imgui_data| imgui_data.deinit(gpa);

    const game_data = create_game_data: {
        const input: Input = try .init(gpa);
        errdefer input.deinit();

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
            .input = input,
            .perf = PerformanceMonitor.init(),
            .render_spaces = .empty,
            .render_spaces_lock = .{},
            .head_output = .init(),
            .desktop_fov = 90,
            .near_z = 0.1,
            .far_z = 1000,
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

    self.game.deinit(gpa, self.graphics_data.device);
    self.messaging.deinit(gpa);
    if (self.imgui_data) |*imgui_data| imgui_data.deinit(gpa);
    if (self.xr) |xr| xr.deinit(gpa);
    self.assets.deinit(gpa, self.graphics_data.device);
    self.graphics_data.deinit(gpa);
    self.window.deinit();

    gpa.destroy(self);
}

fn beginExit(self: *App) void {
    if (self.game.load_state.full_init) {
        self.game.exiting = true;
        self.messaging.host.primary.sendTimeout(.{ .RendererShutdownRequest = .{} }, std.time.ns_per_s) catch {
            log.warn(@src(), "Failed to send shutdown request, exiting without waiting for engine", .{});
            self.game.run_loop = false;
        };
    } else {
        self.game.run_loop = false;
    }
}

fn handleRendererCommand(
    self: *App,
    renderer_command: renderite.messaging.ParsedCommand,
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

            log.debug(@src(), "Setting window title to {s}", .{title});

            try self.window.window.setTitle(title);
            try self.window.window.raise();

            self.game.head_output_device = renderer_init_data.outputDevice;
            self.game.main_process_pid = renderer_init_data.mainProcessId;

            log.debug(@src(), "Head output device updated to {s}", .{@tagName(self.game.head_output_device)});
            log.debug(@src(), "Main process PID {d}", .{renderer_init_data.mainProcessId});

            const formats = comptime std.enums.values(renderite.shared.TextureFormat);

            const supported_formats = self.graphics_data.sampler_supported_formats.unionWith(self.graphics_data.cubemap_supported_formats);
            const supported_formats_len = supported_formats.count();

            var supported_formats_buf: [formats.len]renderite.shared.TextureFormat = undefined;
            var i: usize = 0;
            for (formats) |format| {
                if (supported_formats.contains(format)) {
                    log.trace(@src(), "Sending format {s} as supported", .{@tagName(format)});
                    supported_formats_buf[i] = format;
                    i += 1;
                }
            }

            var shmem_prefix = &self.messaging.shmem_prefix;

            shmem_prefix.len = try std.unicode.utf16LeToUtf8(&shmem_prefix.buffer, renderer_init_data.sharedMemoryPrefix);
            self.messaging.accessor = try SharedMemoryAccessor.init(self.gpa, self.messaging.shmem_prefix.constSlice());

            log.debug(@src(), "Set shmem prefix to {s} (len {d})", .{ shmem_prefix.constSlice(), shmem_prefix.len });

            try self.messaging.host.primary.sendTimeout(.{
                .RendererInitResult = .{
                    .actualOutputDevice = self.game.head_output_device,
                    .stereoRenderingMode = std.unicode.utf8ToUtf16LeStringLiteral("MultiPass"), // out of MultiPass, SinglePass, SinglePassInstanced, SinglePassMultiView
                    .rendererIdentifier = std.unicode.utf8ToUtf16LeStringLiteral("Gloobie"),
                    .mainWindowHandlePtr = 0,
                    .isGPUTexturePOTByteAligned = true, // TODO: determine this by if we support VK_FORMAT_R8G8B8_UNORM and other such formats
                    .maxTextureSize = 16384, // TODO: determine this from GPU code
                    .supportedTextureFormats = supported_formats_buf[0..supported_formats_len],
                },
            }, std.time.ns_per_s * 10);

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
            log.info(@src(), "Engine is requesting that we shut down, beginning exit", .{});
            self.game.run_loop = false;
        },
        .RendererInitFinalizeData => |_| {
            self.game.load_state.full_init = true;
            log.info(@src(), "Engine is fully loaded!", .{});
        },
        .KeepAlive => {
            // do nothing
        },
        .DesktopConfig => |desktop| {
            log.debug(@src(), "Desktop Settings: vsync={any},bg={?d},fg={?d}", .{ desktop.vSync, desktop.maximumBackgroundFramerate, desktop.maximumForegroundFramerate });

            self.window.bg_max_framerate = if (desktop.maximumBackgroundFramerate) |framerate| @intCast(framerate) else null;

            // TODO: Read maximum foreground framerate. Depends on https://github.com/Yellow-Dog-Man/Resonite-Issues/issues/5269
            // We can't do so now since the nature of the bug means that it's uninitialized memory.
            // self.window.fg_max_framerate = if (desktop.maximumForegroundFramerate) |framerate| @intCast(framerate) else null;
            self.window.fg_max_framerate = null;

            try self.updateVSync(desktop.vSync);
        },
        .ResolutionConfig => |resolution| {
            log.debug(@src(), "Window Settings: res={any},fullscreen={any}", .{ resolution.resolution, resolution.fullscreen });
            self.window.fullscreen = resolution.fullscreen;
            try self.window.window.setSize(@intCast(resolution.resolution.x), @intCast(resolution.resolution.y));
            try self.window.window.setResizable(true);

            // If one of the extants matches the primary display resolution, the window was probably maximized on that monitor.
            // Restore that state here, because this is a personal annoyance of mine. -jvy
            if (self.getPrimaryDisplay()) |display| {
                if (display.resolution.x == resolution.resolution.x or display.resolution.y == resolution.resolution.y) {
                    try self.window.window.maximize();
                }
            }

            self.window.resolution_updated = true;
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
            self.assets.unloadTexture(.{
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
            self.assets.unloadMesh(.from(mesh_unload.assetId), self.gpa, self.graphics_data.device);
        },
        .ShaderUpload => |shader_upload| {
            // TODO: load the associated shader in this case
            try self.messaging.host.background.sendTimeout(.{ .ShaderUploadResult = .{
                .assetId = shader_upload.assetId,
                .instanceChanged = true,
            } }, std.time.ns_per_s * 10);
        },
        .ShaderUnload => |shader_unload| {
            // TODO: unload the loaded shader
            _ = shader_unload;
        },
        .FrameSubmitData => {
            std.debug.panic("This should be handled by the other thread!", .{});
        },
        .MaterialPropertyIdRequest => |material_property_id_request| {
            const property_ids = try frame_context.arena.alloc(i32, material_property_id_request.propertyNames.len);
            defer frame_context.arena.free(property_ids);

            // TODO: handle this properly, when we can
            for (material_property_id_request.propertyNames, property_ids) |property_name, *property_id| {
                log.trace(@src(), "Material property name: {f}", .{std.unicode.fmtUtf16Le(property_name)});

                property_id.* = 0;
            }

            try self.messaging.host.primary.sendTimeout(.{
                .MaterialPropertyIdResult = .{
                    .requestId = material_property_id_request.requestId,
                    .propertyIDs = property_ids,
                },
            }, std.time.ns_per_s * 10);
        },
        .MaterialsUpdateBatch => |materials_update_batch| {
            try self.assets.handleMaterialUpdate(self.gpa, frame_context, &self.messaging.accessor.?, materials_update_batch);
        },
        .SetRenderTextureFormat => |set_render_target_format| {
            // TODO: actually create render targets
            try self.messaging.host.background.sendTimeout(
                .{ .RenderTextureResult = .{
                    .assetId = set_render_target_format.assetId,
                    .instanceChanged = true,
                } },
                std.time.ns_per_s * 10,
            );
        },
        else => {
            log.warn(@src(), "Unhandled command type {s}", .{@tagName(command)});
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

fn messagingCallback(self: *App, queue_type: MessagingHost.QueueManager.Type, message: renderite.messaging.ParsedCommand) void {
    log.trace(@src(), "Got message {s} on queue {s}", .{ @tagName(message.command), @tagName(queue_type) });

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
            if (message.command == .DesktopConfig) {
                self.sendLetterToMain(.{
                    .renderer_command = .{ .command = message, .queue_type = queue_type },
                }) catch |err| std.debug.panic("Failed to send letter: {any}", .{err});
                return;
            }

            // FIXME: push resource uploads onto another thread!
            var arena_impl: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena_impl.deinit();

            var frame_context: graphics.FrameContext = .init(self, arena_impl.allocator());
            defer frame_context.deinit(self.gpa);

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

fn updateRenderSpaces(
    self: *App,
    arena: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    updates: []const renderite.shared.RenderSpaceUpdate,
) !void {
    self.game.render_spaces_lock.lock();
    defer self.game.render_spaces_lock.unlock();

    for (self.game.render_spaces.values()) |*render_space| {
        render_space.clearUpdated();
    }

    self.assets.lock.lockShared();
    defer self.assets.lock.unlockShared();

    // SAFETY: messaging accessor should always be available by now!
    const accessor = &self.messaging.accessor.?;

    var active_render_space: RenderSpace.Id = .invalid;
    for (updates) |update| {
        const render_space = self.game.render_spaces.getPtr(.from(update.id)) orelse create_render_space: {
            var render_space: RenderSpace = try .init(update);
            errdefer render_space.deinit(self.gpa, self.graphics_data.device);

            log.debug(@src(), "Created render space {d}", .{update.id});

            try self.game.render_spaces.putNoClobber(self.gpa, .from(update.id), render_space);

            // SAFETY: we just placed it in, so this should be safe!
            break :create_render_space self.game.render_spaces.getPtr(.from(update.id)).?;
        };

        try render_space.handleUpdateLocked(self.gpa, arena, frame_context, accessor, update);

        if (render_space.properties.active and !render_space.properties.overlay) {
            if (active_render_space != .invalid) {
                log.err(@src(), "Render space {d} is active when render space {d} was already found to be active!", .{ update.id, active_render_space.to() });
                return error.MultipleActiveRenderSpaces;
            }

            active_render_space = render_space.id;
        }
    }

    {
        var i: usize = 0;
        while (i < self.game.render_spaces.count()) {
            const render_space = &self.game.render_spaces.values()[i];

            if (render_space.updated) {
                i += 1;
            } else {
                render_space.deinit(self.gpa, self.graphics_data.device);

                log.debug(@src(), "Render space {d} removed", .{render_space.id.to()});
                const removed = self.game.render_spaces.swapRemove(render_space.id);
                std.debug.assert(removed);
            }
        }
    }
}

fn engineHandleMessage(self: *App, message: renderite.messaging.ParsedCommand) !void {
    defer message.arena.deinit();

    var arena_impl: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var frame_context: graphics.FrameContext = .init(self, arena);
    defer frame_context.deinit(self.gpa);

    // SAFETY: only this message should be sent to the engine thread
    const frame_submit_data = message.command.FrameSubmitData;

    if (frame_submit_data.outputState) |output_state| {
        try self.sendLetterToMain(.{ .handle_output_state = output_state });
    }

    self.game.last_frame_index = frame_submit_data.frameIndex;
    log.trace(@src(), "Frame {d} completion", .{frame_submit_data.frameIndex});

    try self.updateRenderSpaces(
        arena,
        &frame_context,
        frame_submit_data.renderSpaces,
    );
    self.game.desktop_fov = frame_submit_data.desktopFOV;
    self.game.near_z = frame_submit_data.nearClip;
    self.game.far_z = frame_submit_data.farClip;

    try frame_context.end(self.gpa);

    self.game.engine_thread_ready_for_begin_frame.set();
}

fn engineLoop(self: *App) !void {
    self.game.engine_thread_ready_for_begin_frame.set();

    while (!self.game.engine_thread_cancellation.isSet()) {
        const message = self.game.to_engine_mailbox.receive(std.time.ns_per_s * 1) catch |err| {
            // Timeouts are nonfatal.
            if (err == error.Timeout) {
                log.trace(@src(), "Engine wait timeout", .{});
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
            if (builtin.os.tag == .ios or builtin.abi.isAndroid())
                160
            else
                96;

        const dpi: f32 = try display.getContentScale() * dpi_scale;

        const natural_orientation: sdl3.video.Display.Orientation = display.getNaturalOrientation() orelse .landscape;
        const current_orientation: sdl3.video.Display.Orientation = display.getCurrentOrientation() orelse .landscape;

        const renderite_orientation: renderite.shared.RectOrientation = switch (natural_orientation) {
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

        const renderite_display: renderite.shared.DisplayState = .{
            .offset = .{ .x = bounds.x, .y = bounds.y },
            .displayIndex = @intCast(index),
            .dpi = .{ .x = dpi, .y = dpi },
            .isPrimary = display.value == primary_display.value,
            .orientation = renderite_orientation,
            .refreshRate = display_mode.refresh_rate orelse 60,
            .resolution = .{ .x = @intCast(display_mode.width), .y = @intCast(display_mode.height) },
        };
        try self.game.displays.append(self.gpa, renderite_display);

        log.debug(@src(), "Got display {d} with size {d}x{d}", .{ index, display_mode.width, display_mode.height });
    }
}

fn getPrimaryDisplay(self: *App) ?renderite.shared.DisplayState {
    for (self.game.displays.items) |display| {
        if (display.isPrimary)
            return display;
    }

    return null;
}

fn updateVSync(self: *App, vsync: bool) !void {
    const present_mode = if (vsync) .vsync else self.window.default_present_mode;

    if (present_mode == self.window.present_mode)
        return;

    if (!self.window.window.hasSurface())
        return;

    // SAFETY: The default present mode was guaranteed to be supported on startup
    if (!self.graphics_data.device.windowSupportsPresentMode(self.window.window, present_mode))
        unreachable;

    try self.graphics_data.device.setSwapchainParameters(self.window.window, self.window.composition_mode, present_mode);
    self.window.present_mode = present_mode;
}

fn applyOutputState(self: *App, output_state: renderite.shared.OutputState) !void {
    if (sdl3.keyboard.textInputActive(self.window.window) != output_state.keyboardInputActive) {
        if (output_state.keyboardInputActive) {
            try sdl3.keyboard.startTextInput(self.window.window);
            log.debug(@src(), "Starting text input", .{});
        } else {
            try sdl3.keyboard.stopTextInput(self.window.window);
            log.debug(@src(), "Stopping text input", .{});
        }
    }

    const imgui_open = if (self.imgui_data) |imgui_data| imgui_data.open else false;
    const locking_cursor = output_state.lockCursor and !imgui_open;

    try sdl3.mouse.setWindowRelativeMode(self.window.window, locking_cursor);

    if (locking_cursor) {
        const size = try self.window.window.getSize();
        sdl3.mouse.warpInWindow(self.window.window, @as(f32, @floatFromInt(size.width)) / 2.0, @as(f32, @floatFromInt(size.height)) / 2.0);
    }
}

pub fn frameLoop(self: *App) !void {
    self.game.engine_thread = try .spawn(.{}, engineLoop, .{self});

    try self.messaging.host.start(self.gpa);

    self.updateDisplays() catch |err| {
        log.err(@src(), "Failed to update displays, got err {s}", .{@errorName(err)});
    };

    var arena_impl: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    while (self.game.run_loop) {
        tracy.frameMark();
        self.game.perf.beginRenderFrame();
        defer self.game.perf.endRenderFrame();

        // keep 10mb in the arena
        defer _ = arena_impl.reset(.{ .retain_with_limit = 10 * 1000 * 1000 });

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
                            log.err(@src(), "Failed to update displays, got err {s}", .{@errorName(err)});
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
                    .window_mouse_enter => |window| if (window.id == self.window.window.getId() catch unreachable) {
                        self.window.mouse_active = true;
                    },
                    .window_mouse_leave => |window| if (window.id == self.window.window.getId() catch unreachable) {
                        self.window.mouse_active = false;
                    },
                    .key_down => |key_down| if (key_down.window_id == self.window.window.getId() catch unreachable) {
                        self.game.input.handleKeyEvent(key_down);

                        const key = key_down.key orelse return;
                        var imgui_data = &(self.imgui_data orelse return);

                        if (key_down.mod.altDown() and !key_down.mod.shiftDown() and !key_down.mod.controlDown() and key == .func3) {
                            imgui_data.open = !imgui_data.open;
                        }
                    },
                    .key_up => |key_up| {
                        if (key_up.window_id == self.window.window.getId() catch unreachable) {
                            self.game.input.handleKeyEvent(key_up);
                        }
                    },
                    .text_input => |text_input| {
                        if (text_input.window_id == self.window.window.getId() catch unreachable) {
                            try self.game.input.handleTextInputUtf8(self.gpa, text_input.text);
                        }
                    },
                    .mouse_button_down => |mouse_down| {
                        if (mouse_down.window_id == self.window.window.getId() catch unreachable) {
                            self.game.input.handleMouseButtonEvent(mouse_down);
                        }
                    },
                    .mouse_button_up => |mouse_up| {
                        if (mouse_up.window_id == self.window.window.getId() catch unreachable) {
                            self.game.input.handleMouseButtonEvent(mouse_up);
                        }
                    },
                    .mouse_wheel => |mouse_wheel| {
                        if (mouse_wheel.window_id == self.window.window.getId() catch unreachable) {
                            self.game.input.handleMouseScrollEvent(mouse_wheel);
                        }
                    },
                    .mouse_motion => |mouse_motion| {
                        if (mouse_motion.window_id == self.window.window.getId() catch unreachable) {
                            self.game.input.handleMouseMotionEvent(mouse_motion);
                        }
                    },
                    .drop_file => |file| {
                        try self.game.input.handleDroppedFile(self.gpa, file);
                    },
                    .drop_text => |text| {
                        try self.game.input.handleTextInputUtf8(self.gpa, text.text);
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
        var frame_context: graphics.FrameContext = .initMain(self, command_buffer, arena);
        defer frame_context.deinit(self.gpa);

        {
            const swapchain_texture_result = acquire_swapchain_texture: {
                const trace = tracy.traceNamed(@src(), "Acquire Swapchain Texture");
                defer trace.end();

                break :acquire_swapchain_texture try command_buffer.acquireSwapchainTexture(self.window.window);
            };
            const maybe_swapchain_texture, const swapchain_width, const swapchain_height = .{ swapchain_texture_result.texture, swapchain_texture_result.width, swapchain_texture_result.height };

            // send a frame start if the engine thread is waiting for us to do so
            if (self.game.load_state.full_init and self.game.engine_thread_ready_for_begin_frame.isSet()) {
                const dropped_files = try self.game.input.takeDroppedFiles(self.gpa);
                defer if (dropped_files) |files| {
                    for (files.paths) |file| {
                        self.gpa.free(file);
                    }
                    self.gpa.free(files.paths);
                };

                try self.messaging.host.primary.sendTimeout(.{
                    .FrameStartData = .{
                        .lastFrameIndex = self.game.last_frame_index,
                        .inputs = .{
                            .displays = self.game.displays.items,
                            .gamepads = &.{},
                            .keyboard = .{
                                .heldKeys = self.game.input.held_keys.keys(),
                                .typeDelta = self.game.input.takeTypedDelta(),
                            },
                            .mouse = .{
                                .leftButtonState = self.game.input.left_click_held,
                                .middleButtonState = self.game.input.middle_click_held,
                                .rightButtonState = self.game.input.right_click_held,
                                .button4State = self.game.input.x1_click_held,
                                .button5State = self.game.input.x2_click_held,
                                .desktopPosition = self.game.input.mouse_desktop_pos,
                                .directDelta = self.game.input.takeMouseDelta(),
                                .isActive = self.window.mouse_active,
                                .scrollWheelDelta = self.game.input.takeScrollDelta(),
                                .windowPosition = self.game.input.mouse_window_pos,
                            },
                            .touches = &.{},
                            .vr = null,
                            .window = .{
                                .isFullscreen = self.window.fullscreen,
                                .isWindowFocused = self.window.focus,
                                .dragAndDropEvent = dropped_files,
                                // TODO: should this be window size or swapchain size?
                                .windowResolution = .{
                                    .x = @intCast(swapchain_width),
                                    .y = @intCast(swapchain_height),
                                },
                                .resolutionSettingsApplied = self.window.takeResolutionUpdate(),
                            },
                        },
                        .performance = self.game.perf.state,
                        .renderedReflectionProbes = &.{},
                        .videoClockErrors = &.{},
                    },
                }, std.time.ns_per_s);

                log.trace(@src(), "Sent frame {d} start", .{self.game.last_frame_index + 1});

                self.game.engine_thread_ready_for_begin_frame.reset();
            }

            const wait_on_engine = true;
            if (wait_on_engine) {
                const trace = tracy.traceNamed(@src(), "Waiting on engine");
                defer trace.end();

                self.game.engine_thread_ready_for_begin_frame.timedWait(std.time.ns_per_ms * 100) catch |err| {
                    if (err == error.Timeout) {
                        log.trace(@src(), "FrooxEngine running really slow, no new frame :(", .{});
                    } else {
                        return err;
                    }
                };
            }

            // handle any messages from the queues, happens before processing most of the frame/rendering
            try handleMessages(self, &frame_context);

            // end frame context, frame is over
            try frame_context.end(self.gpa);

            // tick assets
            self.assets.mainThreadTick(self.gpa, self.graphics_data.device);

            if (self.imgui_data) |*imgui_data| {
                const trace = tracy.traceNamed(@src(), "ImGui start frame");
                defer trace.end();

                if (imgui_data.open)
                    try imgui_data.start();
            }

            if (maybe_swapchain_texture) |swapchain_texture| {
                const render_trace = tracy.traceNamed(@src(), "Render Frame");
                defer render_trace.end();

                if (swapchain_width != self.graphics_data.depth_texture_size.x or swapchain_height != self.graphics_data.depth_texture_size.y) {
                    if (self.graphics_data.depth_texture) |depth_texture| {
                        self.graphics_data.device.releaseTexture(depth_texture);
                    }

                    self.graphics_data.depth_texture = try self.graphics_data.device.createTexture(.{
                        .format = .depth32_float,
                        .width = swapchain_width,
                        .height = swapchain_height,
                        .layer_count_or_depth = 1,
                        .num_levels = 1,
                        .usage = .{ .depth_stencil_target = true },
                    });
                    self.graphics_data.depth_texture_size = .{
                        .x = @intCast(swapchain_width),
                        .y = @intCast(swapchain_height),
                    };
                }

                try self.game.head_output.addDesktopView(
                    self.gpa,
                    self.game.desktop_fov,
                    self.game.near_z,
                    self.game.far_z,
                    swapchain_width,
                    swapchain_height,
                    swapchain_texture,
                    self.graphics_data.depth_texture.?,
                );
                try self.game.head_output.renderScene(arena, self, command_buffer);

                const imgui_draw_data = if (self.imgui_data != null and self.imgui_data.?.open) ImGuiManager.getDrawData(command_buffer) else null;

                const render_pass = command_buffer.beginRenderPass(&.{.{
                    .texture = swapchain_texture,
                    .load = .load,
                    .store = .store,
                }}, null);

                if (imgui_draw_data) |draw_data| {
                    ImGuiManager.draw(draw_data, command_buffer, render_pass);
                }

                render_pass.end();
            }
        }
        {
            const trace = tracy.traceNamed(@src(), "Submit Command Buffer");
            defer trace.end();

            // lock assets in preparation to upload
            self.assets.lock.lock();
            defer self.assets.lock.unlock();

            try command_buffer.submit();

            // Now that command buffers are submit, we need to update the readyness states
            try frame_context.pushReadyAssets(self.gpa);
        }

        self.graphics_data.transfer_buffer_pool.frameTick();
    }
}

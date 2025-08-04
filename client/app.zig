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
    host: renderite.MessagingHost,

    to_render: ToRenderMailbox,
    to_render_envelope_pool: std.heap.MemoryPool(ToRenderMailbox.Envelope),

    letter_allocation_mutex: std.Thread.Mutex,

    pub fn deinit(self: *MessagingData) void {
        self.host.deinit();

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

    pub fn deinit(self: ImGuiData) void {
        imgui_t.gpu.shutdown();
        imgui_t.sdl3.shutdown();
        self.context.destroy();
    }
};

const LoadState = enum(i32) {
    awaiting_engine = 0,
    processing_startup_commands = 1,
    scanning_locales = 2,
    loading_config_json = 3,
    computing_compatibility_hash = 4,
    initializing_frooxengine = 5,
    initializing_input_interface = 6,
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

pub fn init(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    errdefer gpa.destroy(app);

    const messaging_data: MessagingData = create_messaging_data: {
        const host = renderite.MessagingHost.initFromArgs(messagingCallback, app, gpa) catch |err| debug_queue: {
            log.warn("Failed to initialize messaging manager from command line arguments: {s}, setting up dummy queue", .{@errorName(err)});
            break :debug_queue try renderite.MessagingHost.init("gloopie", 8388608, messagingCallback, app);
        };
        errdefer host.deinit();

        break :create_messaging_data .{
            .host = host,
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
        if (xr_data) |xr| {
            const gpu_device = xr.backend.getGpuDevice();

            log.info("Acquired OpenXR GPU device with driver {s}", .{gpu_device.getDriver() catch unreachable});

            break :create_graphics_data .{
                .device = gpu_device,
            };
        } else {
            const gpu_device = try gpu.Device.initWithProperties(.{
                .debug_mode = build_options.safety,
                // TODO: Once we get the ability to transpile to other shader types, specify them here!
                .shaders_spirv = true,
            });
            errdefer gpu_device.deinit();

            // SAFETY: this call never fails if we pass a valid GPU device handle, which we should always have
            log.info("Created GPU device with driver {s}", .{gpu_device.getDriver() catch unreachable});

            break :create_graphics_data .{
                .device = gpu_device,
            };
        }
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
        };
    };
    errdefer if (imgui_data) |imgui| imgui.deinit();

    const game_data: GameData = .{
        .run_loop = true,
        .head_output_device = .UNKNOWN,
        .main_process_pid = null,
        .load_state = .awaiting_engine,
    };

    app.* = .{
        .gpa = gpa,
        .xr = xr_data,
        .graphics = graphics_data,
        .window = window_data,
        .messaging = messaging_data,
        .imgui = imgui_data,
        .game = game_data,
    };

    return app;
}

pub fn deinit(self: *App) void {
    self.messaging.deinit();
    if (self.imgui) |imgui| imgui.deinit();
    if (self.xr) |xr| xr.deinit(self.gpa);
    self.graphics.deinit();
    self.window.deinit();

    const gpa = self.gpa;
    gpa.destroy(self);
}

fn beginExit(self: *App) void {
    self.game.run_loop = false;
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
                defer renderer_command.arena.deinit();

                const command = renderer_command.command;

                log.debug("Recieved command {s}", .{@tagName(command)});

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
                    },
                    .RendererInitProgressUpdate => |renderer_init_progress_update| {
                        self.game.load_state = @enumFromInt(renderer_init_progress_update.phaseIndex);

                        log.debug("Renderer init progress update: force show: {}, phase: \"{f}\", phase index: {d}, sub phase: \"{f}\"", .{
                            renderer_init_progress_update.forceShow,
                            std.unicode.fmtUtf16Le(renderer_init_progress_update.phase),
                            renderer_init_progress_update.phaseIndex,
                            std.unicode.fmtUtf16Le(renderer_init_progress_update.subPhase),
                        });
                    },
                    else => {
                        log.warn("Unhandled command type {s}", .{@tagName(command)});
                    },
                }
            },
        }
    }
}

fn messagingCallback(ctx: *anyopaque, message: renderite.ParsedCommand) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.sendLetter(.{ .renderer_command = message }) catch |err| std.debug.panic("Failed to send letter: {any}", .{err});
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
                // ignore ret, doesnt help us
                _ = imgui_t.sdl3.processEvent(event);

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

        {
            const trace = tracy.traceNamed(@src(), "ImGui start frame");
            defer trace.end();

            // imgui new frame
            imgui_t.gpu.newFrame();
            imgui_t.sdl3.newFrame();
            imgui_t.newFrame();
        }

        var show_demo_window: bool = true;
        imgui_t.showDemoWindow(&show_demo_window);

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

        {
            const trace = tracy.traceNamed(@src(), "ImGui render");
            defer trace.end();

            imgui_t.render();
        }
        const draw_data = imgui_t.getDrawData();
        const is_minimized = draw_data.DisplaySize.x <= 0.0 or draw_data.DisplaySize.y <= 0.0;

        if (maybe_swapchain_texture) |swapchain_texture| {
            const trace = tracy.traceNamed(@src(), "Render Frame");
            defer trace.end();

            if (!is_minimized) {
                imgui_t.gpu.prepareDrawData(draw_data, command_buffer);
            }

            const render_pass = command_buffer.beginRenderPass(&.{.{
                .texture = swapchain_texture,
                .clear_color = .{ .a = 1.0 },
                .load = .clear,
            }}, null);

            if (!is_minimized) {
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

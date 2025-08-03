const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const imgui_t = @import("imgui");
const MessagingManager = @import("renderite").MessagingManager;
const sdl3 = @import("sdl3");
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

const MessagingData = struct {
    manager: MessagingManager,

    pub fn deinit(self: MessagingData) void {
        self.manager.deinit();
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

const GameData = struct {
    run_loop: bool,
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
        const manager = MessagingManager.initFromArgs(gpa) catch debug_queue: {
            log.warn("Failed to initialize messaging manager from command line arguments, setting up dummy queue", .{});
            break :debug_queue try MessagingManager.init("gloopie", false, 8388608, gpa);
        };
        errdefer manager.deinit();

        break :create_messaging_data .{ .manager = manager };
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
            _ = xr; // autofix

            @panic("TODO: XR based graphics init");
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

    // TODO: figure out if this is the correct composition mode
    const composition_mode: gpu.SwapchainComposition = .sdr;
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
    if (self.imgui) |imgui| imgui.deinit();
    self.graphics.deinit();
    self.window.deinit();
    if (self.xr) |xr| xr.deinit(self.gpa);

    const gpa = self.gpa;
    gpa.destroy(self);
}

fn beginExit(self: *App) void {
    self.game.run_loop = false;
}

pub fn frameLoop(self: *App) !void {
    while (self.game.run_loop) {
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

        // imgui new frame
        imgui_t.gpu.newFrame();
        imgui_t.sdl3.newFrame();
        imgui_t.newFrame();

        var show_demo_window: bool = true;
        imgui_t.showDemoWindow(&show_demo_window);

        const command_buffer = try self.graphics.device.acquireCommandBuffer();

        const swapchain_texture_result = try command_buffer.acquireSwapchainTexture(self.window.window);
        const maybe_swapchain_texture, const swapchain_width, const swapchain_height = .{ swapchain_texture_result.texture, swapchain_texture_result.width, swapchain_texture_result.height };
        _ = swapchain_height; // autofix
        _ = swapchain_width; // autofix

        imgui_t.render();
        const draw_data = imgui_t.getDrawData();
        const is_minimized = draw_data.DisplaySize.x <= 0.0 or draw_data.DisplaySize.y <= 0.0;

        if (maybe_swapchain_texture) |swapchain_texture| {
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

        try command_buffer.submit();
    }
}

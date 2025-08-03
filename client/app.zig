const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const sdl3 = @import("sdl3");
const xr_t = @import("xr");
const MessagingManager = @import("renderite").MessagingManager;

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

gpa: std.mem.Allocator,
xr: ?XrData,
graphics: GraphicsData,
window: WindowData,
messaging: MessagingData,

pub fn init(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    errdefer gpa.destroy(app);

    const messaging_data: MessagingData = create_messaging_data: {
        const manager = MessagingManager.initFromArgs(gpa) catch debug_queue: {
            log.warn("Failed to initialize messaging manager from command line arguments, setting up dummy queue", .{});
            break :debug_queue try MessagingManager.init("gloopie", false, 1024 * 1024, gpa);
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

    const window_data: WindowData = create_window_data: {
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

    app.* = .{
        .gpa = gpa,
        .xr = xr_data,
        .graphics = graphics_data,
        .window = window_data,
        .messaging = messaging_data,
    };

    return app;
}

pub fn deinit(self: *App) void {
    self.graphics.deinit();
    self.window.deinit();
    if (self.xr) |xr| xr.deinit(self.gpa);

    const gpa = self.gpa;
    gpa.destroy(self);
}

pub fn frameLoop(self: *App) !void {
    _ = self; // autofix
}

const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
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

gpa: std.mem.Allocator,
xr: ?XrData,
graphics: GraphicsData,

pub fn init(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    errdefer gpa.destroy(app);

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

    const graphics_data: GraphicsData = create_graphics_data: {
        if (xr_backend) |backend| {
            _ = backend; // autofix

            @panic("TODO: XR based graphics init");
        } else {
            const device_props: gpu.Device.Properties = .{
                .debug_mode = build_options.safety,
                // TODO: Once we get the ability to transpile to other shader types, specify them here!
                .shaders_spirv = true,
            };
            const gpu_device = try gpu.Device.initWithProperties(device_props);
            errdefer gpu_device.deinit();

            // SAFETY: this call never fails if we pass a valid GPU device handle, which we should always have
            log.info("Created GPU device with driver {s}", .{gpu_device.getDriver() catch unreachable});

            break :create_graphics_data .{
                .device = gpu_device,
            };
        }
    };

    app.* = .{
        .gpa = gpa,
        .xr = if (xr_backend) |backend| .{ .backend = backend } else null,
        .graphics = graphics_data,
    };

    return app;
}

pub fn deinit(self: *App) void {
    self.graphics.deinit();
    if (self.xr) |xr| xr.deinit(self.gpa);

    const gpa = self.gpa;
    gpa.destroy(self);
}

pub fn frameLoop(self: *App) !void {
    _ = self; // autofix
}

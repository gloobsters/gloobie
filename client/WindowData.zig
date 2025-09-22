const gpu = @import("gpu");
const sdl3 = @import("sdl3");

const WindowData = @This();

window: sdl3.video.Window,

fullscreen: bool,
focus: bool,
mouse_active: bool,
resolution_updated: bool,

bg_max_framerate: ?u32,
fg_max_framerate: ?u32,

pub fn init() !WindowData {
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

    return .{
        .window = window,
        .fullscreen = false,
        .focus = false,
        .mouse_active = false,
        .resolution_updated = false,
        .bg_max_framerate = 10,
        .fg_max_framerate = 60, // set reasonable defaults while the engine is loading
    };
}

pub fn takeResolutionUpdate(self: *WindowData) bool {
    defer self.resolution_updated = false;
    return self.resolution_updated;
}

pub fn deinit(self: WindowData) void {
    self.window.deinit();
}

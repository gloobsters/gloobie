const std = @import("std");
const builtin = @import("builtin");

const gpu = @import("gpu");
const sdl3 = @import("sdl3");

pub fn main() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{}) = .init;

    const gpa = if (std.debug.runtime_safety) debug_alloc_impl.allocator() else std.heap.smp_allocator;

    try sdl3.setMemoryFunctionsByAllocator(gpa);

    try sdl3.init(.{
        .video = true,
    });
    defer sdl3.shutdown();

    const properties_result = try sdl3.video.Window.initWithProperties(.{
        .resizable = true,
        .mouse_grabbed = true,
        .width = 1600,
        .height = 900,
        .title = "gloobie",

        .external_graphics_context = true,
        .vulkan = true, // TODO: support other graphics backends
    });
    const window = properties_result.window;
    properties_result.properties.deinit();

    defer window.deinit();

    var run: bool = true;
    while (run) {
        if (sdl3.events.poll()) |event| {
            switch (event) {
                .quit => {
                    run = false;
                },
                else => {},
            }
        }

        // TODO: create GPU context and submit frames
    }
}

const std = @import("std");
const builtin = @import("builtin");

const gpu = @import("gpu");
const sdl3 = @import("sdl3");
const xr = @import("xr");
const zinterprocess = @import("zinterprocess");
const renderite = @import("renderite");

pub fn main() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{}) = .init;

    const gpa = if (std.debug.runtime_safety) debug_alloc_impl.allocator() else std.heap.smp_allocator;

    // TODO: figure out why this crashes Windows + X11
    // try sdl3.setMemoryFunctionsByAllocator(gpa);

    try sdl3.init(.{
        .video = true,
    });
    defer sdl3.shutdown();

    const xr_backend = try xr.init(gpa);
    defer xr_backend.deinit(gpa);
}

test {
    _ = renderite.ColorProfile;
    _ = zinterprocess.Queue;
}

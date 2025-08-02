const std = @import("std");
const builtin = @import("builtin");

const gpu = @import("gpu");
const build_options = @import("options").build_options;
const sdl3 = @import("sdl3");
const xr = @import("xr");

pub fn main() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{}) = .init;
    defer if(build_options.safety and debug_alloc_impl.deinit() == .leak) {
        @panic("Memory leak!");
    };

    const gpa = if (build_options.safety) debug_alloc_impl.allocator() else std.heap.smp_allocator;

    try sdl3.init(.{
        .video = true,
    });
    defer sdl3.shutdown();
    defer if (sdl3.getNumAllocations()) |num_allocations| {
        if (num_allocations > 0) {
            std.debug.panic("SDL memory leak! {d} outstanding allocations.", .{num_allocations});
        }
    };

    const xr_backend = try xr.init(gpa);
    defer xr_backend.deinit(gpa);
}

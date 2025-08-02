const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const renderite = @import("renderite").Shared;
const sdl3 = @import("sdl3");
const xr = @import("xr");
const zinterprocess = @import("zinterprocess");

const App = @import("app.zig");

const log = std.log.scoped(.main);

pub fn main() !void {
    start() catch |err| {
        log.err("Got error: {s} running, latest SDL error: {?s}\n", .{ @errorName(err), sdl3.errors.get() });

        return err;
    };
}

fn sdl3ErrorCallback(err: ?[:0]const u8) void {
    log.err("Got SDL error {?s}", .{err});
}

fn start() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{}) = .init;
    defer if (build_options.safety and debug_alloc_impl.deinit() == .leak) {
        @panic("Memory leak!");
    };

    const gpa = if (build_options.safety) debug_alloc_impl.allocator() else std.heap.smp_allocator;

    sdl3.errors.error_callback = sdl3ErrorCallback;

    try sdl3.init(.{
        .video = true,
    });
    defer sdl3.shutdown();
    defer if (sdl3.getNumAllocations()) |num_allocations| {
        if (num_allocations > 0) {
            std.debug.panic("SDL memory leak! {d} outstanding allocations.", .{num_allocations});
        }
    };

    const app = try App.init(gpa);
    defer app.deinit();

    try app.frameLoop();
}

pub fn panic(
    msg: []const u8,
    trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = trace;

    log.err("Latest SDL error: {?s}\n", .{sdl3.errors.get()});

    std.debug.FullPanic(std.debug.defaultPanic).call(msg, ret_addr);
}

test {
    _ = renderite.ColorProfile;
    _ = zinterprocess.Queue;
}

const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");
const tracy = @import("tracy");
const xr = @import("xr");
const zinterprocess = @import("zinterprocess");

const App = @import("App.zig");

const log = std.log.scoped(.main);

comptime {
    _ = @import("tests.zig");
}

pub fn main() !void {
    start() catch |err| {
        log.err("Got error: {s} running, latest SDL error: {?s}\n", .{ @errorName(err), sdl3.errors.get() });

        return err;
    };
    log.info("Gloobie exiting...", .{});
}

fn sdl3ErrorCallback(err: ?[:0]const u8) void {
    log.err("Got SDL error {?s}", .{err});
}

fn start() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{}) = .init;
    defer if (build_options.safety and debug_alloc_impl.deinit() == .leak) {
        @panic("Memory leak!");
    };

    var tracy_allocator = tracy.tracyAllocator("General Purpose Allocator", if (build_options.safety) debug_alloc_impl.allocator() else std.heap.smp_allocator);
    const gpa = tracy_allocator.allocator();

    sdl3.errors.error_callback = sdl3ErrorCallback;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    {
        const trace = tracy.traceNamed(@src(), "Init SDL");
        defer trace.end();

        try sdl3.init(.{
            .video = true,
        });
    }
    defer sdl3.shutdown();
    defer if (sdl3.getNumAllocations()) |num_allocations| {
        if (num_allocations > 0) {
            std.debug.panic("SDL memory leak! {d} outstanding allocations.", .{num_allocations});
        }
    };

    const bootstrap = init_bootstrap: {
        const trace = tracy.traceNamed(@src(), "Bootstrap");
        defer trace.end();

        var bootstrap = try renderite.Bootstrap.init(args, gpa);
        errdefer bootstrap.deinit(gpa);

        break :init_bootstrap bootstrap;
    };

    const app = init_app: {
        const trace = tracy.traceNamed(@src(), "Init application");
        defer trace.end();

        break :init_app try App.init(gpa, bootstrap.init_settings);
    };
    defer app.deinit();

    app.frameLoop() catch |err| {
        log.err("Got error {s} in frame loop", .{@errorName(err)});

        return err;
    };
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

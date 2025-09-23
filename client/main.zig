const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const logger = @import("logger");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");
const tracy = @import("tracy");
const xr = @import("xr");
const zinterprocess = @import("zinterprocess");

const App = @import("App.zig");

const log = logger.Scoped(.main);

comptime {
    _ = @import("tests.zig");
}

pub fn main() !void {
    try start();

    std.debug.print("Gloobie exiting...\n", .{});
}

fn sdl3ErrorCallback(err: ?[:0]const u8) void {
    log.err(@src(), "Got SDL error {?s}", .{err});
}

fn start() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{
        .stack_trace_frames = 10,
    }) = .init;
    defer if (build_options.safety and debug_alloc_impl.deinit() == .leak) {
        @panic("Memory leak!");
    };

    var tracy_allocator = tracy.tracyAllocator("General Purpose Allocator", if (build_options.safety) debug_alloc_impl.allocator() else std.heap.smp_allocator);
    const gpa = tracy_allocator.allocator();

    var env_vars = try std.process.getEnvMap(gpa);
    defer env_vars.deinit();

    var default_log_level: logger.Level = if (build_options.safety) .debug else .info;
    if (env_vars.get("glb_log_level")) |log_level_str| {
        if (std.meta.stringToEnum(logger.Level, log_level_str)) |log_level| {
            default_log_level = log_level;
        }
    }

    try logger.init(env_vars, default_log_level);
    defer logger.deinit();

    sdl3.errors.error_callback = sdl3ErrorCallback;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    {
        const trace = tracy.traceNamed(@src(), "Init SDL");
        defer trace.end();

        try sdl3.hints.set(.quit_on_last_window_close, "0");

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

    var bootstrap = init_bootstrap: {
        const trace = tracy.traceNamed(@src(), "Bootstrap");
        defer trace.end();

        break :init_bootstrap try renderite.Bootstrap.init(args, gpa, copy, paste);
    };
    defer bootstrap.deinit();

    try bootstrap.startReceiving(gpa);

    const app = init_app: {
        const trace = tracy.traceNamed(@src(), "Init application");
        defer trace.end();

        break :init_app try App.init(gpa, bootstrap.init_settings);
    };
    defer app.deinit();

    app.frameLoop() catch |err| {
        log.err(@src(), "Got error {s} in frame loop", .{@errorName(err)});

        return err;
    };
}

fn copy(text: [:0]const u8) anyerror!void {
    try sdl3.clipboard.setText(text);
}

fn paste() anyerror![:0]u8 {
    return try sdl3.clipboard.getText();
}

pub fn panic(
    msg: []const u8,
    trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = trace;

    if (sdl3.c.SDL_WasInit(0) != 0) {
        const sdl_err = sdl3.c.SDL_GetError();
        if (sdl_err != null) {
            std.debug.print("Latest SDL error: {s}\n", .{sdl_err});
        }
    }

    std.debug.FullPanic(std.debug.defaultPanic).call(msg, ret_addr);
}

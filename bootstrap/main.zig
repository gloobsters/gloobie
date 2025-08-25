const std = @import("std");
const logger = @import("logger");
const sdl3 = @import("sdl3");
const build_options = @import("options").build_options;

const log = logger.Scoped(.main);

const DedicatedBootstrapper = @import("DedicatedBootstrapper.zig");

pub fn main() !void {
    var debug_allocator_impl: std.heap.DebugAllocator(.{
        .stack_trace_frames = 10,
    }) = .init;
    defer if (build_options.safety and debug_allocator_impl.deinit() == .leak) {
        @panic("Memory leak!");
    };

    const gpa = debug_allocator_impl.allocator();

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

    try sdl3.init(.{
        .video = true,
    });
    defer sdl3.shutdown();
    defer if (sdl3.getNumAllocations()) |num_allocations| {
        if (num_allocations > 0) {
            std.debug.panic("SDL memory leak! {d} outstanding allocations.", .{num_allocations});
        }
    };

    var bootstrapper = try DedicatedBootstrapper.init(args, gpa);
    try bootstrapper.run();
    defer {
        log.debug(@src(), "Waiting for engine init thread to exit...", .{});
        bootstrapper.engine_init_thread.join();
        log.debug(@src(), "Engine init thread exited", .{});
    }
    defer bootstrapper.deinit(gpa);

    log.info(@src(), "Bootstrapper exiting", .{});
}

fn sdl3ErrorCallback(err: ?[:0]const u8) void {
    log.err(@src(), "Got SDL error {?s}", .{err});
}

const std = @import("std");
const build_options = @import("options").build_options;
const logger = @import("logger");

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

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    try DedicatedBootstrapper.run(args, gpa);
}

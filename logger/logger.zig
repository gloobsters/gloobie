const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const options = @import("options");
pub const Level = options.@"build.LogLevel";

pub const Scope = enum(u8) {
    app = 0,
    renderite,
    assets,
    graphics,
    input,
    main,
    mesh,
    perf,
    pooling,
    texture,
    bootstrap,
    shmem,
    messaging,
    xr,
    openxr,
};

const scopes = std.enums.values(Scope);

var context: ?struct {
    levels: [scopes.len]Level,
} = null;

/// Initializes the global state of the logger
pub fn init(
    /// The environment variables for the system
    env: std.process.EnvMap,
    /// The default level to assign to scopes
    default_level: Level,
) !void {
    var levels: [scopes.len]Level = @splat(default_level);

    var name_buf: [64]u8 = undefined;
    for (&levels, scopes) |*level, scope| {
        // SAFETY: it's big enough
        const name = std.fmt.bufPrint(&name_buf, "glb_log_{s}", .{@tagName(scope)}) catch unreachable;

        if (env.get(name)) |log_level| {
            if (std.meta.stringToEnum(Level, log_level)) |parsed_level| {
                level.* = parsed_level;
            }
        }
    }

    context = .{
        .levels = levels,
    };
}

pub fn deinit() void {
    context = null;
}

fn padStringComptime(comptime string: [:0]const u8, comptime len: comptime_int) [:0]const u8 {
    return if (string.len < len) string ++ (" " ** (len - string.len)) else string;
}

pub fn defaultLogFn(
    comptime scope: Scope,
    comptime level: Level,
    comptime source_location: std.builtin.SourceLocation,
    comptime format: [:0]const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    const esc_code = std.ascii.control_code.esc;

    const color = switch (level) {
        .err => "[31;49m",
        .warn => "[33;49m",
        .debug => "[35;49m",
        .info => "[32;49m",
        .trace => "[34;49m",
    };

    const level_str = @tagName(level);
    const scope_str = @tagName(scope);

    const source_location_str = std.fmt.comptimePrint("{s} {s}:{d}", .{
        source_location.file,
        source_location.fn_name,
        source_location.line,
    });

    const color_part = if (builtin.os.tag == .windows) "" else std.fmt.comptimePrint("{c}" ++ color, .{esc_code});
    const file_part = "[" ++ source_location_str ++ "]";
    const scope_part = level_str ++ " (" ++ scope_str ++ ")";

    const file_pad_len = 35;
    const scope_pad_len = 18;

    stderr.print(
        color_part ++
            padStringComptime(file_part, file_pad_len) ++
            " " ++
            padStringComptime(scope_part, scope_pad_len - (if (file_part.len > file_pad_len) (file_part.len - file_pad_len) else 0)) ++
            ": " ++
            format ++
            "\n",
        args,
    ) catch return;
}

const logFn = if (@hasDecl(root, "logFn")) root.logFn else defaultLogFn;

pub fn log(
    comptime scope: Scope,
    comptime level: Level,
    comptime source_location: std.builtin.SourceLocation,
    comptime format: [:0]const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(options.build_options.maximum_log_level)) {
        return;
    }

    if (@intFromEnum(level) > @intFromEnum(context.?.levels[@intFromEnum(scope)])) {
        return;
    }

    return logFn(scope, level, source_location, format, args);
}

pub fn Scoped(comptime scope: Scope) type {
    return struct {
        pub fn err(
            comptime source_location: std.builtin.SourceLocation,
            comptime format: [:0]const u8,
            args: anytype,
        ) void {
            return log(scope, .err, source_location, format, args);
        }

        pub fn warn(
            comptime source_location: std.builtin.SourceLocation,
            comptime format: [:0]const u8,
            args: anytype,
        ) void {
            return log(scope, .warn, source_location, format, args);
        }

        pub fn info(
            comptime source_location: std.builtin.SourceLocation,
            comptime format: [:0]const u8,
            args: anytype,
        ) void {
            return log(scope, .info, source_location, format, args);
        }

        pub fn debug(
            comptime source_location: std.builtin.SourceLocation,
            comptime format: [:0]const u8,
            args: anytype,
        ) void {
            return log(scope, .debug, source_location, format, args);
        }

        pub fn trace(
            comptime source_location: std.builtin.SourceLocation,
            comptime format: [:0]const u8,
            args: anytype,
        ) void {
            return log(scope, .trace, source_location, format, args);
        }
    };
}

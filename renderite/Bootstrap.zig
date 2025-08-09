const std = @import("std");
const builtin = @import("builtin");
const zinterprocess = @import("zinterprocess");
const Queue = zinterprocess.Queue;

const InitSettings = @import("InitSettings.zig");

const log = std.log.scoped(.Bootstrap);

const Bootstrap = @This();

queue_in: ?Queue,
queue_out: ?Queue,
child: ?std.process.Child,
init_settings: InitSettings,

pub fn init(args: []const []const u8, gpa: std.mem.Allocator) !Bootstrap {
    if (args.len > 1 and std.mem.eql(u8, args[1], "-QueueName")) {
        log.debug("Skipping bootstrap logic, as we've been invoked directly from FE.", .{});
        // If the renderer is launching us directly, we need no special logic.
        return .{
            .queue_in = null,
            .queue_out = null,
            .child = null,
            .init_settings = try InitSettings.init(args),
        };
    } else {
        log.debug("Renderer args not detected, beginning bootstrap process.", .{});
        var prefix: [16]u8 = undefined;
        try initPrefix(&prefix);

        var in_buf: [std.fs.max_path_bytes]u8 = undefined;
        const in = try std.fmt.bufPrint(&in_buf, "{s}.bootstrapper_in", .{prefix});
        var out_buf: [std.fs.max_path_bytes]u8 = undefined;
        const out = try std.fmt.bufPrint(&out_buf, "{s}.bootstrapper_out", .{prefix});

        var queue_in = try Queue.init(.{
            .capacity = 8192,
            .destroy_on_deinit = true,
            .memory_view_name = in,
            .side = .Subscriber,
        });

        var queue_out = try Queue.init(.{
            .capacity = 8192,
            .destroy_on_deinit = true,
            .memory_view_name = out,
            .side = .Publisher,
        });

        const child = try startResonite(&prefix, gpa);

        const pid = switch (builtin.target.os.tag) {
            .windows => std.os.windows.GetCurrentProcessId(),
            else => std.os.linux.getpid(),
        };

        var msg_buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "RENDERITE_STARTED:{d}", .{pid});

        log.debug("Sending init message: {s}", .{msg});
        try queue_out.enqueue(msg);

        log.debug("Waiting for Resonite to say hello...", .{});
        const message = try queue_in.dequeue(gpa);
        defer gpa.free(message);
        log.debug("Received queue message! '{s}'", .{message});

        var iterator = std.mem.splitAny(u8, message, " ");
        const max_part = 4;
        var parts: [max_part][]const u8 = undefined;

        var i: usize = 0;
        while (iterator.next()) |part| {
            std.debug.assert(i < max_part);

            parts[i] = part;
            i += 1;
        }

        const init_settings = try InitSettings.init(parts[0..max_part]);

        const bootstrap: Bootstrap = .{
            .queue_in = queue_in,
            .queue_out = queue_out,
            .child = child,
            .init_settings = init_settings,
        };

        return bootstrap;
    }
}

fn initPrefix(prefix: *[16]u8) !void {
    const safe_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    std.crypto.random.bytes(prefix);

    for (prefix) |*char| {
        char.* = safe_chars[char.* % safe_chars.len];
    }
}

fn startResonite(prefix: []const u8, gpa: std.mem.Allocator) !std.process.Child {
    const dotnet_path = switch (builtin.target.os.tag) {
        .windows => "dotnet", // dotnet runtime is globally installed on Windows
        else => "dotnet-runtime/dotnet",
    };

    log.debug("Starting Resonite with dotnet at '{s}', using shmem prefix '{s}'", .{ dotnet_path, prefix });

    var child = std.process.Child.init(&.{
        dotnet_path,
        "Resonite.dll",
        "-shmprefix",
        prefix,
    }, gpa);

    try child.spawn();
    log.debug("Process spawned. PID {any}", .{child.id});
    try child.waitForSpawn();

    return child;
}
pub fn deinit(self: *Bootstrap, gpa: std.mem.Allocator) void {
    if (self.queue_in) |queue| queue.deinit();
    if (self.queue_out) |queue| queue.deinit();

    if (self.child) |*child| {
        _ = child.kill() catch |err| {
            if (err == error.AlreadyTerminated)
                return;

            log.warn("Failed to kill Resonite: {any}", .{err});
            return;
        };
    }

    if (self.args) |args| {
        gpa.free(args);
    }
}

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
        // If the renderer is launching us directly, we need no special logic.
        return .{
            .queue_in = null,
            .queue_out = null,
            .child = null,
            .init_settings = try InitSettings.init(args),
        };
    } else {
        const prefix, const queue_in, const queue_out = try initBootstrapQueues();
        const child = try startResonite(prefix, gpa);

        // wait for resonite's bootstrapper hello message
        const message = try queue_in.dequeue(gpa);
        log.debug("Received queue message: {s}", .{message});

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

        const pid = switch (builtin.target.os.tag) {
            .windows => std.os.windows.GetCurrentProcessId(),
            else => std.os.linux.getpid(),
        };

        var msg_buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "RENDERITE_STARTED:{d}", .{pid});

        try queue_out.enqueue(msg);

        const bootstrap: Bootstrap = .{
            .queue_in = queue_in,
            .queue_out = queue_out,
            .child = child,
            .init_settings = init_settings,
        };

        return bootstrap;
    }
}

fn initBootstrapQueues() !std.meta.Tuple(&.{ []const u8, Queue, Queue }) {
    const safe_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var prefix: [16]u8 = undefined;
    std.crypto.random.bytes(&prefix);

    for (&prefix) |*char| {
        char.* = safe_chars[char.* % safe_chars.len];
    }

    log.debug("Creating bootstrap queue with prefix {s}", .{&prefix});

    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    const in = try std.fmt.bufPrint(&in_buf, "{s}.bootstrapper_in", .{&prefix});
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "{s}.bootstrapper_out", .{&prefix});

    const queue_in = try Queue.init(.{
        .capacity = 8192,
        .destroy_on_deinit = true,
        .memory_view_name = in,
        .side = .Subscriber,
    });

    const queue_out = try Queue.init(.{
        .capacity = 8192,
        .destroy_on_deinit = true,
        .memory_view_name = out,
        .side = .Publisher,
    });

    return .{ &prefix, queue_in, queue_out };
}

fn startResonite(prefix: []const u8, gpa: std.mem.Allocator) !std.process.Child {
    var child = child: switch (builtin.target.os.tag) {
        .windows => {
            break :child std.process.Child.init(&.{
                "dotnet", // dotnet runtime is globally installed on Windows, see InstallScript.vdf
                "Resonite.dll",
                "-shmprefix",
                prefix,
            }, gpa);
        },
        else => {
            break :child std.process.Child.init(&.{
                "dotnet-runtime/dotnet",
                "Resonite.dll",
                "-shmprefix",
                prefix,
            }, gpa);
        },
    };

    try child.spawn();
    try child.waitForSpawn();

    return child;
}
pub fn deinit(self: *Bootstrap, gpa: std.mem.Allocator) void {
    if (self.queue_in) |q| q.deinit();
    if (self.queue_out) |q| q.deinit();

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

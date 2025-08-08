const std = @import("std");
const builtin = @import("builtin");
const zinterprocess = @import("zinterprocess");
const Queue = zinterprocess.Queue;

const log = std.log.scoped(.Bootstrap);

const Bootstrap = @This();

queue_in: Queue,
queue_out: Queue,
prefix: std.BoundedArray(u8, 16),
child: ?std.process.Child,

pub fn init() !Bootstrap {
    const safe_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var prefix: std.BoundedArray(u8, 16) = .{};
    std.crypto.random.bytes(&prefix.buffer);

    for (&prefix.buffer) |*char| {
        char.* = safe_chars[char.* % safe_chars.len];
    }

    log.debug("Creating bootstrap queue with prefix {s}", .{&prefix.buffer});

    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    const in = try std.fmt.bufPrint(&in_buf, "{s}.bootstrapper_in", .{&prefix.buffer});
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "{s}.bootstrapper_out", .{&prefix.buffer});

    const bootstrap: Bootstrap = .{
        .queue_in = try Queue.init(.{
            .capacity = 8192,
            .destroy_on_deinit = true,
            .memory_view_name = in,
            .side = .Subscriber,
        }),
        .queue_out = try Queue.init(.{
            .capacity = 8192,
            .destroy_on_deinit = true,
            .memory_view_name = out,
            .side = .Publisher,
        }),
        .prefix = prefix,
        .child = null,
    };

    return bootstrap;
}

pub fn startResonite(self: *Bootstrap, gpa: std.mem.Allocator) !void {
    var child = child: switch (builtin.target.os.tag) {
        .windows => {
            break :child std.process.Child.init(&.{
                "dotnet", // dotnet runtime is globally installed on Windows, see InstallScript.vdf
                "Resonite.dll",
                "-shmprefix",
                &self.prefix.buffer,
            }, gpa);
        },
        else => {
            break :child std.process.Child.init(&.{
                "dotnet-runtime/dotnet",
                "Resonite.dll",
                "-shmprefix",
                &self.prefix.buffer,
            }, gpa);
        },
    };

    try child.spawn();
    try child.waitForSpawn();

    self.child = child;
}

pub fn deinit(self: *Bootstrap) void {
    self.queue_in.deinit();
    self.queue_out.deinit();

    if (self.child) |*child| {
        _ = child.kill() catch |err| {
            if (err == error.AlreadyTerminated)
                return;

            log.warn("Failed to kill Resonite: {any}", .{err});
            return;
        };
    }
}

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
args: ?[]const u8,

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
        .args = null,
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

pub fn waitForMessage(self: *Bootstrap, gpa: std.mem.Allocator) !void {
    const message = try self.queue_in.dequeue(gpa);
    log.debug("Received queue message: {s}", .{message});

    const expected_header = "-QueueName";
    std.debug.assert(std.mem.eql(u8, message[0..expected_header.len], expected_header));

    self.args = message;

    const pid = init_pid: switch (builtin.target.os.tag) {
        .windows => {
            break :init_pid std.os.windows.GetCurrentProcessId();
        },
        else => {
            break :init_pid std.os.linux.getpid();
        },
    };

    var msg_buf: [32]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "RENDERITE_STARTED:{d}", .{pid});

    try self.queue_out.enqueue(msg);
}

pub fn deinit(self: *Bootstrap, gpa: std.mem.Allocator) void {
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

    if (self.args) |args| {
        gpa.free(args);
    }
}

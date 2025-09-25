const std = @import("std");
const builtin = @import("builtin");

const zinterprocess = @import("zinterprocess");
const Queue = zinterprocess.Queue;

const InitSettings = @import("InitSettings.zig");

const log = @import("logger").Scoped(.bootstrap);

const Bootstrap = @This();

child: ?ChildInfo,
init_settings: InitSettings,
last_heartbeat: i128,

thread: ?std.Thread,
run: bool,

copy_callback: CopyCallback,
paste_callback: PasteCallback,

const CopyCallback = *const fn (text: [:0]const u8) anyerror!void;
const PasteCallback = *const fn () anyerror![:0]u8;

pub const ChildInfo = struct {
    queue_in: Queue,
    queue_out: Queue,
    child: std.process.Child,

    pub fn init(args: []const []const u8, gpa: std.mem.Allocator) !ChildInfo {
        log.info(@src(), "Bootstrapping Resonite...", .{});
        var prefix: [16]u8 = undefined;
        try initPrefix(&prefix);

        var in_buf: [std.fs.max_path_bytes]u8 = undefined;
        const in = try std.fmt.bufPrint(&in_buf, "{s}.bootstrapper_in", .{prefix});
        var out_buf: [std.fs.max_path_bytes]u8 = undefined;
        const out = try std.fmt.bufPrint(&out_buf, "{s}.bootstrapper_out", .{prefix});

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

        const child = try startResonite(&prefix, args, gpa);

        return .{
            .queue_in = queue_in,
            .queue_out = queue_out,
            .child = child,
        };
    }

    pub fn deinit(self: *ChildInfo) void {
        self.queue_in.deinit();
        self.queue_out.deinit();

        _ = self.child.kill() catch |err| {
            if (err == error.AlreadyTerminated)
                return;

            log.warn(@src(), "Failed to kill Resonite: {any}", .{err});
            return;
        };
    }
};

pub fn init(
    args: []const []const u8,
    gpa: std.mem.Allocator,
    copy_callback: CopyCallback,
    paste_callback: PasteCallback,
) !Bootstrap {
    if (args.len > 1 and std.mem.eql(u8, args[1], "-QueueName")) {
        log.info(@src(), "Launched from external bootstrapper, skipping our own bootstrapper!", .{});
        // If the renderer is launching us directly, we need no special logic.
        return .initDirect(args, copy_callback, paste_callback);
    } else {
        var child = try ChildInfo.init(args, gpa);

        const bootstrap: Bootstrap = try .initBootstrap(&child, gpa, copy_callback, paste_callback);
        try bootstrap.sendRenderitePid(std.c.getpid());
        return bootstrap;
    }
}

pub fn initDirect(
    args: []const []const u8,
    copy_callback: CopyCallback,
    paste_callback: PasteCallback,
) !Bootstrap {
    return .{
        .child = null,
        .init_settings = try InitSettings.init(args),
        .last_heartbeat = 0,
        .thread = null,
        .run = false,
        .copy_callback = copy_callback,
        .paste_callback = paste_callback,
    };
}

pub fn initBootstrap(
    child: *ChildInfo,
    gpa: std.mem.Allocator,
    copy_callback: CopyCallback,
    paste_callback: PasteCallback,
) !Bootstrap {
    log.info(@src(), "Waiting for Resonite to say hello...", .{});
    const message = try child.queue_in.dequeue(gpa);
    defer gpa.free(message);
    log.trace(@src(), "Received queue message! '{s}'", .{message});

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

    log.info(@src(), "Resonite launched!", .{});

    const bootstrap: Bootstrap = .{
        .child = child.*,
        .init_settings = init_settings,
        .last_heartbeat = 0,
        .thread = null,
        .run = true,
        .copy_callback = copy_callback,
        .paste_callback = paste_callback,
    };

    return bootstrap;
}

pub fn sendRenderitePid(
    self: Bootstrap,
    pid: std.posix.pid_t,
) !void {
    var msg_buf: [32]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "RENDERITE_STARTED:{d}", .{switch (@typeInfo(std.posix.pid_t)) {
        .pointer => @intFromPtr(pid),
        else => pid,
    }});

    log.trace(@src(), "Sending init message: {s}", .{msg});
    try self.child.?.queue_out.enqueue(msg);
}

pub fn startReceiving(self: *Bootstrap, gpa: std.mem.Allocator) !void {
    if (!self.run)
        return;

    self.thread = try std.Thread.spawn(.{}, receiverLoop, .{ self, gpa });
}

const Commands = enum {
    HEARTBEAT,
    SHUTDOWN,
    GETTEXT,
    SETTEXT,
};

pub fn receiverLoop(self: *Bootstrap, gpa: std.mem.Allocator) void {
    var receive_arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer receive_arena_impl.deinit();

    const receive_arena = receive_arena_impl.allocator();

    self.last_heartbeat = std.time.nanoTimestamp();

    while (self.run) {
        const msg = self.child.?.queue_in.dequeueOnce(receive_arena) catch |err| {
            if (err == error.QueueEmpty)
                continue;

            log.err(@src(), "Failed to dequeue bootstrapper message: {any}", .{err});
            continue;
        };
        defer receive_arena.free(msg);

        log.trace(@src(), "Bootstrapper message: {s}", .{msg});

        const cmd = std.meta.stringToEnum(Commands, msg) orelse try_parse: {
            if (std.mem.startsWith(u8, msg, "SETTEXT"))
                break :try_parse .SETTEXT;

            log.warn(@src(), "Unable to parse bootstrapper command: {s}", .{msg});
            continue;
        };

        switch (cmd) {
            .HEARTBEAT => {
                log.debug(@src(), "Got heartbeat", .{});
                self.last_heartbeat = std.time.nanoTimestamp();
            },
            .SHUTDOWN => {
                log.debug(@src(), "Bootstrapper received exit command", .{});
                self.run = false;
            },
            .GETTEXT => {
                log.debug(@src(), "Clipboard requested by engine", .{});

                const queue_capacity = self.child.?.queue_out.options.capacity - @sizeOf(zinterprocess.MessageHeader);

                // if clipboard fails, just paste the error name so the user knows something is wrong
                const clipboard = self.paste_callback() catch |err| @errorName(err);

                self.child.?.queue_out.enqueue(clipboard[0..@min(queue_capacity, clipboard.len)]) catch |err| {
                    log.warn(@src(), "Failed to enqueue clipboard data: {any}", .{err});
                    continue;
                };
            },
            .SETTEXT => {
                const content = msg[7..];

                const content_sentinel = gpa.allocSentinel(u8, content.len, 0) catch @panic("Failed to allocate clipboard content");
                defer gpa.free(content_sentinel);

                self.copy_callback(content_sentinel) catch |err| {
                    log.warn(@src(), "Failed to copy clipboard: {any}", .{err});
                    continue;
                };
            },
        }
    }

    log.info(@src(), "Bootstrapper exited", .{});
}

fn initPrefix(prefix: *[16]u8) !void {
    const safe_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    std.crypto.random.bytes(prefix);

    for (prefix) |*char| {
        char.* = safe_chars[char.* % safe_chars.len];
    }
}

fn startResonite(prefix: []const u8, args: []const []const u8, gpa: std.mem.Allocator) !std.process.Child {
    _ = args; // TODO: pass args into frooxengine
    const dotnet_path = switch (builtin.target.os.tag) {
        .windows => "dotnet", // dotnet runtime is globally installed on Windows
        else => "dotnet-runtime/dotnet",
    };

    log.debug(@src(), "Starting Resonite with dotnet at '{s}', using shmem prefix '{s}'", .{ dotnet_path, prefix });

    var child = std.process.Child.init(&.{
        dotnet_path,
        "Renderite.Host.dll",
        "-shmprefix",
        prefix,
    }, gpa);

    try child.spawn();
    log.trace(@src(), "Process spawned. PID {any}", .{child.id});
    try child.waitForSpawn();

    return child;
}

pub fn deinit(self: *Bootstrap) void {
    self.run = false;

    log.debug(@src(), "Waiting for reciever thread to exit", .{});

    // wait for exit
    if (self.thread) |thread| {
        thread.join();
    }

    if (self.child) |*child| child.deinit();
}

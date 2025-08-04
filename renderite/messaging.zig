const std = @import("std");

const tracy = @import("tracy");
const zinterprocess = @import("zinterprocess");

const serialization = @import("serialization.zig");
const IpcDeserializer = serialization.IpcDeserializer;
const IpcSerializer = serialization.IpcSerializer;
const shared = @import("shared.zig");

const log = std.log.scoped(.messaging);

pub const ParsedCommand = struct {
    arena: std.heap.ArenaAllocator,
    command: shared.RendererCommand,
};

pub const ReceiveCallback = fn (ctx: *anyopaque, ParsedCommand) void;
// *const ReceiveCallback

pub const MessagingHost = struct {
    primary: QueueManager,
    background: QueueManager,

    pub fn init(queue_name: []const u8, queue_length: u32, comptime receive_callback: *const ReceiveCallback, receive_ctx: *anyopaque) !MessagingHost {
        var queue_name_primary_buf: [std.fs.max_path_bytes]u8 = undefined;
        const queue_name_primary = try std.fmt.bufPrint(&queue_name_primary_buf, "{s}Primary", .{queue_name});
        var queue_name_background_buf: [std.fs.max_path_bytes]u8 = undefined;
        const queue_name_background = try std.fmt.bufPrint(&queue_name_background_buf, "{s}Background", .{queue_name});

        const primary = try QueueManager.init(
            queue_name_primary,
            false,
            queue_length,
            receive_callback,
            receive_ctx,
        );
        const background = try QueueManager.init(
            queue_name_background,
            false,
            queue_length,
            receive_callback,
            receive_ctx,
        );

        return MessagingHost{
            .primary = primary,
            .background = background,
        };
    }

    pub fn initFromArgs(comptime receive_callback: *const ReceiveCallback, receive_ctx: *anyopaque, gpa: std.mem.Allocator) !MessagingHost {
        const args = try std.process.argsAlloc(gpa);
        defer std.process.argsFree(gpa, args);

        // -QueueName randomString -QueueCapacity 8388608

        if (args.len != 5)
            return error.InvalidNumberOfArguments;

        if (!std.mem.eql(u8, args[1], "-QueueName"))
            return error.InvalidQueueName;

        const queue_name = args[2];

        if (!std.mem.eql(u8, args[3], "-QueueCapacity"))
            return error.InvalidQueueLength;

        const queue_length = try std.fmt.parseInt(u32, args[4], 10);

        return try MessagingHost.init(queue_name, queue_length, receive_callback, receive_ctx);
    }

    fn queueSuffix(queue_name: []const u8, comptime suffix: []const u8, gpa: std.mem.Allocator) ![]const u8 {
        const suffixed_name = try gpa.alloc(u8, queue_name.len + suffix.len);

        @memcpy(suffixed_name[0..queue_name.len], queue_name);
        @memcpy(suffixed_name[queue_name.len..], suffix);

        return suffixed_name;
    }

    fn emptyCallback(command: shared.RendererCommand) void {
        _ = command;
    }

    pub fn start(self: *MessagingHost, gpa: std.mem.Allocator) !void {
        try self.primary.start(gpa);
        try self.background.start(gpa);
    }

    pub fn deinit(self: MessagingHost) void {
        self.primary.deinit();
        self.background.deinit();
    }
};

pub const QueueManager = struct {
    publisher: zinterprocess.Queue,
    subscriber: zinterprocess.Queue,

    thread: ?std.Thread = undefined,
    receive_callback: *const ReceiveCallback,
    receive_ctx: *anyopaque,

    pub fn init(queue_name: []const u8, comptime is_authority: bool, capacity: u32, comptime receive_callback: *const ReceiveCallback, receive_ctx: *anyopaque) !QueueManager {
        var name_a_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name_a = try std.fmt.bufPrint(&name_a_buf, "{s}A", .{queue_name});
        var name_s_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name_s = try std.fmt.bufPrint(&name_s_buf, "{s}S", .{queue_name});

        log.debug("Inititalizing QueueManager with names {s} and {s} (size {d})", .{ name_a, name_s, capacity });

        const publisher = try zinterprocess.Queue.init(.{
            .capacity = capacity,
            .memory_view_name = if (is_authority) name_a else name_s,
            .side = .Publisher,
            .destroy_on_deinit = is_authority,
        });
        errdefer publisher.deinit();

        const subscriber = try zinterprocess.Queue.init(.{
            .capacity = capacity,
            .memory_view_name = if (is_authority) name_s else name_a,
            .side = .Subscriber,
            .destroy_on_deinit = is_authority,
        });
        errdefer subscriber.deinit();

        const queue = QueueManager{
            .publisher = publisher,
            .subscriber = subscriber,
            .receive_callback = receive_callback,
            .receive_ctx = receive_ctx,
        };

        return queue;
    }

    pub fn start(self: *QueueManager, gpa: std.mem.Allocator) !void {
        self.thread = try std.Thread.spawn(.{}, QueueManager.receiverLoop, .{ self.*, gpa });
    }

    pub fn deinit(self: QueueManager) void {
        self.publisher.deinit();
        self.subscriber.deinit();
        // todo: stop receiver thread
    }

    fn receiverLoop(self: QueueManager, gpa: std.mem.Allocator) void {
        var receive_arena_impl: std.heap.ArenaAllocator = .init(gpa);
        defer receive_arena_impl.deinit();

        const receive_arena = receive_arena_impl.allocator();

        var contents_allocator_impl: std.heap.ThreadSafeAllocator = .{ .child_allocator = gpa };

        // log.debug("Starting receiver loop", .{});
        while (true) {
            tracy.frameMarkNamed("Receiver Loop");

            defer _ = receive_arena_impl.reset(.{ .retain_with_limit = 1024 * 1024 * 1024 });

            self.receiveOnce(contents_allocator_impl.allocator(), receive_arena) catch |err| {
                log.err("Error while receiving: {any}", .{err});
            };
        }
    }

    fn receiveOnce(self: QueueManager, contents_allocator: std.mem.Allocator, arena: std.mem.Allocator) !void {
        const trace = tracy.traceNamed(@src(), "Receive Once");
        defer trace.end();

        const data = try self.subscriber.dequeue(arena);
        defer arena.free(data);

        var contents_arena_impl: std.heap.ArenaAllocator = .init(contents_allocator);
        errdefer contents_arena_impl.deinit();
        const contents_arena = contents_arena_impl.allocator();

        var reader: std.io.Reader = std.io.Reader.fixed(data);
        const deserializer = IpcDeserializer.init(
            &reader,
            contents_arena,
        );

        const message_type = try deserializer.readEnum(shared.RendererCommandTypes);
        log.debug("Received message of type '{s}'", .{@tagName(message_type)});

        // make RendererCommand from enum value

        const info = @typeInfo(shared.RendererCommand).@"union";
        switch (message_type) {
            inline else => |comptime_type| {
                var command: shared.RendererCommand = undefined;
                if (@hasDecl(info.fields[@intFromEnum(comptime_type)].type, "read")) {
                    // Commands that support reading
                    command = @unionInit(shared.RendererCommand, @tagName(comptime_type), try .read(deserializer));
                } else {
                    // Empty commands
                    command = @unionInit(shared.RendererCommand, @tagName(comptime_type), .{});
                }

                self.receive_callback(self.receive_ctx, .{
                    .arena = contents_arena_impl,
                    .command = command,
                });
            },
        }
        errdefer @compileError("cannot error after send else memory will be freed too soon");
    }
};

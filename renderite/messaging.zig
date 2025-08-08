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

pub fn MessagingHost(comptime Context: type) type {
    return struct {
        pub const Callback = *const fn (ctx: Context, queue_type: QueueManager.Type, command: ParsedCommand) void;

        const Self = @This();

        primary: QueueManager,
        background: QueueManager,

        pub fn init(queue_name: []const u8, queue_length: u32, comptime receive_callback: Callback, context: Context) !Self {
            var queue_name_primary_buf: [std.fs.max_path_bytes]u8 = undefined;
            const queue_name_primary = try std.fmt.bufPrint(&queue_name_primary_buf, "{s}Primary", .{queue_name});
            var queue_name_background_buf: [std.fs.max_path_bytes]u8 = undefined;
            const queue_name_background = try std.fmt.bufPrint(&queue_name_background_buf, "{s}Background", .{queue_name});

            const primary = try QueueManager.init(
                queue_name_primary,
                false,
                .primary,
                queue_length,
                receive_callback,
                context,
            );
            const background = try QueueManager.init(
                queue_name_background,
                false,
                .background,
                queue_length,
                receive_callback,
                context,
            );

            return .{
                .primary = primary,
                .background = background,
            };
        }

        pub fn initFromArgs(comptime receive_callback: Callback, context: Context, args: []const []const u8) !Self {
            // -QueueName randomString -QueueCapacity 8388608

            // 5: Includes process name, e.g. "Renderite.Renderer.exe -QueueName ..."
            // 4: Injected from Bootstrap. Just "-QueueName ..."
            if (args.len != 5 and args.len != 4)
                return error.InvalidNumberOfArguments;

            const offset: usize = if (args.len == 5) 1 else 0;

            if (!std.mem.eql(u8, args[offset], "-QueueName"))
                return error.InvalidQueueName;

            const queue_name = args[1 + offset];

            if (!std.mem.eql(u8, args[2 + offset], "-QueueCapacity"))
                return error.InvalidQueueLength;

            const queue_length = try std.fmt.parseInt(u32, args[3 + offset], 10);

            return try Self.init(queue_name, queue_length, receive_callback, context);
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

        pub fn start(self: *Self, gpa: std.mem.Allocator) !void {
            try self.primary.start(gpa);
            try self.background.start(gpa);
        }

        pub fn deinit(self: *Self) void {
            self.primary.deinit();
            self.background.deinit();
        }

        pub const QueueManager = struct {
            pub const Type = enum {
                primary,
                background,
            };

            publisher: zinterprocess.Queue,
            subscriber: zinterprocess.Queue,

            type: Type,

            thread: ?std.Thread = undefined,
            receive_callback: Callback,
            context: Context,

            run: bool,

            pub fn init(
                queue_name: []const u8,
                comptime is_authority: bool,
                queue_type: Type,
                capacity: u32,
                comptime receive_callback: Callback,
                context: Context,
            ) !QueueManager {
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

                return .{
                    .type = queue_type,
                    .publisher = publisher,
                    .subscriber = subscriber,
                    .receive_callback = receive_callback,
                    .context = context,
                    .run = true,
                };
            }

            pub fn start(self: *QueueManager, gpa: std.mem.Allocator) !void {
                self.thread = try std.Thread.spawn(.{}, QueueManager.receiverLoop, .{ self, gpa });
            }

            pub fn deinit(self: *QueueManager) void {
                self.run = false;

                // wait for thread to exit
                if (self.thread) |thread| {
                    log.debug("Waiting for exit...", .{});
                    thread.join();
                }

                log.debug("deinitting queues", .{});
                self.publisher.deinit();
                self.subscriber.deinit();
            }

            fn receiverLoop(self: *QueueManager, gpa: std.mem.Allocator) void {
                var receive_arena_impl: std.heap.ArenaAllocator = .init(gpa);
                defer receive_arena_impl.deinit();

                const receive_arena = receive_arena_impl.allocator();

                var contents_allocator_impl: std.heap.ThreadSafeAllocator = .{ .child_allocator = gpa };

                // log.debug("Starting receiver loop", .{});
                while (self.run) {
                    tracy.frameMarkNamed("Receiver Loop");

                    defer _ = receive_arena_impl.reset(.{ .retain_with_limit = 1024 * 1024 * 1024 });

                    self.receiveOnce(contents_allocator_impl.allocator(), receive_arena) catch |err| {
                        if (err == zinterprocess.Queue.Error.QueueEmpty) {
                            // SAFETY: we dont care if it fails
                            std.Thread.yield() catch {};
                            continue;
                        }

                        log.err("Error while receiving: {any}", .{err});
                    };
                }
            }

            fn receiveOnce(self: QueueManager, contents_allocator: std.mem.Allocator, arena: std.mem.Allocator) !void {
                const trace = tracy.traceNamed(@src(), "Receive Once");
                defer trace.end();

                const data = try self.subscriber.dequeueOnce(arena);
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

                        self.receive_callback(self.context, self.type, .{
                            .arena = contents_arena_impl,
                            .command = command,
                        });
                    },
                }
                errdefer @compileError("cannot error after send else memory will be freed too soon");
            }

            pub fn send(self: QueueManager, command: shared.RendererCommand) !void {
                const trace = tracy.traceNamed(@src(), "Send Data");
                defer trace.end();

                var data: [8192]u8 = undefined;
                var writer: std.io.Writer = std.io.Writer.fixed(&data);

                const serializer = IpcSerializer.init(&writer);

                switch (command) {
                    inline else => |command_struct| {
                        try serializer.writeInt(i32, @intFromEnum(std.meta.stringToEnum(shared.RendererCommandTypes, @tagName(command)).?));
                        log.debug("Sending message {s}", .{@tagName(command)});

                        // Not all messages have data attached. Only write if the type has a write function.
                        if (@hasDecl(@TypeOf(command_struct), "write")) {
                            try command_struct.write(serializer);
                        }
                    },
                }

                try self.publisher.enqueue(data[0..writer.end]);
            }
        };
    };
}

const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");
const zinterprocess = @import("zinterprocess");

const InitSettings = @import("InitSettings.zig");
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

                        const err_format = "Error while receiving: {any}";
                        if (builtin.mode == .Debug) {
                            std.debug.panic(err_format, .{err});
                        } else {
                            log.err(err_format, .{err});
                        }
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

                const command = try deserializer.readPolymorphic(shared.RendererCommand);
                self.receive_callback(self.context, self.type, .{
                    .arena = contents_arena_impl,
                    .command = command,
                });

                errdefer @compileError("cannot error after send else memory will be freed too soon");
            }

            pub fn send(self: QueueManager, command: shared.RendererCommand) !void {
                const trace = tracy.traceNamed(@src(), "Send Data");
                defer trace.end();

                var data: [8192]u8 = undefined;
                var writer: std.io.Writer = std.io.Writer.fixed(&data);

                const serializer = IpcSerializer.init(&writer);

                log.debug("Sending message {s}", .{@tagName(command)});
                try serializer.writePolymorphic(shared.RendererCommand, command);

                try self.publisher.enqueue(data[0..writer.end]);
            }

            pub fn sendTimeout(self: QueueManager, command: shared.RendererCommand, timeout_ns: u64) !void {
                const end_ns = std.time.nanoTimestamp() + timeout_ns;

                while (true) {
                    self.send(command) catch |err| {
                        // if the queue is full and we're before the end timeout, just continue, else return the error
                        if (err == error.QueueFull and std.time.nanoTimestamp() < end_ns) {
                            log.err("Sending message {s} timed out after {d} nanoseconds", .{ @tagName(command), timeout_ns });
                            // SAFETY: we really don't care if this fails
                            std.Thread.yield() catch {};
                            continue;
                        }

                        return err;
                    };

                    break;
                }
            }
        };
    };
}

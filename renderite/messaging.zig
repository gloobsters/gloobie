const std = @import("std");

const zinterprocess = @import("zinterprocess");

const log = std.log.scoped(.messaging);

pub const MessagingHost = struct {
    primary: QueueManager,
    background: QueueManager,

    pub fn init(queue_name: []const u8, queue_length: u32, allocator: std.mem.Allocator) !MessagingHost {
        const queue_name_primary = try queueSuffix(queue_name, "Primary", allocator);
        defer allocator.free(queue_name_primary);

        const queue_name_background = try queueSuffix(queue_name, "Background", allocator);
        defer allocator.free(queue_name_background);

        const primary = try QueueManager.init(queue_name_primary, false, queue_length, allocator);
        const background = try QueueManager.init(queue_name_background, false, queue_length, allocator);

        return MessagingHost{
            .primary = primary,
            .background = background,
        };
    }

    pub fn initFromArgs(allocator: std.mem.Allocator) !MessagingHost {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        // -QueueName randomString -QueueCapacity 8388608

        if (args.len != 5)
            return error.InvalidNumberOfArguments;

        if (!std.mem.eql(u8, args[1], "-QueueName"))
            return error.InvalidQueueName;

        const queue_name = args[2];

        if (!std.mem.eql(u8, args[3], "-QueueCapacity"))
            return error.InvalidQueueLength;

        const queue_length = try std.fmt.parseInt(u32, args[4], 10);

        return try MessagingHost.init(queue_name, queue_length, allocator);
    }

    fn queueSuffix(queue_name: []const u8, comptime suffix: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const suffixed_name = try allocator.alloc(u8, queue_name.len + suffix.len);

        @memcpy(suffixed_name[0..queue_name.len], queue_name);
        @memcpy(suffixed_name[queue_name.len..], suffix);

        return suffixed_name;
    }

    pub fn deinit(self: MessagingHost) void {
        self.primary.deinit();
        self.background.deinit();
    }
};

pub const QueueManager = struct {
    allocator: std.mem.Allocator,
    publisher: zinterprocess.Queue,
    subscriber: zinterprocess.Queue,
    thread: std.Thread = undefined,

    pub fn init(queue_name: []const u8, comptime is_authority: bool, capacity: u32, allocator: std.mem.Allocator) !QueueManager {
        var name_a_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name_a = try std.fmt.bufPrint(&name_a_buf, "{s}A", .{queue_name});
        var name_s_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name_s = try std.fmt.bufPrint(&name_s_buf, "{s}S", .{queue_name});

        log.debug("Inititalizing QueueManager with names {s} and {s} (size {d})", .{ name_a, name_s, capacity });

        const publisher = try zinterprocess.Queue.init(.{
            .allocator = allocator,
            .capacity = capacity,
            .memory_view_name = if (is_authority) name_a else name_s,
            .side = .Publisher,
            .destroy_on_deinit = is_authority,
        });
        errdefer publisher.deinit();

        const subscriber = try zinterprocess.Queue.init(.{
            .allocator = allocator,
            .capacity = capacity,
            .memory_view_name = if (is_authority) name_s else name_a,
            .side = .Subscriber,
            .destroy_on_deinit = is_authority,
        });
        errdefer subscriber.deinit();

        var queue = QueueManager{
            .allocator = allocator,
            .publisher = publisher,
            .subscriber = subscriber,
        };

        queue.thread = try std.Thread.spawn(.{}, QueueManager.receiverLoop, .{queue});

        return queue;
    }

    pub fn deinit(self: QueueManager) void {
        self.publisher.deinit();
        self.subscriber.deinit();
    }

    fn receiverLoop(self: QueueManager) !void {
        // log.debug("Starting receiver loop", .{});
        while (true) {
            const data = try self.subscriber.dequeue();
            defer self.allocator.free(data);

            log.debug("Received message: {s}", .{data});
            for (data) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
        }
    }
};

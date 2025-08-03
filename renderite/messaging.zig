const std = @import("std");

const zinterprocess = @import("zinterprocess");

pub const MessagingManager = struct {
    publisher: zinterprocess.Queue,
    subscriber: zinterprocess.Queue,

    pub fn init(queue_name: []const u8, is_authority: bool, capacity: u32, allocator: std.mem.Allocator) !MessagingManager {
        const name_a = try queueSuffix(queue_name, 'A', allocator);
        defer allocator.free(name_a);
        const name_s = try queueSuffix(queue_name, 'S', allocator);
        defer allocator.free(name_s);

        const publisher = try zinterprocess.Queue.init(.{
            .allocator = allocator,
            .capacity = capacity,
            .memory_view_name = if (is_authority) name_a else name_s,
            .side = .Publisher,
            .destroy_on_deinit = is_authority,
        });

        const subscriber = try zinterprocess.Queue.init(.{
            .allocator = allocator,
            .capacity = capacity,
            .memory_view_name = if (is_authority) name_s else name_a,
            .side = .Subscriber,
            .destroy_on_deinit = is_authority,
        });

        return MessagingManager{
            .publisher = publisher,
            .subscriber = subscriber,
        };
    }

    pub fn initFromArgs(allocator: std.mem.Allocator) !MessagingManager {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        // -QueueName randomString -QueueLength 8388608

        if (args.len != 5)
            return error.InvalidNumArguments;

        if (!std.mem.eql(u8, args[1], "-QueueName"))
            return error.InvalidArguments;

        const queue_name = args[2];

        if (!std.mem.eql(u8, args[3], "-QueueLength"))
            return error.InvalidArguments;

        const queue_length = try std.fmt.parseInt(u32, args[4], 10);

        return MessagingManager.init(queue_name, true, queue_length, allocator);
    }

    pub fn deinit(self: MessagingManager) void {
        self.publisher.deinit();
        self.subscriber.deinit();
    }

    fn queueSuffix(queue_name: []const u8, c: u8, allocator: std.mem.Allocator) ![]const u8 {
        const name_authority = try allocator.alloc(u8, queue_name.len + 1);

        @memcpy(name_authority[0..queue_name.len], queue_name);
        name_authority[queue_name.len] = c;

        return name_authority;
    }
};

const std = @import("std");

const bounded_array = @import("bounded_array");

pub const InitSettings = @This();

queue_name: bounded_array.BoundedArray(u8, 128),
queue_length: u32,

pub fn init(args: []const []const u8) !InitSettings {
    // -QueueName randomString -QueueCapacity 8388608

    if (args.len != 4 and args.len != 5)
        return error.InvalidNumberOfArguments;

    const offset: usize = if (args.len == 5) 1 else 0;

    if (!std.mem.eql(u8, args[offset], "-QueueName"))
        return error.InvalidQueueName;

    var queue_name: bounded_array.BoundedArray(u8, 128) = .{};
    // SAFETY: FrooxEngine should never send us a queue this big
    queue_name.appendSlice(args[1 + offset]) catch @panic("Queue name is too big");

    if (!std.mem.eql(u8, args[2 + offset], "-QueueCapacity"))
        return error.InvalidQueueCapacity;

    const queue_length = try std.fmt.parseInt(u32, args[3 + offset], 10);

    return .{
        .queue_length = queue_length,
        .queue_name = queue_name,
    };
}

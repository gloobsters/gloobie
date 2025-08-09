const std = @import("std");
pub const InitSettings = @This();

queue_name: []const u8,
queue_length: u32,

pub fn init(args: []const []const u8) !InitSettings {
    // -QueueName randomString -QueueCapacity 8388608

    if (args.len != 4)
        return error.InvalidNumberOfArguments;

    const offset: usize = if (args.len == 5) 1 else 0;

    if (!std.mem.eql(u8, args[offset], "-QueueName"))
        return error.InvalidQueueName;

    const queue_name = args[1 + offset];

    if (!std.mem.eql(u8, args[2 + offset], "-QueueCapacity"))
        return error.InvalidQueueLength;

    const queue_length = try std.fmt.parseInt(u32, args[3 + offset], 10);

    return .{
        .queue_length = queue_length,
        .queue_name = queue_name,
    };
}

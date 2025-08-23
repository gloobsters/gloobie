const std = @import("std");

const MessageHeader = @import("message.zig").MessageHeader;

pub fn getTicks() i64 {
    return @intCast(@divTrunc(std.time.nanoTimestamp(), 100));
}

pub fn paddedMessageLength(length: usize) usize {
    const size: f64 = @floatFromInt(length + @sizeOf(MessageHeader));
    const ceil: usize = @intFromFloat(@ceil(size / 8.0));
    return 8 * ceil;
}

pub fn messageBodyOffset(offset: usize) usize {
    return offset + @sizeOf(MessageHeader);
}

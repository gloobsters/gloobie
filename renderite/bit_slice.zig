const std = @import("std");

pub fn BitSlice(comptime BackingInteger: type) type {
    return struct {
        const Self = @This();

        const IndexType = std.math.IntFittingRange(0, std.math.maxInt(usize) * @bitSizeOf(BackingInteger));

        slice: []BackingInteger,

        fn byteIndex(index: IndexType) usize {
            return @intCast(@divFloor(index, @bitSizeOf(BackingInteger)));
        }

        fn byteBitIndex(index: IndexType) std.math.IntFittingRange(0, @bitSizeOf(BackingInteger) - 1) {
            return @intCast(index % @bitSizeOf(BackingInteger));
        }

        pub fn get(self: Self, index: IndexType) bool {
            const byte_index = byteIndex(index);
            const byte_bit_index = byteBitIndex(index);

            return (self.slice[byte_index] & (@as(BackingInteger, 1) << byte_bit_index)) > 0;
        }

        pub fn set(self: Self, index: IndexType, value: bool) void {
            const byte_index = byteIndex(index);
            const byte_bit_index = byteBitIndex(index);

            const mask = @as(BackingInteger, 1) << byte_bit_index;

            if (value) {
                self.slice[byte_index] |= mask;
            } else {
                self.slice[byte_index] &= ~mask;
            }
        }
    };
}

test BitSlice {
    var backing: [4]u32 = @splat(0);

    const bit_slice: BitSlice(u32) = .{
        .slice = &backing,
    };

    // test first bit
    try std.testing.expectEqual(false, bit_slice.get(0));
    bit_slice.set(0, true);
    try std.testing.expectEqual(true, bit_slice.get(0));
    bit_slice.set(0, false);
    try std.testing.expectEqual(false, bit_slice.get(0));

    // test non-first bit in first byte
    try std.testing.expectEqual(false, bit_slice.get(1));
    bit_slice.set(1, true);
    try std.testing.expectEqual(true, bit_slice.get(1));
    bit_slice.set(1, false);
    try std.testing.expectEqual(false, bit_slice.get(1));

    // make sure separate bits dont clobber each other
    try std.testing.expectEqual(false, bit_slice.get(32));
    bit_slice.set(32, true);
    try std.testing.expectEqual(false, bit_slice.get(0));
    try std.testing.expectEqual(true, bit_slice.get(32));
    bit_slice.set(32, false);
    try std.testing.expectEqual(false, bit_slice.get(32));
}

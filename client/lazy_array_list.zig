const std = @import("std");

pub fn roundUpTo(raw_size: usize, comptime multiple: comptime_int) usize {
    const remainder = raw_size % multiple;

    // Don't round up unnecessarily
    if (remainder == 0) {
        return raw_size;
    }

    return raw_size + (multiple - (remainder));
}

pub fn LazyArrayList(comptime Child: type) type {
    return struct {
        const Self = @This();

        contents: []Child,

        pub const empty: Self = .{ .contents = &.{} };

        pub fn resizeTo(self: *Self, gpa: std.mem.Allocator, new_size: usize, default_value: Child) !void {
            if (gpa.remap(self.contents, new_size)) |new_allocation| {
                // If it's bigger now, make sure to set the default values
                if (new_allocation.len > self.contents.len) {
                    @memset(new_allocation[self.contents.len..], default_value);
                }

                self.contents = new_allocation;
                return;
            }

            const to_copy = @min(new_size, self.contents.len);

            const new_allocation = try gpa.alloc(Child, new_size);
            // Copy in the new values
            @memcpy(new_allocation[0..to_copy], self.contents[0..to_copy]);
            // Apply the default value
            @memset(new_allocation[to_copy..], default_value);

            gpa.free(self.contents);

            self.contents = new_allocation;
        }
    };
}

const std = @import("std");

pub fn Id(comptime BackingType: type, comptime UniqueType: type) type {
    return enum(BackingType) {
        comptime {
            _ = UniqueType;
        }

        invalid = std.math.minInt(BackingType),
        _,

        const Self = @This();

        pub fn from(id: BackingType) Self {
            return @enumFromInt(id);
        }

        pub fn to(id: Self) BackingType {
            return @intFromEnum(id);
        }
    };
}

comptime {
    std.debug.assert(Id(i32, struct {}) != Id(i32, struct {}));
}

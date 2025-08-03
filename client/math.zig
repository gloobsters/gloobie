const std = @import("std");

pub fn srgbToLinear(comptime T: type, srgb: T) f32 {
    return if (srgb <= 0.04045) (srgb / 12.92) else std.math.pow(T, (srgb + 0.055) / 1.055, 2.4);
}

const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");

const log = std.log.scoped(.texture);

const Texture = @This();

const Graphics = struct {
    texture: gpu.Texture,

    pub fn deinit(self: Graphics, device: gpu.Device) void {
        device.releaseTexture(self.texture);
    }
};

filter_mode: renderite.Shared.TextureFilterMode,
aniso_level: i32,
wrap_u: renderite.Shared.TextureWrapMode,
wrap_v: renderite.Shared.TextureWrapMode,
mipmap_bias: f32,
format: ?struct {
    width: u32,
    height: u32,
    texture_format: renderite.Shared.TextureFormat,
    profile: renderite.Shared.ColorProfile,
    mipmap_count: u32,
},
graphics: ?Graphics,

pub fn create(properties: renderite.Shared.SetTexture2DProperties) Texture {
    return .{
        .filter_mode = properties.filterMode,
        .aniso_level = properties.anisoLevel,
        .wrap_u = properties.wrapU,
        .wrap_v = properties.wrapV,
        .mipmap_bias = properties.mipmapBias,
        .format = null,
        .graphics = null,
    };
}

pub fn deinit(self: Texture, device: gpu.Device) void {
    if (self.graphics) |graphics| {
        graphics.deinit(device);
    }
}

pub fn setProperties(self: *Texture, properties: renderite.Shared.SetTexture2DProperties) void {
    self.filter_mode = properties.filterMode;
    self.aniso_level = properties.anisoLevel;
    self.wrap_u = properties.wrapU;
    self.wrap_v = properties.wrapV;
    self.mipmap_bias = properties.mipmapBias;
}

pub fn setFormat(self: *Texture, renderite_format: renderite.Shared.SetTexture2DFormat, device: gpu.Device) !void {
    self.format = .{
        .width = @intCast(renderite_format.width),
        .height = @intCast(renderite_format.height),
        .mipmap_count = @intCast(renderite_format.mipmapCount),
        .profile = renderite_format.profile,
        .texture_format = renderite_format.format,
    };

    if (self.graphics) |graphics| {
        graphics.deinit(device);
    }

    // SAFETY: we just assigned it above
    const format = self.format.?;

    const texture_format = renderiteFormatToGpuFormat(format.texture_format, format.profile) orelse {
        std.debug.assert(false);

        return error.InvalidFormat;
    };

    const texture = try device.createTexture(.{
        .width = format.width,
        .height = format.height,
        .format = texture_format,
        .usage = .{ .sampler = true },
        .num_levels = format.mipmap_count,
        .layer_count_or_depth = 1,
    });
    errdefer device.releaseTexture(texture);

    log.debug("Created GPU texture for Texture {d}", .{renderite_format.assetId});

    self.graphics = .{
        .texture = texture,
    };
}

pub fn renderiteFormatToGpuFormat(format: renderite.Shared.TextureFormat, profile: renderite.Shared.ColorProfile) ?gpu.TextureFormat {
    // TODO: Add all missing formats to GPU
    return switch (profile) {
        .Linear => switch (format) {
            .Unknown => null,
            .Alpha8 => gpu.TextureFormat.a8_unorm,
            .R8 => gpu.TextureFormat.r8_unorm,
            .RGB24 => null,
            .ARGB32 => null,
            .RGBA32 => gpu.TextureFormat.r8g8b8a8_unorm,
            .BGRA32 => gpu.TextureFormat.b8g8r8a8_unorm,
            .RGB565 => null,
            .BGR565 => gpu.TextureFormat.b5g6r5_unorm,
            .RGBAHalf => gpu.TextureFormat.r16g16b16a16_float,
            .ARGBHalf => null,
            .RHalf => gpu.TextureFormat.r16_float,
            .RGHalf => gpu.TextureFormat.r16g16_float,
            .RGBAFloat => gpu.TextureFormat.r16g16b16a16_float,
            .ARGBFloat => null,
            .RFloat => gpu.TextureFormat.r32_float,
            .RGFloat => gpu.TextureFormat.r32g32_float,
            .BC1 => gpu.TextureFormat.bc1_rgba_unorm_compressed,
            .BC2 => gpu.TextureFormat.bc2_rgba_unorm_compressed,
            .BC3 => gpu.TextureFormat.bc3_rgba_unorm_compressed,
            .BC4 => gpu.TextureFormat.bc4_r_unorm_compressed,
            .BC5 => gpu.TextureFormat.bc5_rg_unorm_compressed,
            .BC6H => gpu.TextureFormat.bc6h_rgb_float_compressed,
            .BC7 => gpu.TextureFormat.bc7_rgba_unorm_compressed,
            .ETC2_RGB => null,
            .ETC2_RGBA1 => null,
            .ETC2_RGBA8 => null,
            .ASTC_4x4 => gpu.TextureFormat.astc_4x4_unorm_compressed,
            .ASTC_5x5 => gpu.TextureFormat.astc_5x5_unorm_compressed,
            .ASTC_6x6 => gpu.TextureFormat.astc_6x6_unorm_compressed,
            .ASTC_8x8 => gpu.TextureFormat.astc_8x8_unorm_compressed,
            .ASTC_10x10 => gpu.TextureFormat.astc_10x10_unorm_compressed,
            .ASTC_12x12 => gpu.TextureFormat.astc_12x12_unorm_compressed,
        },
        .sRGBAlpha, .sRGB => switch (format) {
            .Unknown => null,
            .Alpha8 => null,
            .R8 => null,
            .RGB24 => null,
            .ARGB32 => null,
            .RGBA32 => gpu.TextureFormat.r8g8b8a8_unorm_srgb,
            .BGRA32 => gpu.TextureFormat.b8g8r8a8_unorm_srgb,
            .RGB565 => null,
            .BGR565 => null,
            .RGBAHalf => null,
            .ARGBHalf => null,
            .RHalf => null,
            .RGHalf => null,
            .RGBAFloat => null,
            .ARGBFloat => null,
            .RFloat => null,
            .RGFloat => null,
            .BC1 => gpu.TextureFormat.bc1_rgba_unorm_srgb_compressed,
            .BC2 => gpu.TextureFormat.bc2_rgba_unorm_srgb_compressed,
            .BC3 => gpu.TextureFormat.bc3_rgba_unorm_srgb_compressed,
            .BC4 => null,
            .BC5 => null,
            .BC6H => null,
            .BC7 => gpu.TextureFormat.bc7_rgba_unorm_srgb_compressed,
            .ETC2_RGB => null,
            .ETC2_RGBA1 => null,
            .ETC2_RGBA8 => null,
            .ASTC_4x4 => gpu.TextureFormat.astc_4x4_unorm_srgb_compressed,
            .ASTC_5x5 => gpu.TextureFormat.astc_5x5_unorm_srgb_compressed,
            .ASTC_6x6 => gpu.TextureFormat.astc_6x6_unorm_srgb_compressed,
            .ASTC_8x8 => gpu.TextureFormat.astc_8x8_unorm_srgb_compressed,
            .ASTC_10x10 => gpu.TextureFormat.astc_10x10_unorm_srgb_compressed,
            .ASTC_12x12 => gpu.TextureFormat.astc_12x12_unorm_srgb_compressed,
        },
    };
}

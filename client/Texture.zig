const gpu = @import("gpu");
const renderite = @import("renderite");

pub fn renderiteFormatToGpuFormat(format: renderite.Shared.TextureFormat) ?gpu.TextureFormat {
    // TODO: audit sRGB vs. linear here! we *probably* want to be uploading into sRGB textures
    return switch (format) {
        .Unknown => null,
        .Alpha8 => gpu.TextureFormat.a8_unorm,
        .R8 => gpu.TextureFormat.r8_unorm,
        .RGB24 => null, // TODO: add to GPU
        .ARGB32 => null, // TODO: add to GPU
        .RGBA32 => gpu.TextureFormat.r8g8b8a8_unorm_srgb,
        .BGRA32 => gpu.TextureFormat.b8g8r8a8_unorm_srgb,
        .RGB565 => null, // TODO: add to GPU
        .BGR565 => gpu.TextureFormat.b5g6r5_unorm,
        .RGBAHalf => gpu.TextureFormat.r16g16b16a16_float,
        .ARGBHalf => null, // TODO: add to GPU
        .RHalf => gpu.TextureFormat.r16_float,
        .RGHalf => gpu.TextureFormat.r16g16_float,
        .RGBAFloat => gpu.TextureFormat.r16g16b16a16_float,
        .ARGBFloat => null, // TODO: add to GPU
        .RFloat => gpu.TextureFormat.r32_float,
        .RGFloat => gpu.TextureFormat.r32g32_float,
        .BC1 => gpu.TextureFormat.bc1_rgba_unorm_srgb_compressed,
        .BC2 => gpu.TextureFormat.bc2_rgba_unorm_srgb_compressed,
        .BC3 => gpu.TextureFormat.bc3_rgba_unorm_srgb_compressed,
        .BC4 => gpu.TextureFormat.bc4_r_unorm_compressed,
        .BC5 => gpu.TextureFormat.bc5_rg_unorm_compressed,
        .BC6H => gpu.TextureFormat.bc6h_rgb_float_compressed,
        .BC7 => gpu.TextureFormat.bc7_rgba_unorm_srgb_compressed,
        .ETC2_RGB => null, // TODO: add to GPU
        .ETC2_RGBA1 => null, // TODO: add to GPU
        .ETC2_RGBA8 => null, // TODO: add to GPU
        .ASTC_4x4 => gpu.TextureFormat.astc_4x4_unorm_srgb_compressed,
        .ASTC_5x5 => gpu.TextureFormat.astc_5x5_unorm_srgb_compressed,
        .ASTC_6x6 => gpu.TextureFormat.astc_6x6_unorm_srgb_compressed,
        .ASTC_8x8 => gpu.TextureFormat.astc_8x8_unorm_srgb_compressed,
        .ASTC_10x10 => gpu.TextureFormat.astc_10x10_unorm_srgb_compressed,
        .ASTC_12x12 => gpu.TextureFormat.astc_12x12_unorm_srgb_compressed,
    };
}

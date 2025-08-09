const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");

const graphics = @import("graphics.zig");

const log = std.log.scoped(.texture);

const Texture = @This();

const GraphicsData = struct {
    width: u32,
    height: u32,
    texture_format: renderite.Shared.TextureFormat,
    profile: renderite.Shared.ColorProfile,
    mipmap_count: u32,

    texture: gpu.Texture,
    // FIXME: do not create one sampler per texture! pool samplers between all textures!
    sampler: gpu.Sampler,
    binding: gpu.TextureSamplerBinding,
    /// Stores whether a mipmap has data, all mipmaps must have valid data before texture can be used
    data_available: []bool,
    ready: bool,

    pub fn deinit(self: GraphicsData, gpa: std.mem.Allocator, device: gpu.Device) void {
        device.releaseTexture(self.texture);
        device.releaseSampler(self.sampler);
        gpa.free(self.data_available);
    }
};

filter_mode: renderite.Shared.TextureFilterMode,
aniso_level: i32,
wrap_u: renderite.Shared.TextureWrapMode,
wrap_v: renderite.Shared.TextureWrapMode,
mipmap_bias: f32,
graphics_data: ?GraphicsData,

pub fn create(properties: renderite.Shared.SetTexture2DProperties) Texture {
    return .{
        .filter_mode = properties.filterMode,
        .aniso_level = properties.anisoLevel,
        .wrap_u = properties.wrapU,
        .wrap_v = properties.wrapV,
        .mipmap_bias = properties.mipmapBias,
        .graphics_data = null,
    };
}

pub fn deinit(self: Texture, gpa: std.mem.Allocator, device: gpu.Device) void {
    if (self.graphics_data) |graphics_data| {
        graphics_data.deinit(gpa, device);
    }
}

pub fn setProperties(self: *Texture, properties: renderite.Shared.SetTexture2DProperties) void {
    self.filter_mode = properties.filterMode;
    self.aniso_level = properties.anisoLevel;
    self.wrap_u = properties.wrapU;
    self.wrap_v = properties.wrapV;
    self.mipmap_bias = properties.mipmapBias;
}

pub fn setFormat(self: *Texture, gpa: std.mem.Allocator, device: gpu.Device, renderite_format: renderite.Shared.SetTexture2DFormat) !void {
    if (self.graphics_data) |graphics_data| {
        graphics_data.deinit(gpa, device);
    }

    const texture_format = renderiteFormatToGpuFormat(renderite_format.format, renderite_format.profile) orelse {
        std.debug.assert(false);

        return error.InvalidFormat;
    };

    var texture_name_buf: [64]u8 = undefined;
    // SAFETY: it's big enough
    const texture_name = std.fmt.bufPrintZ(&texture_name_buf, "Resonite Texture ({d})", .{renderite_format.assetId}) catch unreachable;

    const texture = try device.createTexture(.{
        .width = @intCast(renderite_format.width),
        .height = @intCast(renderite_format.height),
        .format = texture_format,
        .usage = .{ .sampler = true },
        .num_levels = @intCast(renderite_format.mipmapCount),
        .layer_count_or_depth = 1,
        .props = .{ .name = texture_name },
    });
    errdefer device.releaseTexture(texture);

    var sampler_name_buf: [128]u8 = undefined;
    // SAFETY: it's big enough
    const sampler_name = std.fmt.bufPrintZ(&sampler_name_buf, "Created Sampler ({s}/{s}/{s}/{d}/{d})", .{
        @tagName(self.wrap_u),
        @tagName(self.wrap_v),
        @tagName(self.filter_mode),
        self.aniso_level,
        self.mipmap_bias,
    }) catch unreachable;

    var sampler_parameters = renderiteSamplerParametersToGpuParameters(
        self.wrap_u,
        self.wrap_v,
        self.filter_mode,
        self.aniso_level,
        self.mipmap_bias,
    );
    sampler_parameters.props = .{ .name = sampler_name };

    const sampler = try device.createSampler(sampler_parameters);
    errdefer device.releaseSampler(sampler);

    log.debug("Created GPU texture for Texture {d}", .{renderite_format.assetId});

    const data_available: []bool = try gpa.alloc(bool, @intCast(renderite_format.mipmapCount));
    errdefer gpa.free(data_available);
    @memset(data_available, false);

    self.graphics_data = .{
        .width = @intCast(renderite_format.width),
        .height = @intCast(renderite_format.height),
        .mipmap_count = @intCast(renderite_format.mipmapCount),
        .profile = renderite_format.profile,
        .texture_format = renderite_format.format,

        .texture = texture,
        .sampler = sampler,
        .binding = .{
            .texture = texture,
            .sampler = sampler,
        },
        .data_available = data_available,
        .ready = false,
    };
}

pub fn setData(
    self: *Texture,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    data: renderite.Shared.SetTexture2DData,
    accessor: *renderite.SharedMemoryAccessor,
) !void {
    const data_slice = try accessor.getOrCreate(gpa, data.data);
    defer data_slice.release(accessor);

    // std.debug.print("Texture upload details: {any}\n", .{data});

    if (self.graphics_data == null) {
        log.err("Texture isn't init and has no graphics data! did we miss a set format command?", .{});

        return error.TextureMissingGraphicsData;
    }

    const graphics_data = &self.graphics_data.?;

    //SAFETY: engine should only ever give formats that we support
    const gpu_format = renderiteFormatToGpuFormat(graphics_data.texture_format, graphics_data.profile).?;

    const start_mip_level: u32 = @intCast(data.startMipLevel);
    const num_mips: u32 = @intCast(data.mipMapSizes.len);

    if (num_mips == 0) {
        log.warn("FE sent a texture upload with no mips!", .{});
        return;
    }

    var total_memory_needed: u32 = 0;
    for (data.mipMapSizes) |mipmap_size| {
        total_memory_needed += gpu_format.calculateSize(@intCast(mipmap_size.x), @intCast(mipmap_size.y), 1);
    }

    const copy_pass = try frame_context.getSharedCopyPass();

    const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(total_memory_needed, .upload);
    errdefer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM");

    {
        const transfer_buffer_memory = try frame_context.device.mapTransferBuffer(
            transfer_buffer_entry.transfer_buffer,
            true,
        );

        var write_ptr = transfer_buffer_memory;
        for (data.mipStarts, data.mipMapSizes) |mip_start_num, mip_pixel_size| {
            const mip_byte_start: usize = @intCast(mip_start_num);
            const mip_byte_size = gpu_format.calculateSize(@intCast(mip_pixel_size.x), @intCast(mip_pixel_size.y), 1);

            @memcpy(write_ptr, data_slice.data[mip_byte_start .. mip_byte_start + mip_byte_size]);

            write_ptr += mip_byte_size;
        }

        frame_context.device.unmapTransferBuffer(transfer_buffer_entry.transfer_buffer);
    }

    // if we have an upload region, we can't cycle
    var cycle: bool = !data.hint.hasRegion;
    var read_offset: u32 = 0;
    for (start_mip_level..(start_mip_level + num_mips), data.mipMapSizes) |mip_level, mip_pixel_size| {
        const mip_byte_size = gpu_format.calculateSize(@intCast(mip_pixel_size.x), @intCast(mip_pixel_size.y), 1);

        // FIXME: Renderite.Unity doesn't handle hint.hasRegion, and *presumedly* FE wont send it, but if it does, we need to start handling that!!!
        copy_pass.uploadToTexture(.{
            .offset = read_offset,
            .pixels_per_row = @intCast(mip_pixel_size.x),
            .rows_per_layer = @intCast(mip_pixel_size.y),
            .transfer_buffer = transfer_buffer_entry.transfer_buffer,
        }, .{
            .depth = 1,
            .width = @intCast(mip_pixel_size.x),
            .height = @intCast(mip_pixel_size.y),
            .mip_level = @intCast(mip_level),
            .texture = graphics_data.texture,
        }, cycle);

        read_offset += mip_byte_size;

        // don't cycle twice!
        cycle = false;

        graphics_data.data_available[mip_level] = true;
    }

    var all_ready: bool = true;
    for (graphics_data.data_available) |available| {
        all_ready |= available;
    }

    if (all_ready) {
        try frame_context.texture_readiness_queue.append(gpa, .from(data.assetId));
    }

    try frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry);
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

fn renderiteTextureWrapModeToGpuAddressMode(wrap_mode: renderite.Shared.TextureWrapMode) gpu.SamplerAddressMode {
    return switch (wrap_mode) {
        .Clamp => .clamp_to_edge,
        .Repeat => .repeat,
        .Mirror => .mirrored_repeat,
        .MirrorOnce => .mirrored_repeat, // FIXME: we need to add this to GPU!
    };
}

fn resoniteTextureFilterModeToGpuFilter(texture_filter_mode: renderite.Shared.TextureFilterMode) gpu.Filter {
    return switch (texture_filter_mode) {
        .Point => .nearest,
        .Bilinear => .linear, // FIXME: this needs to be made correct!
        .Trilinear => .linear,
        .Anisotropic => .linear, // FIXME: is this correct?
    };
}

pub fn renderiteSamplerParametersToGpuParameters(
    wrap_u: renderite.Shared.TextureWrapMode,
    wrap_v: renderite.Shared.TextureWrapMode,
    filter_mode: renderite.Shared.TextureFilterMode,
    aniso_level: i32,
    mipmap_bias: f32,
) gpu.SamplerCreateInfo {
    return .{
        .address_mode_u = renderiteTextureWrapModeToGpuAddressMode(wrap_u),
        .address_mode_v = renderiteTextureWrapModeToGpuAddressMode(wrap_v),
        .address_mode_w = .repeat, // FIXME: 3d textures will need this
        .compare = .less_or_equal, // FIXME: is this correct?
        .mag_filter = resoniteTextureFilterModeToGpuFilter(filter_mode),
        .min_filter = resoniteTextureFilterModeToGpuFilter(filter_mode),
        .max_anisotropy = if (aniso_level > 0) @floatFromInt(aniso_level) else null, // FIXME: is this correct?
        .mip_lod_bias = mipmap_bias,
        // FIXME: are these two correct?
        .min_lod = 0,
        .max_lod = 1000, // Eqivalent to VK_LOD_CLAMP_NONE
    };
}

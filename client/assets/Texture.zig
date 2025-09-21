const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");
pub const Type = renderite.shared.TextureType;

const graphics = @import("../graphics.zig");

const log = @import("logger").Scoped(.texture);

const Texture = @This();

const GraphicsData = struct {
    width: u32,
    height: u32,
    depth: u32,
    texture_format: renderite.shared.TextureFormat,
    profile: renderite.shared.ColorProfile,
    mipmap_count: u32,

    texture: gpu.Texture,
    // FIXME: do not create one sampler per texture! pool samplers between all textures!
    sampler: gpu.Sampler,
    binding: gpu.TextureSamplerBinding,
    /// Stores whether a mipmap has data, all mipmaps must have valid data before texture can be used
    data_available: []bool,
    upload_nonce: u64,
    ready: bool,

    pub fn deinit(self: GraphicsData, gpa: std.mem.Allocator, device: gpu.Device) void {
        device.releaseTexture(self.texture);
        device.releaseSampler(self.sampler);
        gpa.free(self.data_available);
    }
};

const Properties = struct {
    filter_mode: renderite.shared.TextureFilterMode,
    aniso_level: i32,
    wrap_u: renderite.shared.TextureWrapMode,
    wrap_v: renderite.shared.TextureWrapMode,
    wrap_w: renderite.shared.TextureWrapMode,
    mipmap_bias: f32,
    type: Type,
};

properties: Properties,
graphics_data: ?GraphicsData,

pub fn create2d(frame_context: *graphics.FrameContext, properties: renderite.shared.SetTexture2DProperties) !Texture {
    var texture: Texture = .{
        .properties = undefined,
        .graphics_data = null,
    };

    try texture.setProperties2d(frame_context, properties);

    return texture;
}

pub fn create3d(frame_context: *graphics.FrameContext, properties: renderite.shared.SetTexture3DProperties) !Texture {
    var texture: Texture = .{
        .properties = undefined,
        .graphics_data = null,
    };

    try texture.setProperties3d(frame_context, properties);

    return texture;
}

pub fn createCubemap(frame_context: *graphics.FrameContext, properties: renderite.shared.SetCubemapProperties) !Texture {
    var texture: Texture = .{
        .properties = undefined,
        .graphics_data = null,
    };

    try texture.setPropertiesCubemap(frame_context, properties);

    return texture;
}

pub fn deinit(self: Texture, gpa: std.mem.Allocator, device: gpu.Device) void {
    if (self.graphics_data) |graphics_data| {
        graphics_data.deinit(gpa, device);
    }
}

pub fn setProperties2d(
    self: *Texture,
    frame_context: *graphics.FrameContext,
    properties: renderite.shared.SetTexture2DProperties,
) !void {
    self.properties = .{
        .filter_mode = properties.filter_mode,
        .aniso_level = properties.aniso_level,
        .wrap_u = properties.wrap_u,
        .wrap_v = properties.wrap_v,
        .wrap_w = .clamp,
        .mipmap_bias = properties.mipmap_bias,
        .type = .texture_2d,
    };

    try frame_context.messaging_host.background.sendTimeout(.{
        .set_texture_2d_result = .{
            .asset_id = properties.asset_id,
            .instance_changed = false,
            .type = .{
                .format_set = false,
                .properties_set = true,
                .data_upload = false,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn setProperties3d(
    self: *Texture,
    frame_context: *graphics.FrameContext,
    properties: renderite.shared.SetTexture3DProperties,
) !void {
    self.properties = .{
        .filter_mode = properties.filter_mode,
        .aniso_level = properties.aniso_level,
        .wrap_u = properties.wrap_u,
        .wrap_v = properties.wrap_v,
        .wrap_w = properties.wrap_w,
        .type = .texture_3d,
        .mipmap_bias = 0,
    };

    try frame_context.messaging_host.background.sendTimeout(.{
        .set_texture_3d_result = .{
            .asset_id = properties.asset_id,
            .instance_changed = false,
            .type = .{
                .properties_set = true,
                .data_upload = false,
                .format_set = false,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn setPropertiesCubemap(
    self: *Texture,
    frame_context: *graphics.FrameContext,
    properties: renderite.shared.SetCubemapProperties,
) !void {
    self.properties = .{
        .filter_mode = properties.filter_mode,
        .aniso_level = properties.aniso_level,
        .wrap_u = .clamp,
        .wrap_v = .clamp,
        .wrap_w = .clamp,
        .type = .cubemap,
        .mipmap_bias = properties.mipmap_bias,
    };

    try frame_context.messaging_host.background.sendTimeout(.{
        .set_cubemap_result = .{
            .asset_id = properties.asset_id,
            .instance_changed = false,
            .type = .{
                .data_upload = false,
                .format_set = false,
                .properties_set = true,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn setFormat2d(self: *Texture, gpa: std.mem.Allocator, frame_context: *graphics.FrameContext, renderite_format: renderite.shared.SetTexture2DFormat) !void {
    if (self.graphics_data) |graphics_data| {
        graphics_data.deinit(gpa, frame_context.device);
    }

    const texture_format = renderiteFormatToGpuFormat(renderite_format.format, renderite_format.profile) orelse {
        std.debug.assert(false);

        return error.InvalidFormat;
    };

    var texture_name_buf: [64]u8 = undefined;
    // SAFETY: it's big enough
    const texture_name = std.fmt.bufPrintZ(&texture_name_buf, "Resonite Texture2D ({d})", .{renderite_format.asset_id}) catch unreachable;

    const texture = try frame_context.device.createTexture(.{
        .width = @intCast(renderite_format.width),
        .height = @intCast(renderite_format.height),
        .format = texture_format,
        .usage = .{ .sampler = true },
        .num_levels = @intCast(renderite_format.mipmap_count),
        .layer_count_or_depth = 1,
        .props = .{ .name = texture_name },
    });
    errdefer frame_context.device.releaseTexture(texture);

    var sampler_name_buf: [128]u8 = undefined;
    // SAFETY: it's big enough
    const sampler_name = std.fmt.bufPrintZ(&sampler_name_buf, "Created Sampler ({s}/{s}/{s}/{d}/{d})", .{
        @tagName(self.properties.wrap_u),
        @tagName(self.properties.wrap_v),
        @tagName(self.properties.filter_mode),
        self.properties.aniso_level,
        self.properties.mipmap_bias,
    }) catch unreachable;

    var sampler_parameters = renderiteSamplerParametersToGpuParameters(self.properties);
    sampler_parameters.props = .{ .name = sampler_name };

    const sampler = try frame_context.device.createSampler(sampler_parameters);
    errdefer frame_context.device.releaseSampler(sampler);

    log.trace(@src(), "Created GPU texture for Texture {d}", .{renderite_format.asset_id});

    const data_available: []bool = try gpa.alloc(bool, @intCast(renderite_format.mipmap_count));
    errdefer gpa.free(data_available);
    @memset(data_available, false);

    self.graphics_data = .{
        .width = @intCast(renderite_format.width),
        .height = @intCast(renderite_format.height),
        .depth = 1,
        .mipmap_count = @intCast(renderite_format.mipmap_count),
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
        .upload_nonce = 0,
    };

    try frame_context.messaging_host.background.sendTimeout(.{
        .set_texture_2d_result = .{
            .asset_id = renderite_format.asset_id,
            .instance_changed = true,
            .type = .{
                .format_set = true,
                .data_upload = false,
                .properties_set = false,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn setFormat3d(self: *Texture, gpa: std.mem.Allocator, frame_context: *graphics.FrameContext, renderite_format: renderite.shared.SetTexture3DFormat) !void {
    if (self.graphics_data) |graphics_data| {
        graphics_data.deinit(gpa, frame_context.device);
    }

    const texture_format = renderiteFormatToGpuFormat(renderite_format.format, renderite_format.profile) orelse {
        std.debug.assert(false);

        return error.InvalidFormat;
    };

    var texture_name_buf: [64]u8 = undefined;
    // SAFETY: it's big enough
    const texture_name = std.fmt.bufPrintZ(&texture_name_buf, "Resonite texture_3d ({d})", .{renderite_format.asset_id}) catch unreachable;

    const texture = try frame_context.device.createTexture(.{
        .width = @intCast(renderite_format.width),
        .height = @intCast(renderite_format.height),
        .layer_count_or_depth = @intCast(renderite_format.depth),
        .format = texture_format,
        .usage = .{ .sampler = true },
        .num_levels = @intCast(renderite_format.mipmap_count),
        .props = .{ .name = texture_name },
        .texture_type = .three_dimensional,
    });
    errdefer frame_context.device.releaseTexture(texture);

    var sampler_name_buf: [128]u8 = undefined;
    // SAFETY: it's big enough
    const sampler_name = std.fmt.bufPrintZ(&sampler_name_buf, "Created Sampler ({s}/{s}/{s}/{s}/{d}/{d})", .{
        @tagName(self.properties.wrap_u),
        @tagName(self.properties.wrap_v),
        @tagName(self.properties.wrap_w),
        @tagName(self.properties.filter_mode),
        self.properties.aniso_level,
        self.properties.mipmap_bias,
    }) catch unreachable;

    var sampler_parameters = renderiteSamplerParametersToGpuParameters(self.properties);
    sampler_parameters.props = .{ .name = sampler_name };

    const sampler = try frame_context.device.createSampler(sampler_parameters);
    errdefer frame_context.device.releaseSampler(sampler);

    log.trace(@src(), "Created GPU texture for Texture {d}", .{renderite_format.asset_id});

    const data_available: []bool = try gpa.alloc(bool, @intCast(renderite_format.mipmap_count));
    errdefer gpa.free(data_available);
    @memset(data_available, false);

    self.graphics_data = .{
        .width = @intCast(renderite_format.width),
        .height = @intCast(renderite_format.height),
        .depth = @intCast(renderite_format.depth),

        .mipmap_count = @intCast(renderite_format.mipmap_count),
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
        .upload_nonce = 0,
    };

    try frame_context.messaging_host.background.sendTimeout(.{
        .set_texture_3d_result = .{
            .asset_id = renderite_format.asset_id,
            .instance_changed = true,
            .type = .{
                .data_upload = false,
                .format_set = true,
                .properties_set = false,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn setFormatCubemap(self: *Texture, gpa: std.mem.Allocator, frame_context: *graphics.FrameContext, renderite_format: renderite.shared.SetCubemapFormat) !void {
    if (self.graphics_data) |graphics_data| {
        graphics_data.deinit(gpa, frame_context.device);
    }

    const texture_format = renderiteFormatToGpuFormat(renderite_format.format, renderite_format.profile) orelse {
        log.err(@src(), "Got invalid cubemap format {s}/{s} from FrooxEngine!", .{
            @tagName(renderite_format.format),
            @tagName(renderite_format.profile),
        });
        std.debug.assert(false);

        return error.InvalidFormat;
    };

    var texture_name_buf: [64]u8 = undefined;
    // SAFETY: it's big enough
    const texture_name = std.fmt.bufPrintZ(&texture_name_buf, "Resonite Cubemap ({d})", .{renderite_format.asset_id}) catch unreachable;

    const texture = try frame_context.device.createTexture(.{
        .width = @intCast(renderite_format.size),
        .height = @intCast(renderite_format.size),
        .layer_count_or_depth = 6, // 6 faces
        .format = texture_format,
        .usage = .{ .sampler = true },
        .num_levels = @intCast(renderite_format.mipmap_count),
        .props = .{ .name = texture_name },
        .texture_type = .cube,
    });
    errdefer frame_context.device.releaseTexture(texture);

    var sampler_name_buf: [128]u8 = undefined;
    // SAFETY: it's big enough
    const sampler_name = std.fmt.bufPrintZ(&sampler_name_buf, "Created Sampler ({s}/{d}/{d})", .{
        @tagName(self.properties.filter_mode),
        self.properties.aniso_level,
        self.properties.mipmap_bias,
    }) catch unreachable;

    var sampler_parameters = renderiteSamplerParametersToGpuParameters(self.properties);
    sampler_parameters.props = .{ .name = sampler_name };

    const sampler = try frame_context.device.createSampler(sampler_parameters);
    errdefer frame_context.device.releaseSampler(sampler);

    log.trace(@src(), "Created GPU texture for Cubemap {d}", .{renderite_format.asset_id});

    const data_available: []bool = try gpa.alloc(
        bool,
        @intCast(renderite_format.mipmap_count * 6), // 6 faces
    );
    errdefer gpa.free(data_available);
    @memset(data_available, false);

    self.graphics_data = .{
        .width = @intCast(renderite_format.size),
        .height = @intCast(renderite_format.size),
        .depth = 1,

        .mipmap_count = @intCast(renderite_format.mipmap_count),
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
        .upload_nonce = 0,
    };

    try frame_context.messaging_host.background.sendTimeout(.{
        .set_cubemap_result = .{
            .asset_id = renderite_format.asset_id,
            .instance_changed = true,
            .type = .{
                .data_upload = false,
                .format_set = true,
                .properties_set = false,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn setData2d(
    self: *Texture,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    data: renderite.shared.SetTexture2DData,
    accessor: *renderite.buffer.SharedMemoryAccessor,
) !void {
    const data_slice = try accessor.getOrCreate(u8, gpa, data.data);
    defer data_slice.release(accessor);

    // std.debug.print("Texture2D upload details: {any}\n", .{data});

    if (self.graphics_data == null) {
        log.err(@src(), "Texture isn't init and has no graphics data! did we miss a set format command?", .{});

        return error.TextureMissingGraphicsData;
    }

    const graphics_data = &self.graphics_data.?;

    //SAFETY: engine should only ever give formats that we support
    const gpu_format = renderiteFormatToGpuFormat(graphics_data.texture_format, graphics_data.profile).?;

    const start_mip_level: u32 = @intCast(data.start_mip_level);
    const num_mips: u32 = @intCast(data.mip_map_sizes.len);

    if (num_mips == 0) {
        log.warn(@src(), "FE sent a texture upload with no mips!", .{});
        return;
    }

    var total_memory_needed: u32 = 0;
    for (data.mip_map_sizes) |mipmap_size| {
        total_memory_needed += gpu_format.calculateSize(@intCast(mipmap_size.x), @intCast(mipmap_size.y), 1);
    }

    const copy_pass = try frame_context.getSharedCopyPass();

    const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(.{ .size = total_memory_needed, .value = .upload });
    {
        errdefer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM");

        {
            const transfer_buffer_memory = try frame_context.device.mapTransferBuffer(
                transfer_buffer_entry.value,
                true,
            );
            defer frame_context.device.unmapTransferBuffer(transfer_buffer_entry.value);

            var write_ptr = transfer_buffer_memory;
            for (data.mip_starts, data.mip_map_sizes) |mip_start_num, mip_pixel_size| {
                const mip_pixel_start: u32 = @intCast(mip_start_num);
                const mip_byte_size = gpu_format.calculateSize(@intCast(mip_pixel_size.x), @intCast(mip_pixel_size.y), 1);

                const mip_byte_start = pixelToByte(mip_pixel_start, graphics_data.texture_format);

                @memcpy(write_ptr, data_slice.data[mip_byte_start .. mip_byte_start + mip_byte_size]);

                write_ptr += mip_byte_size;
            }
        }

        // if we have an upload region, we can't cycle
        var cycle: bool = !data.hint.has_region;
        var read_offset: u32 = 0;
        for (start_mip_level..(start_mip_level + num_mips), data.mip_map_sizes) |mip_level, mip_pixel_size| {
            const mip_byte_size = gpu_format.calculateSize(@intCast(mip_pixel_size.x), @intCast(mip_pixel_size.y), 1);

            const aligned_pixel_size = alignSize(graphics_data.texture_format, .{ @intCast(mip_pixel_size.x), @intCast(mip_pixel_size.y) });

            const destination_width, const destination_height = calculateMipSize(graphics_data.width, graphics_data.height, @intCast(mip_level));

            if (destination_width != mip_pixel_size.x or destination_height != mip_pixel_size.y) {
                log.warn(@src(), "Got mipmap with weird extents! This is likely a FE bug! See #56. Real extents: {d}x{d}, gotten extents: {d}x{d}", .{
                    destination_width,
                    destination_height,
                    mip_pixel_size.x,
                    mip_pixel_size.y,
                });
            }

            // FIXME: Renderite.Unity doesn't handle hint.hasRegion, and *presumedly* FE wont send it, but if it does, we need to start handling that!!!
            copy_pass.uploadToTexture(.{
                .offset = read_offset,
                .pixels_per_row = aligned_pixel_size[0],
                .rows_per_layer = aligned_pixel_size[1],
                .transfer_buffer = transfer_buffer_entry.value,
            }, .{
                .depth = 1,
                .width = destination_width,
                .height = destination_height,
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
            const nonce = frame_context.upload_nonce.fetchAdd(1, .seq_cst);

            graphics_data.upload_nonce = nonce;

            try frame_context.texture_readiness_queue.append(gpa, .{
                .nonce = nonce,
                .handle = .{
                    .id = .from(data.asset_id),
                    .type = .texture_2d,
                },
            });
        }
    }
    try frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry);

    try frame_context.messaging_host.background.sendTimeout(.{
        .set_texture_2d_result = .{
            .asset_id = data.asset_id,
            .instance_changed = false,
            .type = .{
                .data_upload = true,
                .format_set = false,
                .properties_set = false,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn setData3d(
    self: *Texture,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    data: renderite.shared.SetTexture3DData,
    accessor: *renderite.buffer.SharedMemoryAccessor,
) !void {
    const data_slice = try accessor.getOrCreate(u8, gpa, data.data);
    defer data_slice.release(accessor);

    // std.debug.print("texture_3d upload details: {any}\n", .{data});

    if (self.graphics_data == null) {
        log.err(@src(), "Texture isn't init and has no graphics data! did we miss a set format command?", .{});

        return error.TextureMissingGraphicsData;
    }

    const graphics_data = &self.graphics_data.?;

    const gpu_format = renderiteFormatToGpuFormat(graphics_data.texture_format, graphics_data.profile).?;

    const memory_needed = gpu_format.calculateSize(graphics_data.width, graphics_data.height, graphics_data.depth);

    if (data_slice.data.len < memory_needed) {
        return error.BadDataGiven;
    }

    const copy_pass = try frame_context.getSharedCopyPass();

    const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(.{ .size = memory_needed, .value = .upload });
    {
        errdefer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM");

        {
            const transfer_buffer_memory = try frame_context.device.mapTransferBuffer(
                transfer_buffer_entry.value,
                true,
            );
            defer frame_context.device.unmapTransferBuffer(transfer_buffer_entry.value);

            @memcpy(transfer_buffer_memory, data_slice.data[0..memory_needed]);
        }

        const aligned_pixel_size = alignSize(graphics_data.texture_format, .{ graphics_data.width, graphics_data.height });

        copy_pass.uploadToTexture(.{
            .offset = 0,
            .pixels_per_row = aligned_pixel_size[0],
            .rows_per_layer = aligned_pixel_size[1],
            .transfer_buffer = transfer_buffer_entry.value,
        }, .{
            .texture = graphics_data.texture,
            .width = graphics_data.width,
            .height = graphics_data.height,
            .depth = graphics_data.depth,
            .mip_level = 0, // NOTE: texture3d has no mipmaps
        }, true);
    }

    try frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry);

    const nonce = frame_context.upload_nonce.fetchAdd(1, .seq_cst);

    graphics_data.upload_nonce = nonce;

    try frame_context.texture_readiness_queue.append(gpa, .{
        .handle = .{
            .id = .from(data.asset_id),
            .type = .texture_3d,
        },
        .nonce = nonce,
    });
    try frame_context.messaging_host.background.sendTimeout(.{
        .set_texture_3d_result = .{
            .asset_id = data.asset_id,
            .instance_changed = false,
            .type = .{
                .data_upload = true,
                .format_set = false,
                .properties_set = false,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn setDataCubemap(
    self: *Texture,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    data: renderite.shared.SetCubemapData,
    accessor: *renderite.buffer.SharedMemoryAccessor,
) !void {
    const data_slice = try accessor.getOrCreate(u8, gpa, data.data);
    defer data_slice.release(accessor);

    // std.debug.print("Cubemap upload details: {any}\n", .{data});

    if (self.graphics_data == null) {
        log.err(@src(), "Texture isn't init and has no graphics data! did we miss a set format command?", .{});

        return error.TextureMissingGraphicsData;
    }

    const start_mip_level: u32 = @intCast(data.start_mip_level);
    const num_mips: u32 = @intCast(data.mip_map_sizes.len);

    const graphics_data = &self.graphics_data.?;

    const gpu_format = renderiteFormatToGpuFormat(graphics_data.texture_format, graphics_data.profile).?;

    var total_memory_needed: u32 = 0;
    for (data.mip_map_sizes) |mipmap_size| {
        total_memory_needed += gpu_format.calculateSize(
            @intCast(mipmap_size.x),
            @intCast(mipmap_size.y),
            6, // 6 faces
        );
    }

    const copy_pass = try frame_context.getSharedCopyPass();

    const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(.{ .size = total_memory_needed, .value = .upload });
    {
        errdefer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM");

        {
            const transfer_buffer_memory = try frame_context.device.mapTransferBuffer(
                transfer_buffer_entry.value,
                true,
            );
            defer frame_context.device.unmapTransferBuffer(transfer_buffer_entry.value);

            var write_ptr = transfer_buffer_memory;

            for (0..6) |face_idx| {
                const face_mip_starts = data.mip_starts[face_idx];

                for (data.mip_map_sizes, 0..) |raw_mipmap_pixel_size, mip_index| {
                    const destination_width, const destination_height = calculateMipSize(
                        graphics_data.width,
                        graphics_data.height,
                        @intCast(mip_index + start_mip_level),
                    );

                    if (destination_width != raw_mipmap_pixel_size.x or destination_height != raw_mipmap_pixel_size.y) {
                        log.warn(@src(), "FrooxEngine sent a weird texture size again! Got {d}x{d}, expected {d}x{d}", .{
                            raw_mipmap_pixel_size.x,
                            raw_mipmap_pixel_size.y,
                            destination_width,
                            destination_height,
                        });
                    }

                    const mipmap_pixel_size = alignSize(
                        graphics_data.texture_format,
                        .{ destination_width, destination_height },
                    );

                    const num_pixels = mipmap_pixel_size[0] * mipmap_pixel_size[1];
                    const byte_start_offset = pixelToByte(@intCast(face_mip_starts[mip_index]), graphics_data.texture_format);
                    const num_bytes = pixelToByte(num_pixels, graphics_data.texture_format);

                    @memcpy(write_ptr, data_slice.data[byte_start_offset..(byte_start_offset + num_bytes)]);

                    write_ptr += num_bytes;
                }
            }
        }

        var cycle: bool = true;
        var read_offset: u32 = 0;
        for (0..6) |face_idx| {
            for (start_mip_level..(start_mip_level + num_mips), data.mip_map_sizes) |mip_level, raw_mipmap_pixel_size| {
                const destination_width, const destination_height = calculateMipSize(
                    graphics_data.width,
                    graphics_data.height,
                    @intCast(mip_level),
                );

                if (destination_width != raw_mipmap_pixel_size.x or destination_height != raw_mipmap_pixel_size.y) {
                    log.warn(@src(), "FrooxEngine sent a weird texture size again! Got {d}x{d}, expected {d}x{d}", .{
                        raw_mipmap_pixel_size.x,
                        raw_mipmap_pixel_size.y,
                        destination_width,
                        destination_height,
                    });
                }

                const mipmap_pixel_size = alignSize(
                    graphics_data.texture_format,
                    .{ destination_width, destination_height },
                );

                const num_pixels = mipmap_pixel_size[0] * mipmap_pixel_size[1];
                const num_bytes = pixelToByte(num_pixels, graphics_data.texture_format);

                copy_pass.uploadToTexture(.{
                    .offset = read_offset,
                    .pixels_per_row = mipmap_pixel_size[0],
                    .rows_per_layer = mipmap_pixel_size[1],
                    .transfer_buffer = transfer_buffer_entry.value,
                }, .{
                    .depth = 1,
                    .width = @intCast(destination_width),
                    .height = @intCast(destination_height),
                    .mip_level = @intCast(mip_level),
                    .layer = @intCast(face_idx),
                    .texture = graphics_data.texture,
                }, cycle);

                read_offset += num_bytes;

                // don't cycle twice!
                cycle = false;

                graphics_data.data_available[(mip_level * 6) + face_idx] = true;
            }
        }

        var all_ready: bool = true;
        for (graphics_data.data_available) |available| {
            all_ready |= available;
        }

        if (all_ready) {
            const nonce = frame_context.upload_nonce.fetchAdd(1, .seq_cst);

            graphics_data.upload_nonce = nonce;

            try frame_context.texture_readiness_queue.append(gpa, .{
                .handle = .{
                    .id = .from(data.asset_id),
                    .type = .cubemap,
                },
                .nonce = nonce,
            });
        }
    }
    try frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry);

    try frame_context.messaging_host.background.sendTimeout(.{
        .set_cubemap_result = .{
            .asset_id = data.asset_id,
            .instance_changed = false,
            .type = .{
                .data_upload = true,
                .format_set = false,
                .properties_set = false,
            },
        },
    }, std.time.ns_per_s * 10);
}

pub fn renderiteFormatToGpuFormat(format: renderite.shared.TextureFormat, profile: renderite.shared.ColorProfile) ?gpu.TextureFormat {
    // TODO: Add all missing formats to GPU
    return switch (profile) {
        .linear => switch (format) {
            .unknown => null,
            .alpha8 => gpu.TextureFormat.a8_unorm,
            .r8 => gpu.TextureFormat.r8_unorm,
            .rgb24 => null,
            .argb32 => null,
            .rgba32 => gpu.TextureFormat.r8g8b8a8_unorm,
            .bgra32 => gpu.TextureFormat.b8g8r8a8_unorm,
            .rgb565 => null,
            .bgr565 => gpu.TextureFormat.b5g6r5_unorm,
            .rgba_half => gpu.TextureFormat.r16g16b16a16_float,
            .argb_half => null,
            .r_half => gpu.TextureFormat.r16_float,
            .rg_half => gpu.TextureFormat.r16g16_float,
            .rgba_float => gpu.TextureFormat.r16g16b16a16_float,
            .argb_float => null,
            .r_float => gpu.TextureFormat.r32_float,
            .rg_float => gpu.TextureFormat.r32g32_float,
            .bc1 => gpu.TextureFormat.bc1_rgba_unorm_compressed,
            .bc2 => gpu.TextureFormat.bc2_rgba_unorm_compressed,
            .bc3 => gpu.TextureFormat.bc3_rgba_unorm_compressed,
            .bc4 => gpu.TextureFormat.bc4_r_unorm_compressed,
            .bc5 => gpu.TextureFormat.bc5_rg_unorm_compressed,
            .bc6_h => gpu.TextureFormat.bc6h_rgb_float_compressed,
            .bc7 => gpu.TextureFormat.bc7_rgba_unorm_compressed,
            .etc2_rgb => null,
            .etc2_rgba1 => null,
            .etc2_rgba8 => null,
            .astc_4x4 => gpu.TextureFormat.astc_4x4_unorm_compressed,
            .astc_5x5 => gpu.TextureFormat.astc_5x5_unorm_compressed,
            .astc_6x6 => gpu.TextureFormat.astc_6x6_unorm_compressed,
            .astc_8x8 => gpu.TextureFormat.astc_8x8_unorm_compressed,
            .astc_10x10 => gpu.TextureFormat.astc_10x10_unorm_compressed,
            .astc_12x12 => gpu.TextureFormat.astc_12x12_unorm_compressed,
        },
        .s_rgb_alpha, .s_rgb => switch (format) {
            .unknown => null,
            .alpha8 => null,
            .r8 => null,
            .rgb24 => null,
            .argb32 => null,
            .rgba32 => gpu.TextureFormat.r8g8b8a8_unorm_srgb,
            .bgra32 => gpu.TextureFormat.b8g8r8a8_unorm_srgb,
            .rgb565 => null,
            .bgr565 => null,
            .rgba_half => null,
            .argb_half => null,
            .r_half => null,
            .rg_half => null,
            .rgba_float => null,
            .argb_float => null,
            .r_float => null,
            .rg_float => null,
            .bc1 => gpu.TextureFormat.bc1_rgba_unorm_srgb_compressed,
            .bc2 => gpu.TextureFormat.bc2_rgba_unorm_srgb_compressed,
            .bc3 => gpu.TextureFormat.bc3_rgba_unorm_srgb_compressed,
            .bc4 => null,
            .bc5 => null,
            .bc6_h => gpu.TextureFormat.bc6h_rgb_float_compressed, // TODO: have some way of converting sRGB -> Linear in the shaders
            .bc7 => gpu.TextureFormat.bc7_rgba_unorm_srgb_compressed,
            .etc2_rgb => null,
            .etc2_rgba1 => null,
            .etc2_rgba8 => null,
            .astc_4x4 => gpu.TextureFormat.astc_4x4_unorm_srgb_compressed,
            .astc_5x5 => gpu.TextureFormat.astc_5x5_unorm_srgb_compressed,
            .astc_6x6 => gpu.TextureFormat.astc_6x6_unorm_srgb_compressed,
            .astc_8x8 => gpu.TextureFormat.astc_8x8_unorm_srgb_compressed,
            .astc_10x10 => gpu.TextureFormat.astc_10x10_unorm_srgb_compressed,
            .astc_12x12 => gpu.TextureFormat.astc_12x12_unorm_srgb_compressed,
        },
    };
}

fn renderiteTextureWrapModeToGpuAddressMode(wrap_mode: renderite.shared.TextureWrapMode) gpu.SamplerAddressMode {
    return switch (wrap_mode) {
        .clamp => .clamp_to_edge,
        .repeat => .repeat,
        .mirror => .mirrored_repeat,
        .mirror_once => .mirrored_repeat, // FIXME: we need to add this to GPU!
    };
}

fn resoniteTextureFilterModeToGpuFilter(texture_filter_mode: renderite.shared.TextureFilterMode) gpu.Filter {
    return switch (texture_filter_mode) {
        .point => .nearest,
        .bilinear => .linear, // FIXME: this needs to be made correct!
        .trilinear => .linear,
        .anisotropic => .linear, // FIXME: is this correct?
    };
}

pub fn renderiteSamplerParametersToGpuParameters(properties: Properties) gpu.SamplerCreateInfo {
    return .{
        .address_mode_u = renderiteTextureWrapModeToGpuAddressMode(properties.wrap_u),
        .address_mode_v = renderiteTextureWrapModeToGpuAddressMode(properties.wrap_v),
        .address_mode_w = renderiteTextureWrapModeToGpuAddressMode(properties.wrap_w),
        .compare = .less_or_equal, // FIXME: is this correct?
        .mag_filter = resoniteTextureFilterModeToGpuFilter(properties.filter_mode),
        .min_filter = resoniteTextureFilterModeToGpuFilter(properties.filter_mode),
        .max_anisotropy = if (properties.aniso_level > 0) @floatFromInt(properties.aniso_level) else null, // FIXME: is this correct?
        .mip_lod_bias = properties.mipmap_bias,
        // FIXME: are these two correct?
        .min_lod = 0,
        .max_lod = 1000, // Eqivalent to VK_LOD_CLAMP_NONE
    };
}

pub fn pixelToByte(pixel: u32, format: renderite.shared.TextureFormat) u32 {
    const pixel_float: f64 = @floatFromInt(pixel);

    const bit: u64 = @intFromFloat(pixel_float * bitsPerPixel(format));

    return @intCast(@divExact(bit, 8));
}

test pixelToByte {
    try std.testing.expectEqual(@as(u32, 4), pixelToByte(1, .rgba32));
}

fn calculateMipSize(width: u32, height: u32, level: u32) struct { u32, u32 } {
    if (level == 0) {
        return .{ width, height };
    }

    return .{
        @max(1, width / (@as(u32, 2) << @intCast(level - 1))),
        @max(1, height / (@as(u32, 2) << @intCast(level - 1))),
    };
}

test calculateMipSize {
    const level_0 = calculateMipSize(64, 64, 0);
    try std.testing.expectEqual(64, level_0[0]);
    try std.testing.expectEqual(64, level_0[1]);

    const level_1 = calculateMipSize(64, 64, 1);
    try std.testing.expectEqual(32, level_1[0]);
    try std.testing.expectEqual(32, level_1[1]);

    const level_2 = calculateMipSize(64, 64, 2);
    try std.testing.expectEqual(16, level_2[0]);
    try std.testing.expectEqual(16, level_2[1]);

    const level_3 = calculateMipSize(64, 64, 3);
    try std.testing.expectEqual(8, level_3[0]);
    try std.testing.expectEqual(8, level_3[1]);

    const level_99 = calculateMipSize(64, 64, 31);
    try std.testing.expectEqual(1, level_99[0]);
    try std.testing.expectEqual(1, level_99[1]);
}

pub fn bitsPerPixel(format: renderite.shared.TextureFormat) f64 {
    return switch (format) {
        .bc1,
        .bc4,
        .etc2_rgb,
        .etc2_rgba1,
        => 4,

        .alpha8,
        .r8,
        .bc2,
        .bc3,
        .bc5,
        .bc6_h,
        .bc7,
        .etc2_rgba8,
        => 8,

        .rgb565,
        .bgr565,
        .r_half,
        .rg_half,
        => 16,

        .rgb24 => 24,

        .argb32,
        .rgba32,
        .bgra32,
        .r_float,
        => 32,

        .rgba_half,
        .argb_half,
        .rg_float,
        => 64,

        .rgba_float,
        .argb_float,
        => 128,

        inline .astc_4x4,
        .astc_5x5,
        .astc_6x6,
        .astc_8x8,
        .astc_10x10,
        .astc_12x12,
        => |atsc| {
            const block_width, const block_height = blockSize(atsc);

            return 128.0 / @as(f64, @floatFromInt(block_width * block_height));
        },

        .unknown => @panic("invalid texture format"),
    };
}

fn alignBlock(size: u32, block_size: u32) u32 {
    return size + (block_size - size % block_size) % block_size;
}

fn alignSize(format: renderite.shared.TextureFormat, size: struct { u32, u32 }) struct { u32, u32 } {
    const block_size = blockSize(format);

    return .{
        alignBlock(size[0], block_size[0]),
        alignBlock(size[1], block_size[1]),
    };
}

pub fn blockSize(format: renderite.shared.TextureFormat) struct { u32, u32 } {
    return switch (format) {
        .argb32,
        .argb_float,
        .argb_half,
        .bgr565,
        .bgra32,
        .r8,
        .r_float,
        .rgb24,
        .rgb565,
        .rgba32,
        .rgba_float,
        .rgba_half,
        .rg_float,
        .rg_half,
        .r_half,
        .alpha8,
        => .{ 1, 1 },

        .bc1,
        .bc2,
        .bc3,
        .bc4,
        .bc5,
        .bc6_h,
        .bc7,
        .etc2_rgb,
        .etc2_rgba1,
        .etc2_rgba8,
        .astc_4x4,
        => .{ 4, 4 },

        .astc_5x5 => .{ 5, 5 },
        .astc_6x6 => .{ 6, 6 },
        .astc_8x8 => .{ 8, 8 },
        .astc_10x10 => .{ 10, 10 },
        .astc_12x12 => .{ 12, 12 },

        .unknown => @panic("invalid texture format"),
    };
}

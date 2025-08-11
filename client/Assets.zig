const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");

const graphics = @import("graphics.zig");
const Texture = @import("Texture.zig");

const log = std.log.scoped(.assets);

const Assets = @This();

pub const AssetId = enum(i32) {
    _,

    pub fn from(id: i32) AssetId {
        return @enumFromInt(id);
    }

    pub fn to(id: AssetId) i32 {
        return @intFromEnum(id);
    }
};

const TextureReadyFenceHandlerContext = struct {
    gpa: std.mem.Allocator,
    assets: *Assets,
    textures: []const AssetId,
};

fn textureReadyHandler(context: TextureReadyFenceHandlerContext) !void {
    context.assets.lock.lock();
    defer context.assets.lock.unlock();

    for (context.textures) |texture_id| {
        // SAFETY: textures should never be de-init by this moment!
        const texture = context.assets.textures.getPtr(texture_id).?;

        // SAFETY: texture should have graphics data right now!
        texture.graphics_data.?.ready = true;

        // Whisper of successful ascension to readiness
        if (texture.graphics_data) |*graphics_data| {
            const whisper_msg = try std.fmt.allocPrint(context.gpa, "Texture {d} has achieved readiness and joined the rendered realm", .{texture_id.to()});
            try graphics_data.whisperToTheVoid(context.gpa, .ascended, whisper_msg);
            context.gpa.free(whisper_msg);
        }

        log.debug("Texture {d} transcends to readiness!", .{texture_id.to()});
    }
}

fn deinitTextureReadyHandler(context: TextureReadyFenceHandlerContext) void {
    context.gpa.free(context.textures);
}

pub const TextureReadyFenceHandler = graphics.FenceHandler(TextureReadyFenceHandlerContext, textureReadyHandler, deinitTextureReadyHandler, "texture_ready_handler");

lock: std.Thread.RwLock,
textures: std.AutoHashMapUnmanaged(AssetId, Texture),

pub const empty: Assets = .{
    .lock = .{},
    .textures = .empty,
};

pub fn deinit(self: *Assets, gpa: std.mem.Allocator, device: gpu.Device) void {
    self.lock.lock();
    defer self.lock.unlock();

    var tex_iter = self.textures.valueIterator();
    while (tex_iter.next()) |texture| {
        texture.deinit(gpa, device);
    }

    self.textures.deinit(gpa);
}

/// Called to check for pending fences and apply and needed state
pub fn mainThreadTick(self: *Assets, gpa: std.mem.Allocator, device: gpu.Device) void {
    _ = self;
    _ = gpa;
    _ = device;
}

pub fn setTexture2dPropertiesOrCreate(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    properties: renderite.Shared.SetTexture2DProperties,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const result = try self.textures.getOrPut(gpa, .from(properties.assetId));

    const texture = result.value_ptr;
    if (result.found_existing) {
        try texture.setProperties2d(frame_context, properties);
        log.debug("Updated properties of Texture 2D {d}", .{properties.assetId});
    } else {
        texture.* = try .create2d(frame_context, properties);
        log.debug("Created Texture 2D with ID {d}", .{properties.assetId});
    }
}

pub fn setTexture2dFormat(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    format: renderite.Shared.SetTexture2DFormat,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.textures.getPtr(.from(format.assetId)) orelse return error.MissingAsset;

    try texture.setFormat2d(gpa, frame_context, format);

    log.debug("Updated Texture ({d}) format to {s} ({s}), size {d}x{d}", .{
        format.assetId,
        @tagName(format.format),
        @tagName(format.profile),
        format.width,
        format.height,
    });
}

pub fn setTexture2dData(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    data: renderite.Shared.SetTexture2DData,
    accessor: *renderite.SharedMemoryAccessor,
) !void {
    const texture = self.textures.getPtr(.from(data.assetId)) orelse return error.MissingAsset;

    try texture.setData2d(gpa, frame_context, data, accessor);
}

pub fn setTexture3dPropertiesOrCreate(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    properties: renderite.Shared.SetTexture3DProperties,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const result = try self.textures.getOrPut(gpa, .from(properties.assetId));

    const texture = result.value_ptr;
    if (result.found_existing) {
        try texture.setProperties3d(frame_context, properties);
        log.debug("Updated properties of Texture 2D {d}", .{properties.assetId});
    } else {
        texture.* = try .create3d(frame_context, properties);
        log.debug("Created Texture 2D with ID {d}", .{properties.assetId});
    }
}

pub fn setTexture3dFormat(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    format: renderite.Shared.SetTexture3DFormat,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.textures.getPtr(.from(format.assetId)) orelse return error.MissingAsset;

    try texture.setFormat3d(gpa, frame_context, format);

    log.debug("Updated Texture ({d}) format to {s} ({s}), size {d}x{d}x{d}", .{
        format.assetId,
        @tagName(format.format),
        @tagName(format.profile),
        format.width,
        format.height,
        format.depth,
    });
}

pub fn setTexture3dData(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    data: renderite.Shared.SetTexture3DData,
    accessor: *renderite.SharedMemoryAccessor,
) !void {
    const texture = self.textures.getPtr(.from(data.assetId)) orelse return error.MissingAsset;

    try texture.setData3d(gpa, frame_context, data, accessor);
}

pub fn setCubemapPropertiesOrCreate(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    properties: renderite.Shared.SetCubemapProperties,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const result = try self.textures.getOrPut(gpa, .from(properties.assetId));

    const texture = result.value_ptr;
    if (result.found_existing) {
        try texture.setPropertiesCubemap(frame_context, properties);
        log.debug("Updated properties of Cubemap {d}", .{properties.assetId});
    } else {
        texture.* = try .createCubemap(frame_context, properties);
        log.debug("Created Cubemap with ID {d}", .{properties.assetId});
    }
}

pub fn setCubemapFormat(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    format: renderite.Shared.SetCubemapFormat,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.textures.getPtr(.from(format.assetId)) orelse return error.MissingAsset;

    try texture.setFormatCubemap(gpa, frame_context, format);

    log.debug("Updated Cubemap ({d}) format to {s} ({s}), size {d}", .{
        format.assetId,
        @tagName(format.format),
        @tagName(format.profile),
        format.size,
    });
}

pub fn setCubemapData(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    data: renderite.Shared.SetCubemapData,
    accessor: *renderite.SharedMemoryAccessor,
) !void {
    const texture = self.textures.getPtr(.from(data.assetId)) orelse return error.MissingAsset;

    try texture.setDataCubemap(gpa, frame_context, data, accessor);
}

/// Gather statistics about the eldritch state of our texture manifestations
pub fn gatherEldritchStatistics(self: *Assets, gpa: std.mem.Allocator) ![]const u8 {
    self.lock.lock();
    defer self.lock.unlock();
    
    var stats = std.ArrayList(u8).init(gpa);
    defer stats.deinit();
    
    const writer = stats.writer();
    
    try writer.print("=== Eldritch Texture Realm Statistics ===\n");
    
    var state_counts = std.EnumMap(Texture.EldritchState, u32).init(.{});
    var total_textures: u32 = 0;
    var ready_textures: u32 = 0;
    var problem_textures: u32 = 0;
    
    var texture_iterator = self.textures.iterator();
    while (texture_iterator.next()) |entry| {
        total_textures += 1;
        
        if (entry.value_ptr.graphics_data) |graphics_data| {
            if (graphics_data.ready) ready_textures += 1;
            
            const current_count = state_counts.get(graphics_data.eldritch_state) orelse 0;
            state_counts.put(graphics_data.eldritch_state, current_count + 1);
            
            // Count problematic textures
            if (graphics_data.eldritch_state != .mortal and graphics_data.eldritch_state != .ascended) {
                problem_textures += 1;
            }
        } else {
            // Textures without graphics data are lost in the ethereal realm
            const current_count = state_counts.get(.lost_in_void) orelse 0;
            state_counts.put(.lost_in_void, current_count + 1);
            problem_textures += 1;
        }
    }
    
    try writer.print("Total Manifestations: {d}\n", .{total_textures});
    try writer.print("Ready for Rendering: {d}\n", .{ready_textures});
    try writer.print("Problematic Entities: {d}\n", .{problem_textures});
    try writer.print("\nEldritch State Distribution:\n");
    
    var state_iter = state_counts.iterator();
    while (state_iter.next()) |state_entry| {
        try writer.print("  {s}: {d}\n", .{ @tagName(state_entry.key), state_entry.value });
    }
    
    // Add warnings for concerning patterns
    if (problem_textures > total_textures / 4) {
        try writer.print("\n⚠️  WARNING: Over 25% of textures are in problematic states!\n");
    }
    
    if (state_counts.get(.gpu_madness) orelse 0 > 0) {
        try writer.print("\n💀 CRITICAL: GPU has descended into madness processing textures!\n");
    }
    
    return try gpa.dupe(u8, stats.items);
}

/// Attempt to rehabilitate textures that have fallen into eldritch states
pub fn attemptEldritchReconnection(self: *Assets, gpa: std.mem.Allocator) !u32 {
    self.lock.lock();
    defer self.lock.unlock();
    
    var reconnected_count: u32 = 0;
    
    var texture_iterator = self.textures.iterator();
    while (texture_iterator.next()) |entry| {
        try entry.value_ptr.attemptReconnection(gpa);
        
        if (entry.value_ptr.graphics_data) |graphics_data| {
            if (graphics_data.eldritch_state == .mortal) {
                reconnected_count += 1;
            }
        }
    }
    
    log.info("Eldritch rehabilitation complete: {d} textures restored to mortal understanding", .{reconnected_count});
    
    return reconnected_count;
}

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

        log.debug("Texture {d} is now ready!", .{texture_id.to()});
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

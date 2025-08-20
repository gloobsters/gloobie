const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const renderite = @import("renderite");

const graphics = @import("../graphics.zig");
const Materials = @import("Materials.zig");
const Mesh = @import("Mesh.zig");
const Texture = @import("Texture.zig");

const log = @import("logger").Scoped(.assets);

const Assets = @This();

pub const Id = @import("../id.zig").Id(i32, struct {});

pub const TextureHandle = packed struct(u64) {
    id: Id,
    type: Texture.Type,
};

const TextureReadyFenceHandlerContext = struct {
    gpa: std.mem.Allocator,
    assets: *Assets,
    textures: []const TextureHandle,
};

fn textureReadyHandler(context: TextureReadyFenceHandlerContext) !void {
    context.assets.lock.lock();
    defer context.assets.lock.unlock();

    for (context.textures) |texture_info| {
        // SAFETY: textures should never be de-init by this moment!
        const texture = context.assets.textures.getPtr(texture_info).?;

        // SAFETY: texture should have graphics data right now!
        texture.graphics_data.?.ready = true;

        log.debug(@src(), "{s} {d} is now ready!", .{ @tagName(texture_info.type), texture_info.id.to() });
    }
}

fn deinitTextureReadyHandler(context: TextureReadyFenceHandlerContext) void {
    context.gpa.free(context.textures);
}

pub const TextureReadyFenceHandler = graphics.FenceHandler(TextureReadyFenceHandlerContext, textureReadyHandler, deinitTextureReadyHandler, "texture_ready_handler");

lock: std.Thread.RwLock,
textures: std.AutoHashMapUnmanaged(TextureHandle, Texture),
meshes: std.AutoHashMapUnmanaged(Id, Mesh),
materials: Materials,

pub const empty: Assets = .{
    .lock = .{},
    .textures = .empty,
    .meshes = .empty,
    .materials = .empty,
};

pub fn deinit(self: *Assets, gpa: std.mem.Allocator, device: gpu.Device) void {
    self.lock.lock();
    defer self.lock.unlock();

    var tex_iter = self.textures.valueIterator();
    while (tex_iter.next()) |texture| {
        texture.deinit(gpa, device);
    }

    self.textures.deinit(gpa);

    var mesh_iter = self.meshes.valueIterator();
    while (mesh_iter.next()) |mesh| {
        mesh.deinit(gpa, device);
    }

    self.meshes.deinit(gpa);
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
    properties: renderite.shared.SetTexture2DProperties,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const result = try self.textures.getOrPut(gpa, .{
        .id = .from(properties.assetId),
        .type = .Texture2D,
    });

    const texture = result.value_ptr;
    if (result.found_existing) {
        try texture.setProperties2d(frame_context, properties);
        log.trace(@src(), "Updated properties of Texture 2D {d}", .{properties.assetId});
    } else {
        texture.* = try .create2d(frame_context, properties);
        log.debug(@src(), "Created Texture 2D with ID {d}", .{properties.assetId});
    }
}

pub fn setTexture2dFormat(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    format: renderite.shared.SetTexture2DFormat,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.textures.getPtr(.{
        .id = .from(format.assetId),
        .type = .Texture2D,
    }) orelse return error.MissingAsset;

    try texture.setFormat2d(gpa, frame_context, format);

    log.trace(@src(), "Updated Texture ({d}) format to {s} ({s}), size {d}x{d}", .{
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
    data: renderite.shared.SetTexture2DData,
    accessor: *renderite.buffer.SharedMemoryAccessor,
) !void {
    const texture = self.textures.getPtr(.{
        .id = .from(data.assetId),
        .type = .Texture2D,
    }) orelse return error.MissingAsset;

    try texture.setData2d(gpa, frame_context, data, accessor);
}

pub fn setTexture3dPropertiesOrCreate(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    properties: renderite.shared.SetTexture3DProperties,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const result = try self.textures.getOrPut(gpa, .{
        .id = .from(properties.assetId),
        .type = .Texture3D,
    });

    const texture = result.value_ptr;
    if (result.found_existing) {
        try texture.setProperties3d(frame_context, properties);
        log.trace(@src(), "Updated properties of Texture 2D {d}", .{properties.assetId});
    } else {
        texture.* = try .create3d(frame_context, properties);
        log.debug(@src(), "Created Texture 2D with ID {d}", .{properties.assetId});
    }
}

pub fn setTexture3dFormat(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    format: renderite.shared.SetTexture3DFormat,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.textures.getPtr(.{
        .id = .from(format.assetId),
        .type = .Texture3D,
    }) orelse return error.MissingAsset;

    try texture.setFormat3d(gpa, frame_context, format);

    log.trace(@src(), "Updated Texture ({d}) format to {s} ({s}), size {d}x{d}x{d}", .{
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
    data: renderite.shared.SetTexture3DData,
    accessor: *renderite.buffer.SharedMemoryAccessor,
) !void {
    const texture = self.textures.getPtr(.{
        .id = .from(data.assetId),
        .type = .Texture3D,
    }) orelse return error.MissingAsset;

    try texture.setData3d(gpa, frame_context, data, accessor);
}

pub fn setCubemapPropertiesOrCreate(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    properties: renderite.shared.SetCubemapProperties,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const result = try self.textures.getOrPut(gpa, .{
        .id = .from(properties.assetId),
        .type = .Cubemap,
    });

    const texture = result.value_ptr;
    if (result.found_existing) {
        try texture.setPropertiesCubemap(frame_context, properties);
        log.trace(@src(), "Updated properties of Cubemap {d}", .{properties.assetId});
    } else {
        texture.* = try .createCubemap(frame_context, properties);
        log.debug(@src(), "Created Cubemap with ID {d}", .{properties.assetId});
    }
}

pub fn setCubemapFormat(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    format: renderite.shared.SetCubemapFormat,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.textures.getPtr(.{
        .id = .from(format.assetId),
        .type = .Cubemap,
    }) orelse return error.MissingAsset;

    try texture.setFormatCubemap(gpa, frame_context, format);

    log.trace(@src(), "Updated Cubemap ({d}) format to {s} ({s}), size {d}", .{
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
    data: renderite.shared.SetCubemapData,
    accessor: *renderite.buffer.SharedMemoryAccessor,
) !void {
    const texture = self.textures.getPtr(.{
        .id = .from(data.assetId),
        .type = .Cubemap,
    }) orelse return error.MissingAsset;

    try texture.setDataCubemap(gpa, frame_context, data, accessor);
}

pub fn unloadTexture(self: *Assets, texture_handle: TextureHandle, gpa: std.mem.Allocator, device: gpu.Device) void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.textures.get(texture_handle) orelse {
        log.warn(@src(), "Tried to unload missing texture {d}", .{texture_handle.id});
        return;
    };

    log.debug(@src(), "Unloading {s} ({d}) of type {s}", .{ @tagName(texture_handle.type), texture_handle.id.to(), @tagName(texture.properties.type) });

    texture.deinit(gpa, device);

    const removed = self.textures.remove(texture_handle);
    std.debug.assert(removed);
}

pub fn uploadMeshData(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    mesh_upload_data: renderite.shared.MeshUploadData,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const result = try self.meshes.getOrPut(gpa, .from(mesh_upload_data.assetId));

    const mesh = result.value_ptr;
    if (result.found_existing) {
        try mesh.setData(gpa, frame_context, accessor, mesh_upload_data);
        log.trace(@src(), "Updated mesh {d}", .{mesh_upload_data.assetId});
    } else {
        mesh.* = try .init(gpa, frame_context, accessor, mesh_upload_data);
        log.debug(@src(), "Created mesh {d}", .{mesh_upload_data.assetId});
    }
}

pub fn unloadMesh(self: *Assets, asset_id: Id, gpa: std.mem.Allocator, device: gpu.Device) void {
    self.lock.lock();
    defer self.lock.unlock();

    const mesh = self.meshes.getPtr(asset_id) orelse {
        log.warn(@src(), "Tried to unload missing mesh {d}", .{asset_id});
        return;
    };

    mesh.deinit(gpa, device);

    const removed = self.meshes.remove(asset_id);
    std.debug.assert(removed);
}

pub fn handleMaterialUpdate(
    self: *Assets,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: renderite.shared.MaterialsUpdateBatch,
) !void {
    self.lock.lock();
    defer self.lock.unlock();

    try self.materials.handleUpdate(gpa, frame_context, accessor, update);
}

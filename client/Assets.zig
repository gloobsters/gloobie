const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");

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

lock: std.Thread.RwLock,
texture_2ds: std.AutoHashMapUnmanaged(AssetId, Texture),

pub const empty: Assets = .{
    .lock = .{},
    .texture_2ds = .empty,
};

pub fn deinit(self: *Assets, gpa: std.mem.Allocator, device: gpu.Device) void {
    var tex_iter = self.texture_2ds.valueIterator();
    while (tex_iter.next()) |texture| {
        texture.deinit(device);
    }

    self.texture_2ds.deinit(gpa);
}

pub fn setTexture2dPropertiesOrCreate(self: *Assets, gpa: std.mem.Allocator, properties: renderite.Shared.SetTexture2DProperties) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const result = try self.texture_2ds.getOrPut(gpa, .from(properties.assetId));

    const texture = result.value_ptr;
    if (result.found_existing) {
        texture.setProperties(properties);
        log.debug("Updated properties of Texture 2D {d}", .{properties.assetId});
    } else {
        texture.* = .create(properties);
        log.debug("Created Texture 2D with ID {d}", .{properties.assetId});
    }
}

pub fn setTexture2dFormat(self: *Assets, format: renderite.Shared.SetTexture2DFormat, device: gpu.Device) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.texture_2ds.getPtr(.from(format.assetId)) orelse return error.MissingAsset;

    try texture.setFormat(format, device);

    log.debug("Updated Texture ({d}) format to {s} ({s}), size {d}x{d}", .{
        format.assetId,
        @tagName(format.format),
        @tagName(format.profile),
        format.width,
        format.height,
    });
}

pub fn setTexture2dData(self: *Assets, data: renderite.Shared.SetTexture2DData, accessor: *renderite.SharedMemoryAccessor) !void {
    const view = try accessor.getOrCreateView(data.data);
    log.debug("Got texture data of size {d}", .{view.data.len});
    _ = self;
}

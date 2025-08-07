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

pub const TextureReadynessState = struct {
    texture: *Texture,
    ready: bool,
};

pub const ReadynessList = struct {
    fence: gpu.Fence,
    items: std.ArrayListUnmanaged(TextureReadynessState),
};

lock: std.Thread.RwLock,
texture_2ds: std.AutoHashMapUnmanaged(AssetId, Texture),
texture_2ds_readyness: std.ArrayListUnmanaged(ReadynessList),

pub const empty: Assets = .{
    .lock = .{},
    .texture_2ds = .empty,
    .texture_2ds_readyness = .empty,
};

pub fn deinit(self: *Assets, gpa: std.mem.Allocator, device: gpu.Device) void {
    self.lock.lock();
    defer self.lock.unlock();

    var tex_iter = self.texture_2ds.valueIterator();
    while (tex_iter.next()) |texture| {
        texture.deinit(gpa, device);
    }

    for (self.texture_2ds_readyness.items) |readyness_list| {
        device.releaseFence(readyness_list.fence);
    }
    self.texture_2ds_readyness.deinit(gpa);

    self.texture_2ds.deinit(gpa);
}

/// Called to check for pending fences and apply and needed state
pub fn mainThreadTick(self: *Assets, gpa: std.mem.Allocator, device: gpu.Device) void {
    self.lock.lock();
    defer self.lock.unlock();

    var i: usize = 0;
    // iterate over all the queued things, check if the fences are complete. if so, then release the fence and update the texture states
    while (i < self.texture_2ds_readyness.items.len) {
        const readyness_flags = &self.texture_2ds_readyness.items[i];
        if (!device.queryFence(readyness_flags.fence)) {
            // only increment when we actually are done with an item, since else we removed so dont increment
            i += 1;
            continue;
        }
        defer {
            device.releaseFence(readyness_flags.fence);
            readyness_flags.items.deinit(gpa);
            // remove this from the list, preserving order
            _ = self.texture_2ds_readyness.orderedRemove(i);
        }

        // the fence is complete, mark all textures as the ready state
        for (readyness_flags.items.items) |state| {
            state.texture.graphics_data.?.ready = state.ready;
        }
    }
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

pub fn setTexture2dFormat(self: *Assets, gpa: std.mem.Allocator, format: renderite.Shared.SetTexture2DFormat, device: gpu.Device) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const texture = self.texture_2ds.getPtr(.from(format.assetId)) orelse return error.MissingAsset;

    try texture.setFormat(gpa, device, format);

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
    const texture = self.texture_2ds.getPtr(.from(data.assetId)) orelse return error.MissingAsset;

    try texture.setData(gpa, frame_context, data, accessor);
}

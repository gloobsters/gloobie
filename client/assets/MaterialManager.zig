const std = @import("std");
const builtin = @import("builtin");

const math = @import("math");
const renderite = @import("renderite");
const SharedMemoryAccessor = renderite.buffer.SharedMemoryAccessor;
const shared = renderite.shared;

const graphics = @import("../graphics.zig");
const Assets = @import("Assets.zig");

const MaterialManager = @This();

const Material = struct {
    pub const RenderType = enum(i32) {
        fully_opaque = 0,
        transparent_cutout = 1,
        transparent = 2,
    };

    render_type: RenderType,
    shader_id: Assets.Id,
    render_queue_override: ?i32,
    enable_instancing: bool,

    fn handleMaterialUpdate(
        material: *Material,
        gpa: std.mem.Allocator,
        accessor: *SharedMemoryAccessor,
        reader: *MaterialUpdateReader,
        update: shared.MaterialPropertyUpdate,
    ) !void {
        switch (update.update_type) {
            .update_batch_end,
            .select_target,
            => return error.InvalidOperation,
            .set_shader => {
                material.shader_id = .from(update.property_id);
                material.render_queue_override = null;
            },
            .set_render_queue => {
                material.render_queue_override = update.property_id;
            },
            .set_instancing => {
                material.enable_instancing = update.property_id > 0;
            },
            .set_render_type => {
                material.render_type = @enumFromInt(update.property_id);
            },
            .set_float => {
                _ = try reader.float_buffer.next(gpa, accessor);
            },
            .set_float4 => {
                _ = try reader.vector_buffer.next(gpa, accessor);
            },
            .set_float4x4 => {
                _ = try reader.matrix_buffer.nextPtr(gpa, accessor);
            },
            .set_float_array => {
                _ = try reader.float_buffer.nextSlice(gpa, accessor, &reader.int_buffer);
            },
            .set_float4_array => {
                _ = try reader.vector_buffer.nextSlice(gpa, accessor, &reader.int_buffer);
            },
            .set_texture => {
                _ = try reader.int_buffer.next(gpa, accessor);
            },
        }
    }
};

const PropertyBlock = struct {
    fn handlePropertyBlockUpdate(
        property_block: *PropertyBlock,
        gpa: std.mem.Allocator,
        accessor: *SharedMemoryAccessor,
        reader: *MaterialUpdateReader,
        update: shared.MaterialPropertyUpdate,
    ) !void {
        _ = property_block; // autofix

        switch (update.update_type) {
            .select_target,
            .set_shader,
            .set_render_queue,
            .set_instancing,
            .set_render_type,
            .update_batch_end,
            => return error.InvalidOperation,
            .set_float => {
                _ = try reader.float_buffer.next(gpa, accessor);
            },
            .set_float4 => {
                _ = try reader.vector_buffer.next(gpa, accessor);
            },
            .set_float4x4 => {
                _ = try reader.matrix_buffer.nextPtr(gpa, accessor);
            },
            .set_float_array => {
                _ = try reader.float_buffer.nextSlice(gpa, accessor, &reader.int_buffer);
            },
            .set_float4_array => {
                _ = try reader.vector_buffer.nextSlice(gpa, accessor, &reader.int_buffer);
            },
            .set_texture => {
                _ = try reader.int_buffer.next(gpa, accessor);
            },
        }
    }
};

pub const empty: MaterialManager = .{
    .materials = .empty,
    .property_blocks = .empty,
};

materials: std.AutoHashMapUnmanaged(Assets.Id, Material),
property_blocks: std.AutoHashMapUnmanaged(Assets.Id, PropertyBlock),

pub fn deinit(self: *MaterialManager, gpa: std.mem.Allocator) void {
    self.materials.deinit(gpa);
    self.property_blocks.deinit(gpa);
}

fn SharedMemorySliceIterator(comptime UnderlyingType: type) type {
    return struct {
        const Self = @This();

        buffer_descriptors: []const renderite.buffer.SharedMemoryBufferDescriptor,
        active_buffer: ?SharedMemoryAccessor.Slice(UnderlyingType),

        next_buffer: usize,
        next_element_index: usize,

        pub fn init(buffer_descriptors: []const renderite.buffer.SharedMemoryBufferDescriptor) Self {
            return .{
                .buffer_descriptors = buffer_descriptors,
                .active_buffer = null,

                .next_buffer = 0,
                .next_element_index = 0,
            };
        }

        pub fn deinit(self: Self, accessor: *SharedMemoryAccessor) void {
            if (self.active_buffer) |active_buffer| {
                active_buffer.release(accessor);
            }
        }

        fn advanceBuffer(
            self: *Self,
            gpa: std.mem.Allocator,
            accessor: *SharedMemoryAccessor,
        ) !bool {
            // De-init the current buffer
            if (self.active_buffer) |active_buffer| {
                active_buffer.release(accessor);
                self.active_buffer = null;
            }

            self.active_buffer = try accessor.getOrCreate(UnderlyingType, gpa, self.buffer_descriptors[self.next_buffer]);
            self.next_buffer += 1;
            self.next_element_index = 0;

            std.debug.assert(self.active_buffer != null);

            return true;
        }

        pub fn nextPtr(
            self: *Self,
            gpa: std.mem.Allocator,
            accessor: *SharedMemoryAccessor,
        ) !?*align(1) UnderlyingType {
            if (self.active_buffer == null) {
                if (!try self.advanceBuffer(gpa, accessor)) {
                    // no more buffers
                    return null;
                }

                std.debug.assert(self.active_buffer != null);
            }

            const active_buffer = self.active_buffer.?;

            // If we've reached the end of this buffer
            if (self.next_element_index >= active_buffer.data.len) {
                // Try to advance
                if (!try self.advanceBuffer(gpa, accessor)) {
                    // If that fails, return null
                    return null;
                }

                return self.nextPtr(gpa, accessor);
            }

            // read the next element
            const element = &active_buffer.data[self.next_element_index];

            self.next_element_index += 1;

            return element;
        }

        pub fn next(
            self: *Self,
            gpa: std.mem.Allocator,
            accessor: *SharedMemoryAccessor,
        ) !?UnderlyingType {
            const value = try self.nextPtr(gpa, accessor) orelse return null;

            return value.*;
        }

        pub fn nextSlice(
            self: *Self,
            gpa: std.mem.Allocator,
            accessor: *SharedMemoryAccessor,
            length_reader: *SharedMemorySliceIterator(i32),
        ) !?[]align(1) UnderlyingType {
            const len: usize = @intCast(try length_reader.next(gpa, accessor) orelse return null);

            if (len == 0) {
                return &.{};
            }

            if (self.active_buffer == null or (self.next_element_index + len) >= self.active_buffer.?.data.len) {
                if (!try self.advanceBuffer(gpa, accessor)) {
                    // there's length to read, but no buffer, something's gone wrong!
                    return error.MissingBufferData;
                }
            }

            const slice = self.active_buffer.?.data[self.next_element_index .. self.next_element_index + len];
            self.next_element_index += len;
            return slice;
        }
    };
}

const MaterialUpdateReader = struct {
    update: shared.MaterialsUpdateBatch,
    index: usize,

    instance_changed_index: usize,
    instance_changed_buffer: renderite.bit_slice.BitSlice(u32),

    update_buffer: SharedMemorySliceIterator(shared.MaterialPropertyUpdate),
    int_buffer: SharedMemorySliceIterator(i32),
    float_buffer: SharedMemorySliceIterator(f32),
    vector_buffer: SharedMemorySliceIterator(math.Vector4f),
    matrix_buffer: SharedMemorySliceIterator(math.Matrix4x4f),

    pub fn deinit(self: MaterialUpdateReader, accessor: *SharedMemoryAccessor) void {
        self.update_buffer.deinit(accessor);
        self.int_buffer.deinit(accessor);
        self.float_buffer.deinit(accessor);
        self.vector_buffer.deinit(accessor);
        self.matrix_buffer.deinit(accessor);
    }

    pub fn hasNext(self: *MaterialUpdateReader) bool {
        if (self.update_buffer.active_buffer) |active_buffer| {
            if (self.update_buffer.next_element_index == active_buffer.data.len) {
                return self.update_buffer.next_buffer < self.update_buffer.buffer_descriptors.len;
            }

            return active_buffer.data[self.update_buffer.next_element_index].update_type != .update_batch_end;
        }
        return self.update_buffer.next_buffer < self.update_buffer.buffer_descriptors.len;
    }

    pub fn writeInstanceChanged(self: *MaterialUpdateReader, changed: bool) void {
        self.instance_changed_buffer.set(self.instance_changed_index, changed);
        self.instance_changed_index += 1;
    }
};

pub fn handleUpdate(
    self: *MaterialManager,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *SharedMemoryAccessor,
    update: shared.MaterialsUpdateBatch,
) !void {
    const instance_changed_buffer = try accessor.getOrCreate(u32, gpa, update.instance_changed_buffer);
    defer instance_changed_buffer.release(accessor);

    var reader: MaterialUpdateReader = .{
        .index = 0,
        .update = update,

        .instance_changed_index = 0,
        .instance_changed_buffer = .{ .slice = instance_changed_buffer.data },

        .matrix_buffer = .init(update.matrix_buffers),
        .float_buffer = .init(update.float_buffers),
        .int_buffer = .init(update.int_buffers),
        .update_buffer = .init(update.material_updates),
        .vector_buffer = .init(update.float4_buffers),
    };
    defer reader.deinit(accessor);

    var i: usize = 0;
    var handling_property_block_updates = false;
    var maybe_instance_changed: ?bool = false;

    var material_asset_id: ?Assets.Id = null;
    var material_property_block_asset_id: ?Assets.Id = null;

    while (reader.hasNext()) {
        // SAFETY: we check in the loop that one is available
        const material_property_update = try reader.update_buffer.next(gpa, accessor) orelse unreachable;

        const as_asset_id: Assets.Id = .from(material_property_update.property_id);

        if (material_property_update.update_type == .select_target) {
            if (i == update.material_update_count) {
                handling_property_block_updates = true;
            }

            i += 1;

            if (maybe_instance_changed) |instance_changed| {
                reader.writeInstanceChanged(instance_changed);
            }

            maybe_instance_changed = false;

            if (handling_property_block_updates) {
                if (!self.property_blocks.contains(as_asset_id)) {
                    try self.property_blocks.put(gpa, as_asset_id, .{});
                }

                maybe_instance_changed = true;
                material_property_block_asset_id = as_asset_id;
            } else {
                if (!self.materials.contains(as_asset_id)) {
                    try self.materials.put(gpa, as_asset_id, .{
                        .render_type = .fully_opaque,
                        .enable_instancing = false,
                        .render_queue_override = null,
                        .shader_id = .invalid,
                    });
                }

                material_asset_id = as_asset_id;
            }
        } else if (handling_property_block_updates) {
            std.debug.assert(material_property_block_asset_id != null);

            const property_block = self.property_blocks.getPtr(material_property_block_asset_id.?).?;

            try property_block.handlePropertyBlockUpdate(
                gpa,
                accessor,
                &reader,
                material_property_update,
            );
        } else {
            std.debug.assert(material_asset_id != null);

            const material = self.materials.getPtr(material_asset_id.?).?;

            try material.handleMaterialUpdate(
                gpa,
                accessor,
                &reader,
                material_property_update,
            );
        }
    }

    try frame_context.messaging_host.background.sendTimeout(.{ .materials_update_batch_result = .{
        .update_batch_id = update.update_batch_id,
    } }, std.time.ns_per_s * 10);
}

pub fn unloadMaterial(self: *MaterialManager, request: renderite.shared.UnloadMaterial) void {
    _ = self.materials.remove(.from(request.asset_id));
}

pub fn unloadMaterialPropertyBlock(self: *MaterialManager, request: renderite.shared.UnloadMaterialPropertyBlock) void {
    _ = self.property_blocks.remove(.from(request.asset_id));
}

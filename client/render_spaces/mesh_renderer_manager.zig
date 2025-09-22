const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");

const Assets = @import("../assets/Assets.zig");
const Mesh = @import("../assets/Mesh.zig");
const graphics = @import("../graphics.zig");
const lazy_array_list = @import("../lazy_array_list.zig");
const TransformManager = @import("TransformManager.zig");

const log = @import("logger").Scoped(.render_space);

const MaterialPropertyBlockPair = packed struct(u64) {
    material: Assets.Id,
    property_block: Assets.Id,
};

pub const SharedMeshRenderable = struct {
    transform: TransformManager.Transform.Id,
    mesh: Assets.Id,
    shadow_cast_mode: renderite.shared.ShadowCastMode,
    motion_vector_mode: renderite.shared.MotionVectorMode,
    sorting_order: i16,
    material_pairs: []MaterialPropertyBlockPair,

    pub fn init(transform: TransformManager.Transform.Id) SharedMeshRenderable {
        return .{
            .transform = transform,
            .mesh = .invalid,
            .shadow_cast_mode = .off,
            .motion_vector_mode = .no_motion,
            .sorting_order = 0,
            .material_pairs = &.{},
        };
    }

    pub fn deinit(self: SharedMeshRenderable, gpa: std.mem.Allocator) void {
        gpa.free(self.material_pairs);
    }
};

const MeshRenderable = struct {
    shared: SharedMeshRenderable,

    pub fn init(transform: TransformManager.Transform.Id) MeshRenderable {
        return .{
            .shared = .init(transform),
        };
    }

    pub fn deinit(self: MeshRenderable, gpa: std.mem.Allocator, device: gpu.Device) void {
        _ = device;
        self.shared.deinit(gpa);
    }
};

const SkinnedMeshRenderable = struct {
    shared: SharedMeshRenderable,

    update_when_offscreen: bool,
    bounds: renderite.shared.RenderBoundingBox,

    root_bone: TransformManager.Transform.Id,

    /// The CPU sided copy of the bone TransformManager
    bones: []TransformManager.Transform.Id,

    /// The CPU sided copy of the blend shape values
    blend_shape_values: lazy_array_list.LazyArrayList(f32),
    /// The GPU sided copy of the blend shape values, it is UB to access this when `capacity` == 0!
    blend_shape_values_buffer: gpu.Buffer,
    /// The size of the blend shape GPU buffer, in bytes
    blend_shape_values_buffer_capacity: u32,
    /// Whether the CPU sided blend shapes buffer has been updated
    blend_shape_values_updated: bool,

    pub fn init(transform: TransformManager.Transform.Id) SkinnedMeshRenderable {
        return .{
            .shared = .init(transform),

            .update_when_offscreen = false,
            .bounds = .{ .center = .zero, .extents = .zero },

            .root_bone = .invalid,

            .bones = &.{},

            .blend_shape_values = .empty,
            .blend_shape_values_updated = false,
            .blend_shape_values_buffer = undefined,
            .blend_shape_values_buffer_capacity = 0,
        };
    }

    fn uploadBlendshapeData(
        self: *SkinnedMeshRenderable,
        gpa: std.mem.Allocator,
        frame_context: *graphics.FrameContext,
        mesh: *Mesh,
    ) !void {
        const needed_buffer_size = mesh.mesh_layout.num_blendshapes * @sizeOf(f32);

        // Resize directly to the number of blendshapes
        try self.blend_shape_values.resizeTo(gpa, mesh.mesh_layout.num_blendshapes, 0.0);

        // Nothing to do
        if (mesh.mesh_layout.num_blendshapes == 0) {
            return;
        }

        if (self.blend_shape_values_buffer_capacity < needed_buffer_size) {
            if (self.blend_shape_values_buffer_capacity > 0)
                frame_context.device.releaseBuffer(self.blend_shape_values_buffer);

            self.blend_shape_values_buffer = try frame_context.device.createBuffer(.{
                .usage = .{ .graphics_storage_read = true },
                .size = needed_buffer_size,
            });
            self.blend_shape_values_buffer_capacity = needed_buffer_size;
        }
        errdefer {
            if (self.blend_shape_values_buffer_capacity > 0)
                frame_context.device.releaseBuffer(self.blend_shape_values_buffer);

            self.blend_shape_values_buffer_capacity = 0;
        }

        const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(.{
            .size = needed_buffer_size,
            .value = .upload,
        });
        defer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM");

        {
            const mapped_data = try frame_context.device.mapTransferBuffer(transfer_buffer_entry.value, true);
            defer frame_context.device.unmapTransferBuffer(transfer_buffer_entry.value);

            const dst: []align(1) f32 = @ptrCast(mapped_data[0..needed_buffer_size]);

            @memcpy(dst, self.blend_shape_values.contents[0..mesh.mesh_layout.num_blendshapes]);
        }

        const copy_pass = try frame_context.getSharedCopyPass();

        copy_pass.uploadToBuffer(.{
            .transfer_buffer = transfer_buffer_entry.value,
            .offset = 0,
        }, .{
            .buffer = self.blend_shape_values_buffer,
            .offset = 0,
            .size = needed_buffer_size,
        }, true);
    }

    pub fn tryPushDataAssetsLocked(
        self: *SkinnedMeshRenderable,
        gpa: std.mem.Allocator,
        frame_context: *graphics.FrameContext,
    ) !void {
        if (self.shared.mesh == .invalid) {
            return;
        }

        const mesh = frame_context.assets.meshes.getPtr(self.shared.mesh) orelse return;

        if (self.blend_shape_values_updated) {
            try self.uploadBlendshapeData(gpa, frame_context, mesh);
        }
    }

    pub fn deinit(
        self: SkinnedMeshRenderable,
        gpa: std.mem.Allocator,
        device: gpu.Device,
    ) void {
        self.shared.deinit(gpa);
        // Non-zero capacity means it's valid
        if (self.blend_shape_values_buffer_capacity > 0)
            device.releaseBuffer(self.blend_shape_values_buffer);
        gpa.free(self.blend_shape_values.contents);
        gpa.free(self.bones);
    }
};

fn meshRendererFinishUpdates(
    contents: anytype,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: anytype,
) !void {
    const mesh_renderer_states = try accessor.getOrCreate(renderite.shared.MeshRendererState, gpa, update.mesh_states);
    defer mesh_renderer_states.release(accessor);

    // nothing to do
    if (mesh_renderer_states.data.len == 0) {
        return;
    }

    const material_and_property_blocks = try accessor.getOrCreate(i32, gpa, update.mesh_materials_and_property_blocks);
    defer material_and_property_blocks.release(accessor);
    var current_id_index: usize = 0;

    for (mesh_renderer_states.data) |mesh_renderer_state| {
        if (mesh_renderer_state.renderable_index < 0) {
            break;
        }

        const mesh_renderer = &contents[@intCast(mesh_renderer_state.renderable_index)];

        mesh_renderer.shared.mesh = if (mesh_renderer_state.mesh_asset_id < 0) .invalid else .from(mesh_renderer_state.mesh_asset_id);
        mesh_renderer.shared.shadow_cast_mode = mesh_renderer_state.shadow_cast_mode;
        mesh_renderer.shared.motion_vector_mode = mesh_renderer_state.motion_vector_mode;
        // SAFETY: unity defines this to be within a 16-bit signed integer range, so let's cast directly down to that
        mesh_renderer.shared.sorting_order = std.math.lossyCast(i16, mesh_renderer_state.sorting_order);

        // fill out materials and property blocks
        if (mesh_renderer_state.material_count >= 0) {
            if (mesh_renderer.shared.material_pairs.len != mesh_renderer_state.material_count) {
                gpa.free(mesh_renderer.shared.material_pairs);

                mesh_renderer.shared.material_pairs = try gpa.alloc(MaterialPropertyBlockPair, @intCast(mesh_renderer_state.material_count));
                // NOTE: all members are going to be filled out in the folliwng
            }
            errdefer @compileError("Cannot error! material pairs may not be set to a value!");

            // Fill out materials
            for (mesh_renderer.shared.material_pairs) |*material_property_block_pair| {
                const material_id = material_and_property_blocks.data[current_id_index];
                current_id_index += 1;

                if (material_id < 0) {
                    material_property_block_pair.material = .invalid;
                    continue;
                }

                material_property_block_pair.material = .from(material_id);
            }

            // Fill out property blocks
            for (mesh_renderer.shared.material_pairs, 0..) |*material_property_block_pair, i| {
                // only fill out the property blocks we actually have
                if (i >= mesh_renderer_state.material_property_block_count) {
                    material_property_block_pair.property_block = .invalid;
                    continue;
                }

                const property_block_id = material_and_property_blocks.data[current_id_index];
                current_id_index += 1;

                if (property_block_id < 0) {
                    material_property_block_pair.property_block = .invalid;
                    continue;
                }

                material_property_block_pair.property_block = .from(property_block_id);
            }
        }
    }
}

fn skinnedMeshRendererFinishUpdates(
    contents: []SkinnedMeshRenderable,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: renderite.shared.SkinnedMeshRenderablesUpdate,
) !void {
    try meshRendererFinishUpdates(contents, gpa, accessor, update);

    const bounds_updates = try accessor.getOrCreate(renderite.shared.SkinnedMeshBoundsUpdate, gpa, update.bounds_updates);
    defer bounds_updates.release(accessor);

    for (bounds_updates.data) |bounds_update| {
        if (bounds_update.renderable_index < 0) {
            break;
        }

        const renderable = &contents[@intCast(bounds_update.renderable_index)];

        renderable.bounds = bounds_update.local_bounds;
        renderable.update_when_offscreen = false;
    }

    const realtime_bounds_updates = try accessor.getOrCreate(renderite.shared.SkinnedMeshRealtimeBoundsUpdate, gpa, update.realtime_bounds_updates);
    defer realtime_bounds_updates.release(accessor);

    for (realtime_bounds_updates.data) |*realtime_bounds_update| {
        if (realtime_bounds_update.renderable_index < 0) {
            break;
        }

        const renderable = &contents[@intCast(realtime_bounds_update.renderable_index)];

        // TODO: compute global bounds during the rendering process!
        realtime_bounds_update.computed_global_bounds = .{
            .center = .zero,
            .extents = .zero,
        };

        renderable.update_when_offscreen = true;
    }

    const bone_assignments = try accessor.getOrCreate(renderite.shared.BoneAssignment, gpa, update.bone_assignments);
    defer bone_assignments.release(accessor);
    const bone_transform_indexes = try accessor.getOrCreate(i32, gpa, update.bone_transform_indexes);
    defer bone_transform_indexes.release(accessor);
    var next_bone_index: usize = 0;

    for (bone_assignments.data) |bone_assignment| {
        if (bone_assignment.renderable_index < 0) {
            break;
        }

        const renderable = &contents[@intCast(bone_assignment.renderable_index)];

        {
            if (renderable.bones.len != bone_assignment.bone_count) {
                gpa.free(renderable.bones);

                renderable.bones = try gpa.alloc(TransformManager.Transform.Id, @intCast(bone_assignment.bone_count));
            }
            errdefer @compileError("Cannot error! bones may not be set to a value!");

            for (renderable.bones) |*bone| {
                const transform_idx = bone_transform_indexes.data[next_bone_index];
                next_bone_index += 1;

                bone.* = if (transform_idx < 0) .invalid else .from(transform_idx);
            }
        }

        renderable.root_bone = if (bone_assignment.root_bone_transform_id < 0) .invalid else .from(bone_assignment.root_bone_transform_id);
    }

    const blendshape_update_batches = try accessor.getOrCreate(renderite.shared.BlendshapeUpdateBatch, gpa, update.blendshape_update_batches);
    defer blendshape_update_batches.release(accessor);
    const blendshape_updates = try accessor.getOrCreate(renderite.shared.BlendshapeUpdate, gpa, update.blendshape_updates);
    defer blendshape_updates.release(accessor);
    var next_blendshape_update_index: usize = 0;

    for (blendshape_update_batches.data) |blendshape_update_batch| {
        if (blendshape_update_batch.renderable_index < 0) {
            break;
        }

        const renderable = &contents[@intCast(blendshape_update_batch.renderable_index)];

        for (0..@intCast(blendshape_update_batch.blendshape_update_count)) |_| {
            const blendshape_update = blendshape_updates.data[next_blendshape_update_index];
            next_blendshape_update_index += 1;

            const blendshape_index: u32 = @intCast(blendshape_update.blendshape_index);
            if ((blendshape_index + 1) >= renderable.blend_shape_values.contents.len) {
                try renderable.blend_shape_values.resizeTo(gpa, lazy_array_list.roundUpTo(blendshape_index + 1, 16), 0.0);
            }

            renderable.blend_shape_values.contents[blendshape_index] = blendshape_update.weight;
        }

        renderable.blend_shape_values_updated = true;
    }
}

pub const MeshRendererManager = @import("renderer_manager.zig").RendererManager(MeshRenderable, renderite.shared.MeshRenderablesUpdate, meshRendererFinishUpdates);
pub const SkinnedMeshRendererManager = @import("renderer_manager.zig").RendererManager(SkinnedMeshRenderable, renderite.shared.SkinnedMeshRenderablesUpdate, skinnedMeshRendererFinishUpdates);

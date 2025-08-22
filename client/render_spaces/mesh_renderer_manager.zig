const std = @import("std");

const renderite = @import("renderite");

const Assets = @import("../assets/Assets.zig");
const Transforms = @import("Transforms.zig");

const log = @import("logger").Scoped(.render_space);

const MaterialPropertyBlockPair = packed struct(u64) {
    material: Assets.Id,
    property_block: Assets.Id,
};

pub const SharedMeshRenderable = struct {
    transform: Transforms.Transform.Id,
    mesh: Assets.Id,
    shadow_cast_mode: renderite.shared.ShadowCastMode,
    motion_vector_mode: renderite.shared.MotionVectorMode,
    sorting_order: i16,
    material_pairs: []MaterialPropertyBlockPair,

    pub fn init(transform: Transforms.Transform.Id) SharedMeshRenderable {
        return .{
            .transform = transform,
            .mesh = .invalid,
            .shadow_cast_mode = .Off,
            .motion_vector_mode = .NoMotion,
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

    pub fn init(transform: Transforms.Transform.Id) MeshRenderable {
        return .{
            .shared = .init(transform),
        };
    }

    pub fn deinit(self: MeshRenderable, gpa: std.mem.Allocator) void {
        self.shared.deinit(gpa);
    }
};

const SkinnedMeshRenderable = struct {
    shared: SharedMeshRenderable,

    update_when_offscreen: bool,
    bounds: renderite.shared.RenderBoundingBox,

    root_bone: Transforms.Transform.Id,
    bones: []Transforms.Transform.Id,

    pub fn init(transform: Transforms.Transform.Id) SkinnedMeshRenderable {
        return .{
            .shared = .init(transform),

            .update_when_offscreen = false,
            .bounds = .{ .center = .zero, .extents = .zero },

            .root_bone = .invalid,
            .bones = &.{},
        };
    }

    pub fn deinit(self: SkinnedMeshRenderable, gpa: std.mem.Allocator) void {
        self.shared.deinit(gpa);
        gpa.free(self.bones);
    }
};

fn meshRendererFinishUpdates(
    contents: anytype,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: anytype,
) !void {
    const mesh_renderer_states = try accessor.getOrCreate(renderite.shared.MeshRendererState, gpa, update.meshStates);
    defer mesh_renderer_states.release(accessor);

    // nothing to do
    if (mesh_renderer_states.data.len == 0) {
        return;
    }

    const material_and_property_blocks = try accessor.getOrCreate(i32, gpa, update.meshMaterialsAndPropertyBlocks);
    defer material_and_property_blocks.release(accessor);
    var current_id_index: usize = 0;

    for (mesh_renderer_states.data) |mesh_renderer_state| {
        if (mesh_renderer_state.renderableIndex < 0) {
            break;
        }

        const mesh_renderer = &contents[@intCast(mesh_renderer_state.renderableIndex)];

        mesh_renderer.shared.mesh = if (mesh_renderer_state.meshAssetId < 0) .invalid else .from(mesh_renderer_state.meshAssetId);
        mesh_renderer.shared.shadow_cast_mode = mesh_renderer_state.shadowCastMode;
        mesh_renderer.shared.motion_vector_mode = mesh_renderer_state.motionVectorMode;
        // SAFETY: unity defines this to be within a 16-bit signed integer range, so let's cast directly down to that
        mesh_renderer.shared.sorting_order = @intCast(mesh_renderer_state.sortingOrder);

        // fill out materials and property blocks
        if (mesh_renderer_state.materialCount >= 0) {
            if (mesh_renderer.shared.material_pairs.len != mesh_renderer_state.materialCount) {
                gpa.free(mesh_renderer.shared.material_pairs);

                mesh_renderer.shared.material_pairs = try gpa.alloc(MaterialPropertyBlockPair, @intCast(mesh_renderer_state.materialCount));
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
                if (i >= mesh_renderer_state.materialPropertyBlockCount) {
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

    const bounds_updates = try accessor.getOrCreate(renderite.shared.SkinnedMeshBoundsUpdate, gpa, update.boundsUpdates);
    defer bounds_updates.release(accessor);

    for (bounds_updates.data) |bounds_update| {
        if (bounds_update.renderableIndex < 0) {
            break;
        }

        const renderable = &contents[@intCast(bounds_update.renderableIndex)];

        renderable.bounds = bounds_update.localBounds;
        renderable.update_when_offscreen = false;
    }

    const realtime_bounds_updates = try accessor.getOrCreate(renderite.shared.SkinnedMeshRealtimeBoundsUpdate, gpa, update.realtimeBoundsUpdates);
    defer realtime_bounds_updates.release(accessor);

    for (realtime_bounds_updates.data) |*realtime_bounds_update| {
        if (realtime_bounds_update.renderableIndex < 0) {
            break;
        }

        const renderable = &contents[@intCast(realtime_bounds_update.renderableIndex)];

        // TODO: compute global bounds during the rendering process!
        realtime_bounds_update.computedGlobalBounds = .{
            .center = .zero,
            .extents = .zero,
        };

        renderable.update_when_offscreen = true;
    }

    const bone_assignments = try accessor.getOrCreate(renderite.shared.BoneAssignment, gpa, update.boneAssignments);
    defer bone_assignments.release(accessor);
    const bone_transform_indexes = try accessor.getOrCreate(i32, gpa, update.boneTransformIndexes);
    defer bone_transform_indexes.release(accessor);
    var next_bone_index: usize = 0;

    for (bone_assignments.data) |bone_assignment| {
        if (bone_assignment.renderableIndex < 0) {
            break;
        }

        const renderable = &contents[@intCast(bone_assignment.renderableIndex)];

        if (renderable.bones.len != bone_assignment.boneCount) {
            gpa.free(renderable.bones);

            renderable.bones = try gpa.alloc(Transforms.Transform.Id, @intCast(bone_assignment.boneCount));
        }
        errdefer @compileError("Cannot error! bones may not be set to a value!");

        for (renderable.bones) |*bone| {
            const transform_idx = bone_transform_indexes.data[next_bone_index];
            next_bone_index += 1;

            bone.* = if (transform_idx < 0) .invalid else .from(transform_idx);
        }

        renderable.root_bone = if (bone_assignment.rootBoneTransformId < 0) .invalid else .from(bone_assignment.rootBoneTransformId);
    }

    const blendshape_update_batches = try accessor.getOrCreate(renderite.shared.BlendshapeUpdateBatch, gpa, update.blendshapeUpdateBatches);
    defer blendshape_update_batches.release(accessor);
    const blendshape_updates = try accessor.getOrCreate(renderite.shared.BlendshapeUpdate, gpa, update.blendshapeUpdates);
    defer blendshape_updates.release(accessor);
    var next_blendshape_update_index: usize = 0;

    for (blendshape_update_batches.data) |blendshape_update_batch| {
        if (blendshape_update_batch.renderableIndex < 0) {
            break;
        }

        const renderable = &contents[@intCast(blendshape_update_batch.renderableIndex)];
        _ = renderable;

        // TODO: handle blendshape updates
        for (0..@intCast(blendshape_update_batch.blendshapeUpdateCount)) |_| {
            const blendshape_update = blendshape_updates.data[next_blendshape_update_index];
            next_blendshape_update_index += 1;

            _ = blendshape_update;
        }
    }
}

pub const MeshRendererManager = @import("renderer_manager.zig").RendererManager(MeshRenderable, renderite.shared.MeshRenderablesUpdate, meshRendererFinishUpdates);
pub const SkinnedMeshRendererManager = @import("renderer_manager.zig").RendererManager(SkinnedMeshRenderable, renderite.shared.SkinnedMeshRenderablesUpdate, skinnedMeshRendererFinishUpdates);

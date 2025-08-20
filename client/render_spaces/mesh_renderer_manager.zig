const std = @import("std");

const renderite = @import("renderite");

const Assets = @import("../Assets.zig");
const Transforms = @import("Transforms.zig");

const log = @import("logger").Scoped(.render_space);

const MaterialPropertyBlockPair = packed struct(u64) {
    material: Assets.Id,
    property_block: Assets.Id,
};

const MeshRenderer = struct {
    transform: Transforms.Transform.Id,
    mesh: Assets.Id,
    shadow_cast_mode: renderite.shared.ShadowCastMode,
    motion_vector_mode: renderite.shared.MotionVectorMode,
    sorting_order: i16,
    material_pairs: []MaterialPropertyBlockPair,

    pub fn init(transform: Transforms.Transform.Id) MeshRenderer {
        return .{
            .transform = transform,
            .mesh = .invalid,
            .shadow_cast_mode = .Off,
            .motion_vector_mode = .NoMotion,
            .sorting_order = 0,
            .material_pairs = &.{},
        };
    }

    pub fn deinit(self: MeshRenderer, gpa: std.mem.Allocator) void {
        gpa.free(self.material_pairs);
    }
};

fn finishUpdates(
    contents: []MeshRenderer,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: renderite.shared.MeshRenderablesUpdate,
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

        mesh_renderer.mesh = if (mesh_renderer_state.meshAssetId < 0) .invalid else .from(mesh_renderer_state.meshAssetId);
        mesh_renderer.shadow_cast_mode = mesh_renderer_state.shadowCastMode;
        mesh_renderer.motion_vector_mode = mesh_renderer_state.motionVectorMode;
        // SAFETY: unity defines this to be within a 16-bit signed integer range, so let's cast directly down to that
        mesh_renderer.sorting_order = @intCast(mesh_renderer_state.sortingOrder);

        // fill out materials and property blocks
        if (mesh_renderer_state.materialCount >= 0) {
            if (mesh_renderer.material_pairs.len != mesh_renderer_state.materialCount) {
                gpa.free(mesh_renderer.material_pairs);

                mesh_renderer.material_pairs = try gpa.alloc(MaterialPropertyBlockPair, @intCast(mesh_renderer_state.materialCount));
                // NOTE: all members are going to be filled out in the folliwng
            }
            errdefer @compileError("Cannot error! material pairs may not be set to a value!");

            // Fill out materials
            for (mesh_renderer.material_pairs) |*material_property_block_pair| {
                const material_id = material_and_property_blocks.data[current_id_index];
                current_id_index += 1;

                if (material_id < 0) {
                    material_property_block_pair.material = .invalid;
                    continue;
                }

                material_property_block_pair.material = .from(material_id);
            }

            // Fill out property blocks
            for (mesh_renderer.material_pairs, 0..) |*material_property_block_pair, i| {
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

pub const MeshRendererManager = @import("renderer_manager.zig").RendererManager(MeshRenderer, renderite.shared.MeshRenderablesUpdate, finishUpdates);

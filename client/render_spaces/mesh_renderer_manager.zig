const std = @import("std");

const renderite = @import("renderite");

const Transforms = @import("Transforms.zig");

const log = @import("logger").Scoped(.render_space);

const MeshRenderer = struct {
    transform: Transforms.Transform.Id,

    pub fn init(transform: Transforms.Transform.Id) MeshRenderer {
        return .{
            .transform = transform,
        };
    }
};

fn finishUpdates(
    self: anytype,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: renderite.shared.MeshRenderablesUpdate,
) !void {
    _ = self;

    const mesh_renderer_states = try accessor.getOrCreate(renderite.shared.MeshRendererState, gpa, update.meshStates) orelse return;
    defer mesh_renderer_states.release(accessor);

    const maybe_material_and_property_blocks = try accessor.getOrCreate(i32, gpa, update.meshMaterialsAndPropertyBlocks);
    defer if (maybe_material_and_property_blocks) |material_and_property_blocks| material_and_property_blocks.release(accessor);

    for (mesh_renderer_states.data) |mesh_renderer_state| {
        _ = mesh_renderer_state;

        // TODO
    }
}

pub const MeshRendererManager = @import("renderer_manager.zig").RendererManager(MeshRenderer, renderite.shared.MeshRenderablesUpdate, finishUpdates);

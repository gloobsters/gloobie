const std = @import("std");

const renderite = @import("renderite");

const RenderSpace = @import("RenderSpace.zig");

const Transforms = @This();

pub const Transform = struct {
    pub const Id = @import("../id.zig").Id(i32, struct {});

    parent: Id,

    render_transform: renderite.shared.RenderTransform,
};

transforms: std.ArrayListUnmanaged(Transform),

pub fn init() Transforms {
    return .{
        .transforms = .empty,
    };
}

pub fn deinit(self: *Transforms, gpa: std.mem.Allocator) void {
    self.transforms.deinit(gpa);
}

fn fixupTransform(
    old_transform: Transform.Id,
    removed: Transform.Id,
    last_transform: usize,
) Transform.Id {
    if (old_transform == removed) {
        return .invalid;
    } else if (old_transform.to() == last_transform) {
        return removed;
    }

    return old_transform;
}

pub fn handleUpdate(
    self: *Transforms,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    render_space: *RenderSpace,
    update: renderite.shared.TransformsUpdate,
) !void {
    const removals = try accessor.getOrCreate(i32, gpa, update.removals);
    defer removals.release(accessor);

    for (removals.data) |removal_id| {
        if (removal_id < 0) {
            break;
        }

        const removal: Transform.Id = .from(removal_id);

        for (self.transforms.items) |*transform| {
            // orphan all children
            if (transform.parent == removal) {
                transform.parent = .invalid;
            }

            // The last item is about to be moved into the removed slot, so update any children of the last item to the new slot it will be in
            if (transform.parent.to() == self.transforms.items.len - 1) {
                transform.parent = removal;
            }
        }

        for (render_space.mesh_renderer_manager.contents.items) |*mesh_renderer| {
            mesh_renderer.shared.transform = fixupTransform(mesh_renderer.shared.transform, removal, self.transforms.items.len - 1);
        }

        for (render_space.skinned_mesh_renderer_manager.contents.items) |*skinned_mesh_renderer| {
            skinned_mesh_renderer.shared.transform = fixupTransform(skinned_mesh_renderer.shared.transform, removal, self.transforms.items.len - 1);
            skinned_mesh_renderer.root_bone = fixupTransform(skinned_mesh_renderer.root_bone, removal, self.transforms.items.len - 1);
            for (skinned_mesh_renderer.bones) |*bone| {
                bone.* = fixupTransform(bone.*, removal, self.transforms.items.len - 1);
            }
        }

        _ = self.transforms.swapRemove(@intCast(removal_id));
    }

    // engine says how many transforms there will be in the end
    try self.transforms.ensureTotalCapacity(gpa, @intCast(update.targetTransformCount));

    // fill out the new ones
    if (self.transforms.items.len < update.targetTransformCount) {
        const new = self.transforms.addManyAsSliceAssumeCapacity(@as(usize, @intCast(update.targetTransformCount)) - self.transforms.items.len);

        for (new) |*new_transform| {
            new_transform.* = .{
                .parent = .invalid,
                .render_transform = .{
                    .position = .zero,
                    .rotation = .identity,
                    .scale = .one,
                },
            };
        }
    }

    const parent_updates = try accessor.getOrCreate(renderite.shared.TransformParentUpdate, gpa, update.parentUpdates);
    defer parent_updates.release(accessor);

    for (parent_updates.data) |parent_update| {
        if (parent_update.transformId < 0) {
            break;
        }

        const transform = &self.transforms.items[@intCast(parent_update.transformId)];

        transform.parent = .from(parent_update.newParentId);
    }

    const pose_updates = try accessor.getOrCreate(renderite.shared.TransformPoseUpdate, gpa, update.poseUpdates);
    defer pose_updates.release(accessor);

    for (pose_updates.data) |pose_update| {
        if (pose_update.transformId < 0) {
            break;
        }

        const transform = &self.transforms.items[@intCast(pose_update.transformId)];

        transform.render_transform = pose_update.pose;
    }
}

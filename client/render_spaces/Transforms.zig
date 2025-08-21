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

pub fn handleUpdate(
    self: *Transforms,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    render_space: *RenderSpace,
    update: renderite.shared.TransformsUpdate,
) !void {
    const removals = try accessor.getOrCreate(i32, gpa, update.removals);
    defer removals.release(accessor);

    for (removals.data) |removal| {
        if (removal < 0) {
            break;
        }

        for (self.transforms.items) |*transform| {
            // orphan all children
            if (transform.parent.to() == removal) {
                transform.parent = .invalid;
            }

            // The last item is about to be moved into the removed slot, so update any children of the last item to the new slot it will be in
            if (transform.parent.to() == self.transforms.items.len - 1) {
                transform.parent = .from(removal);
            }
        }

        for (render_space.mesh_renderer_manager.contents.items) |*mesh_renderer| {
            if (mesh_renderer.transform.to() == removal) {
                // Mark the mesh renderer as having an invalid transform
                mesh_renderer.transform = .invalid;
            } else if (mesh_renderer.transform.to() == self.transforms.items.len - 1) {
                // Update all mesh renderers to the new ID, since the last slot is moving
                mesh_renderer.transform = .from(removal);
            }
        }

        _ = self.transforms.swapRemove(@intCast(removal));
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

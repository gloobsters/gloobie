const std = @import("std");

const renderite = @import("renderite");

const Transforms = @This();

pub const Transform = struct {
    pub const Id = @import("../id.zig").Id(i32, struct {});

    parent: Id,

    render_transform: renderite.Shared.RenderTransform,
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
    accessor: *renderite.SharedMemoryAccessor,
    update: renderite.Shared.TransformsUpdate,
) !void {
    if (try accessor.getOrCreate(i32, gpa, update.removals)) |removals| {
        defer removals.release(accessor);

        for (removals.data) |removal| {
            if (removal < 0) {
                break;
            }

            // orphan all children
            for (self.transforms.items) |*transform| {
                if (transform.parent.to() == removal) {
                    transform.parent = .invalid;
                }
            }

            _ = self.transforms.swapRemove(@intCast(removal));
        }
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

    if (try accessor.getOrCreate(renderite.Shared.TransformParentUpdate, gpa, update.parentUpdates)) |parent_updates| {
        defer parent_updates.release(accessor);

        for (parent_updates.data) |parent_update| {
            if (parent_update.transformId < 0) {
                break;
            }

            const transform = &self.transforms.items[@intCast(parent_update.transformId)];

            transform.parent = .from(parent_update.newParentId);
        }
    }

    if (try accessor.getOrCreate(renderite.Shared.TransformPoseUpdate, gpa, update.poseUpdates)) |pose_updates| {
        defer pose_updates.release(accessor);

        for (pose_updates.data) |pose_update| {
            if (pose_update.transformId < 0) {
                break;
            }

            const transform = &self.transforms.items[@intCast(pose_update.transformId)];

            transform.render_transform = pose_update.pose;
        }
    }
}

const std = @import("std");

const math = @import("math");
const renderite = @import("renderite");

const RenderSpace = @import("RenderSpace.zig");

const Transforms = @This();

pub const Transform = struct {
    pub const Id = @import("../id.zig").Id(i32, struct {});

    parent: Id,

    render_transform: renderite.shared.RenderTransform,
};

const ComputedTransform = struct {
    checked: bool,
    computed: bool,
    matrix: math.Matrix4x4f,
};

transforms: std.ArrayListUnmanaged(Transform),
computed_transforms: std.MultiArrayList(ComputedTransform),

pub fn init() Transforms {
    return .{
        .transforms = .empty,
        .computed_transforms = .empty,
    };
}

pub fn deinit(self: *Transforms, gpa: std.mem.Allocator) void {
    self.transforms.deinit(gpa);
    self.computed_transforms.deinit(gpa);
}

fn fixupTransformid(
    old_transform_id: Transform.Id,
    removed_id: Transform.Id,
    last_transform_id: usize,
) Transform.Id {
    if (old_transform_id == removed_id) {
        return .invalid;
    } else if (old_transform_id.to() == last_transform_id) {
        return removed_id;
    }

    return old_transform_id;
}

fn handleRemovals(
    self: *Transforms,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    render_space: *RenderSpace,
    update: renderite.shared.TransformsUpdate,
) !void {
    const removals = try accessor.getOrCreate(i32, gpa, update.removals);
    defer removals.release(accessor);

    // NOTE: This is technically unsafe since we're modifying the array, but since we're only doing swap remove, it's technically fine
    var computed_transforms_computed = self.computed_transforms.items(.computed);

    for (removals.data) |removal_id| {
        if (removal_id < 0) {
            break;
        }

        const removal: Transform.Id = .from(removal_id);

        for (self.transforms.items, 0..) |*transform, transform_index| {
            // orphan all children
            if (transform.parent == removal) {
                // Mark it as non-computed, as it's parent is no longer valid
                // NOTE: generally we would call `.items` once, but we can't here, beacuse we
                computed_transforms_computed[transform_index] = false;
                transform.parent = .invalid;
            }

            // The last item is about to be moved into the removed slot, so update any children of the last item to the new slot it will be in
            if (transform.parent.to() == self.transforms.items.len - 1) {
                transform.parent = removal;
            }
        }

        for (render_space.mesh_renderer_manager.contents.items) |*mesh_renderer| {
            mesh_renderer.shared.transform = fixupTransformid(mesh_renderer.shared.transform, removal, self.transforms.items.len - 1);
        }

        for (render_space.skinned_mesh_renderer_manager.contents.items) |*skinned_mesh_renderer| {
            skinned_mesh_renderer.shared.transform = fixupTransformid(skinned_mesh_renderer.shared.transform, removal, self.transforms.items.len - 1);
            skinned_mesh_renderer.root_bone = fixupTransformid(skinned_mesh_renderer.root_bone, removal, self.transforms.items.len - 1);
            for (skinned_mesh_renderer.bones) |*bone| {
                bone.* = fixupTransformid(bone.*, removal, self.transforms.items.len - 1);
            }
        }

        _ = self.transforms.swapRemove(@intCast(removal_id));
        _ = self.computed_transforms.swapRemove(@intCast(removal_id));

        // NOTE: this is technically unnecessary, but it's for safety!
        computed_transforms_computed.len -= 1;
    }
}

fn handleAdditions(
    self: *Transforms,
    gpa: std.mem.Allocator,
    update: renderite.shared.TransformsUpdate,
) !void {
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

        const old_len = self.computed_transforms.len;
        try self.computed_transforms.resize(gpa, @intCast(update.targetTransformCount));
        // Mark them all as non-computed
        @memset(self.computed_transforms.items(.computed)[old_len..self.computed_transforms.len], false);
    }
}

fn handleParentUpdates(
    self: *Transforms,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: renderite.shared.TransformsUpdate,
) !void {
    const parent_updates = try accessor.getOrCreate(renderite.shared.TransformParentUpdate, gpa, update.parentUpdates);
    defer parent_updates.release(accessor);

    const computed_transforms_computed = self.computed_transforms.items(.computed);

    for (parent_updates.data) |parent_update| {
        if (parent_update.transformId < 0) {
            break;
        }

        const transform_index: usize = @intCast(parent_update.transformId);

        const transform = &self.transforms.items[transform_index];

        computed_transforms_computed[transform_index] = false;
        transform.parent = .from(parent_update.newParentId);
    }
}

fn handlePoseUpdates(
    self: *Transforms,
    gpa: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: renderite.shared.TransformsUpdate,
) !void {
    const pose_updates = try accessor.getOrCreate(renderite.shared.TransformPoseUpdate, gpa, update.poseUpdates);
    defer pose_updates.release(accessor);

    const computed_transforms_computed = self.computed_transforms.items(.computed);

    for (pose_updates.data) |pose_update| {
        if (pose_update.transformId < 0) {
            break;
        }

        const transform_index: usize = @intCast(pose_update.transformId);

        const transform = &self.transforms.items[transform_index];

        computed_transforms_computed[transform_index] = false;
        transform.render_transform = pose_update.pose;
    }
}

fn computeTransforms(
    self: *Transforms,
    arena: std.mem.Allocator,
) !void {
    const transforms = self.transforms.items;

    const slice = self.computed_transforms.slice();
    const checked_slice = slice.items(.checked);
    const computed_slice = slice.items(.computed);
    const matrix_slice = slice.items(.matrix);

    // mark them all as not checked
    @memset(checked_slice, false);

    var stack: std.ArrayListUnmanaged(Transform.Id) = try .initCapacity(arena, 64);
    defer stack.deinit(arena);

    var transform_index: usize = self.computed_transforms.len -| 1;
    while (transform_index < self.computed_transforms.len) : (transform_index -%= 1) {
        defer std.debug.assert(stack.items.len == 0);

        if (checked_slice[transform_index]) {
            // If something's already been checked, it's definitely been computed
            std.debug.assert(computed_slice[transform_index]);
            continue;
        }

        var maybe_uppermost_matrix: ?math.Matrix4x4f = null;

        // TODO: figure out why incremental updates are not working correctly when checking the whole stack for computed
        var all_computed = false;
        var id: Transform.Id = .from(@intCast(transform_index));
        while (id != .invalid) {
            const index: usize = @intCast(id.to());

            const computed = computed_slice[index];
            if (!computed) {
                all_computed = false;
            }

            // If it has already been checked and is computed, then we've found the "uppermost" and this is the top of our stack
            if (computed and checked_slice[index]) {
                maybe_uppermost_matrix = matrix_slice[index];
                break;
            }

            try stack.append(arena, id);

            id = transforms[index].parent;
        }

        if (all_computed) {
            // If they were all computed, then we can mark them all as checked
            while (stack.pop()) |value| {
                checked_slice[@intCast(value.to())] = true;
            }
        } else {
            // If one was not computed, then we need to recompute all the stack
            var parent_matrix =
                // If we have a pre-calculated uppermost matrix, use it
                if (maybe_uppermost_matrix) |uppermost_matrix|
                    uppermost_matrix
                    // Else, we need to calculate the uppermost matrix and mark it as computed and checked
                else get_topmost_matrix: {
                    const top = stack.pop().?;
                    const uppermost_matrix: math.Matrix4x4f = .createRenderTransform(transforms[@intCast(top.to())].render_transform);
                    const index: usize = @intCast(top.to());

                    checked_slice[index] = true;
                    computed_slice[index] = true;
                    matrix_slice[index] = uppermost_matrix;

                    break :get_topmost_matrix uppermost_matrix;
                };
            while (stack.pop()) |child_id| {
                const child_index: usize = @intCast(child_id.to());

                parent_matrix = parent_matrix.mult(&.createRenderTransform(transforms[child_index].render_transform));

                checked_slice[child_index] = true;
                computed_slice[child_index] = true;
                matrix_slice[child_index] = parent_matrix;
            }
        }
    }
}

pub fn handleUpdate(
    self: *Transforms,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    render_space: *RenderSpace,
    update: renderite.shared.TransformsUpdate,
) !void {
    try self.handleRemovals(gpa, accessor, render_space, update);

    try self.handleAdditions(gpa, update);

    try self.handleParentUpdates(gpa, accessor, update);

    try self.handlePoseUpdates(gpa, accessor, update);

    try self.computeTransforms(arena);
}

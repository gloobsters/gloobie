const std = @import("std");

const math = @import("math");
const options = @import("options");
const renderite = @import("renderite");
const tracy = @import("tracy");

const RenderSpace = @import("RenderSpace.zig");

const Transforms = @This();

pub const Transform = struct {
    pub const Id = @import("../id.zig").Id(i32, struct {});

    parent: Id,
    render_transform: renderite.shared.RenderTransform,

    checked: bool,
    computed: bool,
    matrix: math.Matrix4x4f,
};

transforms: std.MultiArrayList(Transform),

pub fn init() Transforms {
    return .{
        .transforms = .empty,
    };
}

pub fn deinit(self: *Transforms, gpa: std.mem.Allocator) void {
    self.transforms.deinit(gpa);
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
    render_space: *RenderSpace,
    removals: []align(1) const i32,
) !void {
    const trace = tracy.traceNamed(@src(), "Handle Removals");
    defer trace.end();

    // NOTE: This is technically unsafe since we're modifying the array, but since we're only doing swap remove, it's technically fine
    var transforms_computed = self.transforms.items(.computed);
    var transforms_parents = self.transforms.items(.parent);

    for (removals) |removal_id| {
        if (removal_id < 0) {
            break;
        }

        const removal: Transform.Id = .from(removal_id);

        for (transforms_parents, 0..) |*parent, transform_index| {
            // orphan all children
            if (parent.* == removal) {
                // Mark it as non-computed, as it's parent is no longer valid
                // NOTE: generally we would call `.items` once, but we can't here, beacuse we
                transforms_computed[transform_index] = false;
                parent.* = .invalid;
            }

            // The last item is about to be moved into the removed slot, so update any children of the last item to the new slot it will be in
            if (parent.* == Transform.Id.from(@intCast(self.transforms.len - 1))) {
                parent.* = removal;
            }
        }

        for (render_space.mesh_renderer_manager.contents.items) |*mesh_renderer| {
            mesh_renderer.shared.transform = fixupTransformid(mesh_renderer.shared.transform, removal, self.transforms.len - 1);
        }

        for (render_space.skinned_mesh_renderer_manager.contents.items) |*skinned_mesh_renderer| {
            skinned_mesh_renderer.shared.transform = fixupTransformid(skinned_mesh_renderer.shared.transform, removal, self.transforms.len - 1);
            skinned_mesh_renderer.root_bone = fixupTransformid(skinned_mesh_renderer.root_bone, removal, self.transforms.len - 1);
            for (skinned_mesh_renderer.bones) |*bone| {
                bone.* = fixupTransformid(bone.*, removal, self.transforms.len - 1);
            }
        }

        _ = self.transforms.swapRemove(@intCast(removal_id));

        // NOTE: this is technically unnecessary, but it's for safety!
        transforms_computed.len -= 1;
        transforms_parents.len -= 1;
    }
}

fn handleAdditions(
    self: *Transforms,
    gpa: std.mem.Allocator,
    target_count: usize,
) !void {
    const trace = tracy.traceNamed(@src(), "Handle Additions");
    defer trace.end();

    if (self.transforms.len > target_count) {
        return;
    }

    const old_len = self.transforms.len;

    // engine says how many transforms there will be in the end
    try self.transforms.resize(gpa, target_count);

    const slice = self.transforms.slice().subslice(old_len, self.transforms.len - old_len);
    @memset(slice.items(.parent), .invalid);
    @memset(slice.items(.render_transform), .{ .position = .zero, .rotation = .identity, .scale = .one });
    @memset(slice.items(.computed), false);
}

fn handleParentUpdates(
    self: *Transforms,
    parent_updates: []align(1) const renderite.shared.TransformParentUpdate,
) !void {
    const trace = tracy.traceNamed(@src(), "Handle Parent Updates");
    defer trace.end();

    const transforms_computed = self.transforms.items(.computed);
    const transforms_parents = self.transforms.items(.parent);

    for (parent_updates) |parent_update| {
        if (parent_update.transformId < 0) {
            break;
        }

        const transform_index: usize = @intCast(parent_update.transformId);

        transforms_computed[transform_index] = false;
        transforms_parents[transform_index] = .from(parent_update.newParentId);
    }
}

fn handlePoseUpdates(
    self: *Transforms,
    pose_updates: []align(1) const renderite.shared.TransformPoseUpdate,
) !void {
    const trace = tracy.traceNamed(@src(), "Handle Pose Updates");
    defer trace.end();

    const transforms_computed = self.transforms.items(.computed);
    const transforms_render_transforms = self.transforms.items(.render_transform);

    for (pose_updates) |pose_update| {
        if (pose_update.transformId < 0) {
            break;
        }

        const transform_index: usize = @intCast(pose_update.transformId);

        transforms_computed[transform_index] = false;
        transforms_render_transforms[transform_index] = pose_update.pose;
    }
}

/// Marks all children of uncomputed transforms as themselves uncomputed
fn markChildrenUncomputed(self: *Transforms) void {
    const trace = tracy.traceNamed(@src(), "Mark Children Uncomputed");
    defer trace.end();

    const slice = self.transforms.slice();
    const checked_slice = slice.items(.checked);
    const computed_slice = slice.items(.computed);
    const parent_slice = slice.items(.parent);

    // mark them all as not checked
    @memset(checked_slice, false);

    var transform_index: usize = self.transforms.len -| 1;
    while (transform_index < self.transforms.len) : (transform_index -%= 1) {
        const checked = &checked_slice[transform_index];

        if (checked.*) {
            continue;
        }

        const transform_id: Transform.Id = .from(@intCast(transform_index));

        var maybe_last_non_computed: ?Transform.Id = null;
        {
            // Go through the hierarchy of this this trnasform, and find the *uppermost* non-computed transform
            var id = transform_id;
            while (id != .invalid) {
                const index: usize = @intCast(id.to());
                if (!computed_slice[index]) {
                    maybe_last_non_computed = id;
                }

                // If this parent has already been checked, then all of it's parents have aswell,
                // so either the parent is uncomputed, meaning we go *up to* that first [checked, uncomputed] transform,
                // marking this chain of children as uncomputed, or we've hit a [checked, computed],
                // meaning all the parents of that transform *are* computed, and we can safely stop checking parents.
                if (checked_slice[index]) {
                    break;
                }

                id = parent_slice[index];
            }
        }

        if (maybe_last_non_computed) |last_non_computed| {
            // Go through the hierarchy of this transform *up until* the uppermost non-computed transform,
            // and mark all children of that transform as non-computed
            var id = transform_id;
            while (id != last_non_computed) {
                const index: usize = @intCast(id.to());

                computed_slice[index] = false;
                checked_slice[index] = true;
                id = parent_slice[index];
            }
        } else {
            // If we found no uncomputed transform in the whole hierarchy, then we can safely mark this chain as checked
            var id = transform_id;
            while (id != .invalid) {
                const index: usize = @intCast(id.to());

                checked_slice[index] = true;
                id = parent_slice[index];
            }
        }

        checked.* = true;
    }
}

fn compute(
    self: *Transforms,
    arena: std.mem.Allocator,
) !void {
    const trace = tracy.traceNamed(@src(), "Compute Matrices");
    defer trace.end();

    var num_computed: usize = 0;
    defer if (options.build_options.tracy.enable) {
        var buf: [128]u8 = undefined;
        tracy.messageCopy(std.fmt.bufPrint(&buf, "Calculated matrices for {d}/{d} transforms", .{ num_computed, self.transforms.len }) catch unreachable);
    };

    const slice = self.transforms.slice();
    const computed_slice = slice.items(.computed);
    const matrix_slice = slice.items(.matrix);
    const parent_slice = slice.items(.parent);
    const render_transform_slice = slice.items(.render_transform);

    var stack: std.ArrayListUnmanaged(Transform.Id) = try .initCapacity(arena, 64);
    defer stack.deinit(arena);

    var transform_index: usize = self.transforms.len -| 1;
    while (transform_index < self.transforms.len) : (transform_index -%= 1) {
        defer std.debug.assert(stack.items.len == 0);

        // No work to do!
        if (computed_slice[transform_index]) {
            continue;
        }

        var maybe_uppermost_matrix: ?math.Matrix4x4f = null;

        // TODO: figure out why incremental updates are not working correctly when checking the whole stack for computed
        var id: Transform.Id = .from(@intCast(transform_index));
        while (id != .invalid) {
            const index: usize = @intCast(id.to());

            const computed = computed_slice[index];

            // If it has already been checked and is computed, then we've found the "uppermost" and this is the top of our stack
            if (computed) {
                maybe_uppermost_matrix = matrix_slice[index];
                break;
            }

            try stack.append(arena, id);

            id = parent_slice[index];
        }

        var parent_matrix =
            // If we have a pre-calculated uppermost matrix, use it
            if (maybe_uppermost_matrix) |uppermost_matrix|
                uppermost_matrix
                // Else, we need to calculate the uppermost matrix and mark it as computed
            else get_topmost_matrix: {
                const top = stack.pop().?;
                const uppermost_matrix: math.Matrix4x4f = .createRenderTransform(render_transform_slice[@intCast(top.to())]);
                const index: usize = @intCast(top.to());

                computed_slice[index] = true;
                matrix_slice[index] = uppermost_matrix;
                num_computed += 1;

                break :get_topmost_matrix uppermost_matrix;
            };
        while (stack.pop()) |child_id| {
            const child_index: usize = @intCast(child_id.to());

            parent_matrix = parent_matrix.mult(&.createRenderTransform(render_transform_slice[child_index]));

            computed_slice[child_index] = true;
            matrix_slice[child_index] = parent_matrix;
            num_computed += 1;
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
    const trace = tracy.traceNamed(@src(), "Handle Transforms Update");
    defer trace.end();

    const removals = try accessor.getOrCreate(i32, gpa, update.removals);
    defer removals.release(accessor);
    try self.handleRemovals(render_space, removals.data);

    try self.handleAdditions(gpa, @intCast(update.targetTransformCount));

    const parent_updates = try accessor.getOrCreate(renderite.shared.TransformParentUpdate, gpa, update.parentUpdates);
    defer parent_updates.release(accessor);
    try self.handleParentUpdates(parent_updates.data);

    const pose_updates = try accessor.getOrCreate(renderite.shared.TransformPoseUpdate, gpa, update.poseUpdates);
    defer pose_updates.release(accessor);
    try self.handlePoseUpdates(pose_updates.data);

    self.markChildrenUncomputed();

    try self.compute(arena);
}

fn dumpTransforms(transforms: []const Transform) void {
    std.debug.print("\n", .{});
    for (transforms, 0..) |transform, i| {
        std.debug.print("[{d}]\tparent: {d}\ttranslation: {d}x{d}x{d}\n", .{
            i,
            transform.parent.to(),
            transform.render_transform.position.x,
            transform.render_transform.position.y,
            transform.render_transform.position.z,
        });
    }
}

fn dumpComputed(self: Transforms) void {
    std.debug.print("\n", .{});
    const slice = self.transforms.slice();
    const checked_slice = slice.items(.checked);
    const computed_slice = slice.items(.computed);
    const matrices = slice.items(.matrix);

    for (checked_slice, computed_slice, matrices, 0..) |checked, computed, matrix, i| {
        const translation = matrix.getTranslation();
        std.debug.print("[{d}]\t{any}\t{any}\t{d}x{d}x{d}\n", .{ i, checked, computed, translation.x, translation.y, translation.z });
    }
}

test compute {
    const gpa = std.testing.allocator;

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const transform_count = 5;

    var transform_parents: [transform_count - 1]renderite.shared.TransformParentUpdate = undefined;
    for (&transform_parents, 1..) |*parent, i| {
        parent.transformId = @intCast(i);
        parent.newParentId = @intCast(i - 1);
    }

    var transform_poses: [transform_count]renderite.shared.TransformPoseUpdate = undefined;
    for (&transform_poses, 0..) |*pose, i| {
        pose.* = .{
            .transformId = @intCast(i),
            .pose = .{
                .position = .natural_forward,
                .rotation = .identity,
                .scale = .one,
            },
        };
    }

    var transforms: Transforms = .init();
    defer transforms.deinit(gpa);

    try transforms.handleAdditions(gpa, transform_count);
    try transforms.handleParentUpdates(&transform_parents);
    try transforms.handlePoseUpdates(&transform_poses);
    transforms.markChildrenUncomputed();
    try transforms.compute(arena);

    const computed_matrices = transforms.transforms.items(.matrix);

    for (computed_matrices, 0..) |matrix, i| {
        const expected_position: math.Vector3f = .mul(.natural_forward, .splat(@floatFromInt(i + 1)));

        const actual_position = matrix.getTranslation();

        try std.testing.expectApproxEqRel(expected_position.z, actual_position.z, 0.001);
    }

    // Update the root to be at z=-2, moving every other object -1 on Z aswell
    try transforms.handlePoseUpdates(&.{.{
        .transformId = 0,
        .pose = .{
            .position = .mul(.natural_forward, .splat(2)),
            .rotation = .identity,
            .scale = .one,
        },
    }});
    transforms.markChildrenUncomputed();
    try transforms.compute(arena);

    for (computed_matrices, 0..) |matrix, i| {
        const expected_position: math.Vector3f = .add(.mul(.natural_forward, .splat(@floatFromInt(i + 1))), .natural_forward);

        const actual_position = matrix.getTranslation();

        try std.testing.expectApproxEqRel(expected_position.z, actual_position.z, 0.001);
    }

    // Update the root back to Z=-1
    try transforms.handlePoseUpdates(&.{.{
        .transformId = 0,
        .pose = .{
            .position = .natural_forward,
            .rotation = .identity,
            .scale = .one,
        },
    }});
    // Reparent the fourth item to the root, so the new hierarchy is
    // 0-1-2, 0-3-4
    try transforms.handleParentUpdates(&.{.{
        .transformId = 3,
        .newParentId = 0,
    }});

    transforms.markChildrenUncomputed();
    try transforms.compute(arena);

    const expected: []const f32 = &.{ -1, -2, -3, -2, -3 };

    for (computed_matrices, expected) |matrix, expected_z| {
        const actual_position = matrix.getTranslation();
        try std.testing.expectApproxEqRel(expected_z, actual_position.z, 0.001);
    }
}

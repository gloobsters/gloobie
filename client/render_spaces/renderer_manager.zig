const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");

const RenderSpace = @import("RenderSpace.zig");
const TransformManager = @import("TransformManager.zig");

pub fn RendererManager(
    comptime ChildType: type,
    comptime UpdateType: type,
    comptime finishUpdateFn: anytype,
) type {
    return struct {
        const Self = @This();

        contents: std.ArrayListUnmanaged(ChildType),

        pub fn init() Self {
            return .{
                .contents = .empty,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator, device: gpu.Device) void {
            if (@hasDecl(ChildType, "deinit")) {
                for (self.contents.items) |removed| {
                    removed.deinit(gpa, device);
                }
            }

            self.contents.deinit(gpa);
        }

        pub fn handleUpdate(
            self: *Self,
            gpa: std.mem.Allocator,
            device: gpu.Device,
            accessor: *renderite.buffer.SharedMemoryAccessor,
            render_space: *RenderSpace,
            update: UpdateType,
        ) !void {
            const removals = try accessor.getOrCreate(i32, gpa, update.removals);
            defer removals.release(accessor);

            for (removals.data) |removal| {
                if (removal < 0) {
                    break;
                }

                const removed = self.contents.swapRemove(@intCast(removal));
                if (@hasDecl(ChildType, "deinit")) {
                    removed.deinit(gpa, device);
                }
            }

            const additions = try accessor.getOrCreate(i32, gpa, update.additions);
            defer additions.release(accessor);

            try self.contents.ensureUnusedCapacity(gpa, additions.data.len);

            for (additions.data) |transform| {
                if (transform < 0) {
                    break;
                }

                std.debug.assert(transform < render_space.transform_manager.transforms.len);

                const child: ChildType = .init(TransformManager.Transform.Id.from(transform));

                self.contents.appendAssumeCapacity(child);
            }

            return try finishUpdateFn(self.contents.items, gpa, accessor, update);
        }
    };
}

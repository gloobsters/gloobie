const std = @import("std");

const renderite = @import("renderite");

const RenderSpace = @import("RenderSpace.zig");
const Transforms = @import("Transforms.zig");

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

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.contents.deinit(gpa);
        }

        pub fn handleUpdate(
            self: *Self,
            gpa: std.mem.Allocator,
            accessor: *renderite.buffer.SharedMemoryAccessor,
            render_space: *RenderSpace,
            update: UpdateType,
        ) !void {
            if (try accessor.getOrCreate(i32, gpa, update.removals)) |removals| {
                defer removals.release(accessor);

                for (removals.data) |removal| {
                    if (removal < 0) {
                        break;
                    }

                    _ = self.contents.swapRemove(@intCast(removal));
                }
            }

            if (try accessor.getOrCreate(i32, gpa, update.additions)) |additions| {
                defer additions.release(accessor);

                try self.contents.ensureUnusedCapacity(gpa, additions.data.len);

                for (additions.data) |transform| {
                    if (transform < 0) {
                        break;
                    }

                    std.debug.assert(transform < render_space.transforms.transforms.items.len);

                    const child: ChildType = .init(Transforms.Transform.Id.from(transform));

                    self.contents.appendAssumeCapacity(child);
                }
            }

            return try finishUpdateFn(self, gpa, accessor, update);
        }
    };
}

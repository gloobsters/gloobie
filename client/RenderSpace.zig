const std = @import("std");

const renderite = @import("renderite");

const RenderSpace = @This();

pub const Id = enum(i32) {
    invalid = std.math.maxInt(i32),
    _,

    pub fn from(id: i32) Id {
        return @enumFromInt(id);
    }

    pub fn to(id: Id) i32 {
        return @intFromEnum(id);
    }
};

pub const Properties = struct {
    active: bool,
    overlay: bool,
    private: bool,
    root_transform: renderite.Shared.RenderTransform,
    view_position_is_external: bool,
    overridden_view_transform: ?renderite.Shared.RenderTransform,
};

id: Id,
properties: Properties,
updated: bool,

pub fn init(gpa: std.mem.Allocator, update: renderite.Shared.RenderSpaceUpdate) !RenderSpace {
    _ = gpa; // autofix

    const render_space: RenderSpace = .{
        .id = .from(update.id),
        .properties = loadProperties(update),
        .updated = false,
    };

    return render_space;
}

pub fn clearUpdated(self: *RenderSpace) void {
    self.updated = false;
}

fn loadProperties(update: renderite.Shared.RenderSpaceUpdate) Properties {
    return .{
        .active = update.isActive,
        .overlay = update.isOverlay,
        .private = update.isPrivate,
        .root_transform = update.rootTransform,
        .view_position_is_external = update.viewPositionIsExternal,
        .overridden_view_transform = if (update.overrideViewPosition)
            update.overridenViewTransform
        else
            null,
    };
}

pub fn handleUpdate(self: *RenderSpace, gpa: std.mem.Allocator, accessor: *renderite.SharedMemoryAccessor, update: renderite.Shared.RenderSpaceUpdate) !void {
    self.updated = true;

    self.properties = loadProperties(update);

    if (update.reflectionProbeSH2Taks) |sh2_tasks_descriptor| {
        if (try accessor.getOrCreate(gpa, sh2_tasks_descriptor.tasks)) |sh2_tasks_slice| {
            defer sh2_tasks_slice.release(accessor);

            // Make all reflection tasks fail
            const sh2_tasks: []align(1) renderite.Shared.ReflectionProbeSH2Task = @ptrCast(sh2_tasks_slice.data);
            for (sh2_tasks) |*task| {
                task.result = .Failed;
            }
        }
    }
}

pub fn deinit(self: RenderSpace) void {
    _ = self; // autofix
}

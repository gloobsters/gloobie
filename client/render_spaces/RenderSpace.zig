const std = @import("std");

const renderite = @import("renderite");

const Transforms = @import("Transforms.zig");

const RenderSpace = @This();

pub const Id = @import("../id.zig").Id(i32, struct {});

pub const Properties = struct {
    active: bool,
    overlay: bool,
    private: bool,
    root_transform: renderite.Shared.RenderTransform,
    view_position_is_external: bool,
    overridden_view_transform: ?renderite.Shared.RenderTransform,
};

// TODO: make this struct zero-width when ImGui is disabled
const ImGuiData = struct {
    render_window: bool,

    pub const default: ImGuiData = .{
        .render_window = true,
    };
};

id: Id,
properties: Properties,
updated: bool,
transforms: Transforms,
imgui_data: ImGuiData,

pub fn init(gpa: std.mem.Allocator, update: renderite.Shared.RenderSpaceUpdate) !RenderSpace {
    _ = gpa; // autofix

    const render_space: RenderSpace = .{
        .id = .from(update.id),
        .properties = loadProperties(update),
        .updated = false,
        .transforms = .init(),
        .imgui_data = .default,
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
        if (try accessor.getOrCreate(renderite.Shared.ReflectionProbeSH2Task, gpa, sh2_tasks_descriptor.tasks)) |sh2_tasks| {
            defer accessor.release(gpa, sh2_tasks);

            for (sh2_tasks.data) |*task| {
                task.result = .Failed;
            }
        }
    }

    if (update.transformsUpdate) |transforms_update| {
        try self.transforms.handleUpdate(gpa, accessor, transforms_update);
    }
}

pub fn deinit(self: *RenderSpace, gpa: std.mem.Allocator) void {
    self.transforms.deinit(gpa);
}

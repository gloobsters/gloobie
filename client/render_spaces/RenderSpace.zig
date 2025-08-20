const std = @import("std");

const renderite = @import("renderite");

const MeshRendererManager = @import("mesh_renderer_manager.zig").MeshRendererManager;
const RendererManager = @import("renderer_manager.zig").RendererManager;
const Transforms = @import("Transforms.zig");

const RenderSpace = @This();

pub const Id = @import("../id.zig").Id(i32, struct {});

const log = @import("logger").Scoped(.render_space);

pub const Properties = struct {
    active: bool,
    overlay: bool,
    private: bool,
    root_transform: renderite.shared.RenderTransform,
    view_position_is_external: bool,
    overridden_view_transform: ?renderite.shared.RenderTransform,
};

// TODO: make this struct zero-width when ImGui is disabled
const ImGuiData = struct {
    render_window: bool,

    pub const default: ImGuiData = .{
        .render_window = true,
    };
};

imgui_data: ImGuiData,
id: Id,
properties: Properties,
updated: bool,
transforms: Transforms,
mesh_renderer_manager: MeshRendererManager,

pub fn init(update: renderite.shared.RenderSpaceUpdate) !RenderSpace {
    const render_space: RenderSpace = .{
        .id = .from(update.id),
        .properties = loadProperties(update),
        .updated = false,
        .transforms = .init(),
        .imgui_data = .default,
        .mesh_renderer_manager = .init(),
    };

    return render_space;
}

pub fn clearUpdated(self: *RenderSpace) void {
    self.updated = false;
}

fn loadProperties(update: renderite.shared.RenderSpaceUpdate) Properties {
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

pub fn handleUpdate(self: *RenderSpace, gpa: std.mem.Allocator, accessor: *renderite.buffer.SharedMemoryAccessor, update: renderite.shared.RenderSpaceUpdate) !void {
    self.updated = true;

    self.properties = loadProperties(update);

    if (update.reflectionProbeSH2Taks) |sh2_tasks_descriptor| {
        const sh2_tasks = try accessor.getOrCreate(renderite.shared.ReflectionProbeSH2Task, gpa, sh2_tasks_descriptor.tasks);
        defer sh2_tasks.release(accessor);

        for (sh2_tasks.data) |*task| {
            task.result = .Failed;
        }
    }

    if (update.transformsUpdate) |transforms_update| {
        try self.transforms.handleUpdate(gpa, accessor, transforms_update);
    }

    if (update.meshRenderersUpdate) |mesh_renderer_update| {
        try self.mesh_renderer_manager.handleUpdate(gpa, accessor, self, mesh_renderer_update);
    }
}

pub fn deinit(self: *RenderSpace, gpa: std.mem.Allocator) void {
    self.transforms.deinit(gpa);
    self.mesh_renderer_manager.deinit(gpa);
}

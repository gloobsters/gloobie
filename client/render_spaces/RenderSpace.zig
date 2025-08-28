const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");
const tracy = @import("tracy");

const graphics = @import("../graphics.zig");
const mesh_renderer_managers = @import("mesh_renderer_manager.zig");
const RendererManager = @import("renderer_manager.zig").RendererManager;
const TransformManager = @import("TransformManager.zig");

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
transform_manager: TransformManager,
mesh_renderer_manager: mesh_renderer_managers.MeshRendererManager,
skinned_mesh_renderer_manager: mesh_renderer_managers.SkinnedMeshRendererManager,

pub fn init(update: renderite.shared.RenderSpaceUpdate) !RenderSpace {
    const render_space: RenderSpace = .{
        .id = .from(update.id),
        .properties = loadProperties(update),
        .updated = false,
        .transform_manager = .init(),
        .imgui_data = .default,
        .mesh_renderer_manager = .init(),
        .skinned_mesh_renderer_manager = .init(),
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

pub fn handleUpdateLocked(
    self: *RenderSpace,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    update: renderite.shared.RenderSpaceUpdate,
) !void {
    const trace = tracy.traceNamed(@src(), "Render Space Update");
    defer trace.end();

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
        try self.transform_manager.handleUpdate(
            gpa,
            arena,
            accessor,
            self,
            transforms_update,
        );
    }

    if (update.meshRenderersUpdate) |mesh_renderer_update| {
        try self.mesh_renderer_manager.handleUpdate(gpa, frame_context.device, accessor, self, mesh_renderer_update);
    }

    if (update.skinnedMeshRenderersUpdate) |skinned_mesh_renderers_update| {
        try self.skinned_mesh_renderer_manager.handleUpdate(gpa, frame_context.device, accessor, self, skinned_mesh_renderers_update);
    }

    for (self.skinned_mesh_renderer_manager.contents.items) |*skinned_mesh_renderer| {
        try skinned_mesh_renderer.tryPushDataAssetsLocked(gpa, frame_context);
    }
}

pub fn deinit(
    self: *RenderSpace,
    gpa: std.mem.Allocator,
    device: gpu.Device,
) void {
    self.transform_manager.deinit(gpa);
    self.mesh_renderer_manager.deinit(gpa, device);
    self.skinned_mesh_renderer_manager.deinit(gpa, device);
}

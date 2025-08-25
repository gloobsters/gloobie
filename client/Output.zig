const std = @import("std");

const gpu = @import("gpu");
const math = @import("math");
const renderite = @import("renderite");
const tracy = @import("tracy");

const App = @import("App.zig");
const Assets = @import("assets/Assets.zig");
const graphics = @import("graphics.zig");
const mesh_renderer_manager = @import("render_spaces/mesh_renderer_manager.zig");
const RenderSpace = @import("render_spaces/RenderSpace.zig");
const Transforms = @import("render_spaces/Transforms.zig");

const Output = @This();

pub const OutputTarget = struct {
    raster_target: gpu.Texture,
    cycle_raster_target: bool,
    depth_target: gpu.Texture,
    cycle_depth_target: bool,
};

const View = struct {
    pub const Type = enum {
        left_eye,
        right_eye,
        desktop,
    };

    transform: renderite.shared.RenderTransform,
    projection: math.Matrix4x4f,
    type: Type,
    output_target: OutputTarget,
};

views: std.ArrayListUnmanaged(View),

pub fn init() Output {
    return .{
        .views = .empty,
    };
}

pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
    self.views.deinit(gpa);
}

inline fn renderTransformToMatrix(render_transform: renderite.shared.RenderTransform) math.Matrix4x4f {
    return .createTranslationRotationScale(.{
        .x = render_transform.position.x,
        .y = render_transform.position.y,
        .z = render_transform.position.z,
    }, render_transform.rotation, render_transform.scale);
}

/// Ensures a view scale is actually valid, and non-zero
fn filterScale(scale: math.Vector3f) math.Vector3f {
    const minimum_scale: math.SimdVector3f = @splat(1E-08);

    if (@reduce(.Or, scale.toSimd() <= minimum_scale)) {
        return .one;
    }

    return scale;
}

fn renderSharedMeshRenderer(
    command_buffer: gpu.CommandBuffer,
    render_pass: gpu.RenderPass,
    mesh_renderer: mesh_renderer_manager.SharedMeshRenderable,
    assets: *Assets,
    computed_transforms: []math.Matrix4x4f,
) !void {
    // TODO: is this intended behaviour?
    // std.debug.assert(mesh_renderer.transform != .invalid);
    if (mesh_renderer.transform == .invalid) {
        return;
    }

    const mesh = assets.meshes.get(mesh_renderer.mesh) orelse return;
    if (mesh.vertex_buffer == null or mesh.index_buffer == null or !mesh.ready) {
        return;
    }

    command_buffer.pushVertexUniformData(1, std.mem.asBytes(&computed_transforms[@intCast(mesh_renderer.transform.to())]));

    const position_offset = find_position_offset: {
        var offset: u32 = 0;
        for (mesh.vertex_attributes) |vertex_attribute| {
            if (vertex_attribute.type == .Position) {
                break;
            }

            offset += vertex_attribute.format.stride() * mesh.mesh_layout.num_vertices;
        }
        break :find_position_offset offset;
    };

    render_pass.bindVertexBuffers(0, &.{
        .{
            .buffer = mesh.vertex_buffer.?,
            .offset = position_offset,
        },
    });

    render_pass.bindIndexBuffer(.{
        .buffer = mesh.index_buffer.?,
        .offset = 0,
    }, mesh.mesh_layout.index_element_type);

    for (mesh.submeshes) |submesh| {
        render_pass.drawIndexedPrimitives(
            submesh.index_count,
            1,
            submesh.index_start,
            0,
            0,
        );
    }
}

fn renderRenderSpace(
    arena: std.mem.Allocator,
    assets: *Assets,
    render_space: *RenderSpace,
    command_buffer: gpu.CommandBuffer,
    render_pass: gpu.RenderPass,
) !void {
    _ = arena; // autofix
    const trace = tracy.traceNamed(@src(), "Render Render Space");
    defer trace.end();

    const computed_transforms = render_space.transforms.computed_transforms.items(.matrix);

    for (render_space.mesh_renderer_manager.contents.items) |*mesh_renderer| {
        try renderSharedMeshRenderer(
            command_buffer,
            render_pass,
            mesh_renderer.shared,
            assets,
            computed_transforms,
        );
    }

    for (render_space.skinned_mesh_renderer_manager.contents.items) |*skinned_mesh_renderer| {
        try renderSharedMeshRenderer(
            command_buffer,
            render_pass,
            skinned_mesh_renderer.shared,
            assets,
            computed_transforms,
        );
    }
}

pub fn addDesktopView(
    self: *Output,
    gpa: std.mem.Allocator,
    desktop_fov: f32,
    near_z: f32,
    far_z: f32,
    swapchain_width: u32,
    swapchain_height: u32,
    texture: gpu.Texture,
    depth_texture: gpu.Texture,
) !void {
    const aspect_ratio: f32 = @as(f32, @floatFromInt(swapchain_width)) / @as(f32, @floatFromInt(swapchain_height));

    const vertical_fov = math.degreesToRadians(f32, desktop_fov);
    const horizontal_fov = std.math.clamp(std.math.atan(@tan(vertical_fov / 2.0) * aspect_ratio), 0.1, std.math.pi - 0.1) * 2.0;
    const matrix = math.Matrix4x4f.createProjectionFov(.{
        .angleUp = vertical_fov / 2.0,
        .angleDown = -(vertical_fov / 2.0),
        .angleRight = horizontal_fov / 2.0,
        .angleLeft = -(horizontal_fov / 2.0),
    }, far_z, near_z); // inverse Z

    try self.views.append(gpa, .{
        .projection = matrix,
        .transform = .{
            .position = .zero,
            .rotation = .identity,
            .scale = .one,
        },
        .output_target = .{
            .raster_target = texture,
            .cycle_raster_target = false,
            .depth_target = depth_texture,
            .cycle_depth_target = true,
        },
        .type = .desktop,
    });
}

pub fn renderScene(
    self: *Output,
    arena: std.mem.Allocator,
    app: *App,
    command_buffer: gpu.CommandBuffer,
) !void {
    const trace = tracy.traceNamed(@src(), "Render Scene");
    defer trace.end();

    defer self.views.clearRetainingCapacity();

    app.game.render_spaces_lock.lockShared();
    defer app.game.render_spaces_lock.unlockShared();

    app.assets.lock.lockShared();
    defer app.assets.lock.unlockShared();

    var first_render_pass = true;
    for (self.views.items) |*view| {
        const render_pass = command_buffer.beginRenderPass(&.{.{
            .texture = view.output_target.raster_target,
            .load = .clear,
            .store = .store,
            .clear_color = .{
                .r = 0.1,
                .g = 0.1,
                .b = 0.1,
                .a = 1,
            },
            .cycle = view.output_target.cycle_raster_target and first_render_pass,
        }}, .{
            .texture = view.output_target.depth_target,
            .clear_depth = 0.0,
            .load = .clear,
            .store = .store,
            .stencil_load = .do_not_care,
            .stencil_store = .do_not_care,
            .cycle = view.output_target.cycle_depth_target and first_render_pass,
            .clear_stencil = 0,
        });
        defer {
            render_pass.end();
            first_render_pass = false;
        }

        render_pass.bindGraphicsPipeline(app.graphics_data.window_test_pipeline.pipeline);

        for (app.game.render_spaces.values()) |*render_space| {
            if (!render_space.properties.active) {
                continue;
            }

            var view_transform = render_space.properties.overridden_view_transform orelse render_space.properties.root_transform;
            view_transform.scale = filterScale(view_transform.scale);

            const view_matrix: math.Matrix4x4f = renderTransformToMatrix(view_transform);

            var matrices: [2]math.Matrix4x4f = .{
                view_matrix.invert(),
                view.projection,
            };
            command_buffer.pushVertexUniformData(0, std.mem.sliceAsBytes(&matrices));

            try renderRenderSpace(
                arena,
                &app.assets,
                render_space,
                command_buffer,
                render_pass,
            );
        }
    }
}

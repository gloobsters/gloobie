const std = @import("std");

const gpu = @import("gpu");
const math = @import("math");
const renderite = @import("renderite");

const App = @import("App.zig");
const Assets = @import("assets/Assets.zig");
const graphics = @import("graphics.zig");
const RenderSpace = @import("render_spaces/RenderSpace.zig");

const Output = @This();

const View = struct {
    pub const Type = enum {
        left_eye,
        right_eye,
        desktop,
    };

    transform: renderite.shared.RenderTransform,
    projection: math.Matrix4x4f,
    type: Type,
    texture: gpu.Texture,
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
        .z = -render_transform.position.z,
    }, render_transform.rotation, render_transform.scale);
}

fn renderRenderSpace(
    arena: std.mem.Allocator,
    assets: *Assets,
    render_space: *RenderSpace,
    command_buffer: gpu.CommandBuffer,
    render_pass: gpu.RenderPass,
) !void {
    var transform_matrix_stack: std.ArrayListUnmanaged(*const renderite.shared.RenderTransform) = try .initCapacity(arena, 64);
    defer transform_matrix_stack.deinit(arena);

    const transforms = render_space.transforms.transforms.items;

    for (render_space.mesh_renderer_manager.contents.items) |*mesh_renderer| {
        std.debug.assert(mesh_renderer.transform != .invalid);

        const mesh = assets.meshes.get(mesh_renderer.mesh) orelse continue;
        if (mesh.vertex_buffer == null or mesh.index_buffer == null) {
            continue;
        }

        var transform_id = mesh_renderer.transform;
        while (transform_id != .invalid) {
            const transform = &transforms[@intCast(transform_id.to())];

            try transform_matrix_stack.append(arena, &transform.render_transform);

            transform_id = transform.parent;
        }

        std.debug.assert(transform_matrix_stack.items.len > 0);

        var model_matrix = renderTransformToMatrix(transform_matrix_stack.pop().?.*);
        while (transform_matrix_stack.pop()) |child_matrix| {
            model_matrix = model_matrix.mult(&renderTransformToMatrix(child_matrix.*));
        }

        command_buffer.pushComputeUniformData(1, std.mem.asBytes(&model_matrix));

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
) !void {
    const aspect_ratio: f32 = @as(f32, @floatFromInt(swapchain_width)) / @as(f32, @floatFromInt(swapchain_height));

    const vertical_fov = math.degreesToRadians(f32, desktop_fov);
    const horizontal_fov = std.math.clamp(std.math.atan(@tan(vertical_fov / 2.0) * aspect_ratio), 0.1, std.math.pi - 0.1) * 2.0;
    const matrix = math.Matrix4x4f.createProjectionFov(.{
        .angleUp = vertical_fov / 2.0,
        .angleDown = -(vertical_fov / 2.0),
        .angleRight = horizontal_fov / 2.0,
        .angleLeft = -(horizontal_fov / 2.0),
    }, near_z, far_z);

    try self.views.append(gpa, .{
        .projection = matrix,
        .transform = .{
            .position = .zero,
            .rotation = .identity,
            .scale = .one,
        },
        .texture = texture,
        .type = .desktop,
    });
}

pub fn renderScene(
    self: *Output,
    arena: std.mem.Allocator,
    app: *App,
    command_buffer: gpu.CommandBuffer,
) !void {
    defer self.views.clearRetainingCapacity();

    app.game.render_spaces_lock.lock();
    defer app.game.render_spaces_lock.unlock();

    app.assets.lock.lockShared();
    defer app.assets.lock.unlockShared();

    for (self.views.items) |*view| {
        const render_pass = command_buffer.beginRenderPass(&.{.{
            .texture = view.texture,
            .load = .clear,
            .store = .store,
            .clear_color = .{
                .r = 0.1,
                .g = 0.1,
                .b = 0.1,
                .a = 1,
            },
            .cycle = false,
        }}, null);
        defer render_pass.end();

        render_pass.bindGraphicsPipeline(app.graphics_data.window_test_pipeline.pipeline);

        for (app.game.render_spaces.values()) |*render_space| {
            if (!render_space.properties.active) {
                continue;
            }

            const view_matrix: math.Matrix4x4f = renderTransformToMatrix(render_space.properties.overridden_view_transform orelse render_space.properties.root_transform);

            const render_matrix = view.projection.mult(&view_matrix);

            command_buffer.pushComputeUniformData(0, std.mem.asBytes(&render_matrix));

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

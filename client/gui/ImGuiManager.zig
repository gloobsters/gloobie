const std = @import("std");

const gpu = @import("gpu");
const imgui = @import("imgui");

const App = @import("../App.zig");
const Texture = @import("../assets/Texture.zig");
const mesh_renderer_manager = @import("../render_spaces/mesh_renderer_manager.zig");
const RenderSpace = @import("../render_spaces/RenderSpace.zig");

pub const ImGuiManager = @This();

context: imgui.Context,

wants_mouse: bool,
wants_keyboard: bool,

open: bool,

demo_open: bool,
assets_open: bool,
performance_open: bool,
loadstate_open: bool,

temporary_graphics_bindings: std.ArrayListUnmanaged(gpu.TextureSamplerBinding),

app: *App,

pub fn init(context: imgui.Context, app: *App) ImGuiManager {
    return .{
        .context = context,
        .app = app,
        .wants_mouse = false,
        .wants_keyboard = false,
        .open = true,
        .assets_open = true,
        .loadstate_open = true,
        .demo_open = true,
        .performance_open = true,
        .temporary_graphics_bindings = .empty,
    };
}

pub fn deinit(self: *ImGuiManager, gpa: std.mem.Allocator) void {
    self.temporary_graphics_bindings.deinit(gpa);
    imgui.gpu.shutdown();
    imgui.sdl3.shutdown();
    self.context.destroy();
}

pub fn start(self: *ImGuiManager) !void {
    if (!self.open)
        return error.ImGuiClosed;

    const io = self.context.getIo();
    self.wants_mouse = io.WantCaptureMouse;
    self.wants_keyboard = io.WantCaptureKeyboard;

    // imgui new frame
    imgui.gpu.newFrame();
    imgui.sdl3.newFrame();
    imgui.newFrame();

    {
        const assets_render = imgui.begin("Assets", &self.assets_open, 0);
        defer imgui.end();
        if (assets_render) {
            self.app.assets.lock.lockShared();
            defer self.app.assets.lock.unlockShared();

            // ensure there's enough to handle all the textures
            self.temporary_graphics_bindings.clearRetainingCapacity();
            try self.temporary_graphics_bindings.ensureTotalCapacity(self.app.gpa, self.app.assets.textures.count());

            if (imgui.collapsingHeader("Texture 2Ds", 0)) {
                self.fillTextures(.Texture2D);
            }

            if (imgui.collapsingHeader("Texture 3Ds", 0)) {
                self.fillTextures(.Texture3D);
            }

            if (imgui.collapsingHeader("Cubemaps", 0)) {
                self.fillTextures(.Cubemap);
            }

            if (imgui.collapsingHeader("Meshes", 0)) {
                self.fillMeshes();
            }

            if (imgui.collapsingHeader("Materials", 0)) {
                self.fillMaterials();
            }

            if (imgui.collapsingHeader("Property Blocks", 0)) {
                self.fillPropertyBlocks();
            }
        }
    }

    self.fillRenderSpaces();

    {
        const performance_render = imgui.begin("Performance", &self.performance_open, 0);
        defer imgui.end();
        if (performance_render) {
            self.fillPerformance();
        }
    }

    if (!self.app.game.load_state.full_init) {
        const phase = &self.app.game.load_state.phase;
        const loadstate_render = imgui.begin("Loading...", &self.loadstate_open, 0);
        defer imgui.end();
        if (loadstate_render) {
            imgui.text(phase.phase_name.buffer[0..phase.phase_name.len :0]);
            if (phase.sub_phase_name.len != 0)
                imgui.text(phase.sub_phase_name.buffer[0..phase.sub_phase_name.len :0]);

            const progress: f32 = @as(f32, @floatFromInt(phase.phase_index)) / @as(f32, @floatFromInt(App.total_load_phases));
            imgui.progressBar(progress, .{ .x = 0, .y = 0 }, "");
        }
    }

    imgui.showDemoWindow(&self.demo_open);

    imgui.render();
}

pub fn getDrawData(command_buffer: gpu.CommandBuffer) ?*imgui.DrawData {
    const draw_data = imgui.getDrawData();
    const is_minimized = draw_data.DisplaySize.x <= 0.0 or draw_data.DisplaySize.y <= 0.0;

    if (is_minimized) {
        return null;
    }

    imgui.gpu.prepareDrawData(draw_data, command_buffer);
    return draw_data;
}

pub fn draw(draw_data: *imgui.DrawData, command_buffer: gpu.CommandBuffer, render_pass: gpu.RenderPass) void {
    imgui.gpu.renderDrawData(
        draw_data,
        command_buffer,
        render_pass,
        null,
    );
}

fn fillMaterials(self: *ImGuiManager) void {
    var material_iter = self.app.assets.materials.materials.iterator();
    while (material_iter.next()) |material_entry| {
        defer imgui.separator();

        const id, const material = .{ material_entry.key_ptr.*, material_entry.value_ptr };

        imgui.c.igText("Material %d", id.to());
        imgui.c.igText("Render Type: %s", @tagName(material.render_type).ptr);
        imgui.c.igText("Shader ID: %d", material.shader_id.to());
        imgui.c.igText("Render Queue Override: %d", material.render_queue_override orelse -1);
        imgui.c.igText("Enable Instancing: %d", @as(u32, @intFromBool(material.enable_instancing)));
    }
}

fn fillPropertyBlocks(self: *ImGuiManager) void {
    var property_block_iter = self.app.assets.materials.property_blocks.iterator();
    while (property_block_iter.next()) |material_entry| {
        defer imgui.separator();

        const id, const property_block = .{ material_entry.key_ptr.*, material_entry.value_ptr };
        _ = property_block;

        imgui.c.igText("Property Block %d", id.to());
    }
}

fn fillTextures(self: *ImGuiManager, texture_type: Texture.Type) void {
    var texture_iter = self.app.assets.textures.iterator();
    while (texture_iter.next()) |texture_entry| {
        if (texture_entry.value_ptr.properties.type != texture_type) {
            continue;
        }

        defer imgui.separator();

        const handle, const texture = .{ texture_entry.key_ptr.*, texture_entry.value_ptr };

        imgui.c.igText("%s %d", @tagName(handle.type).ptr, @intFromEnum(handle.id));
        imgui.c.igText("Filter Mode: %s", @tagName(texture.properties.filter_mode).ptr);
        imgui.c.igText("Anisotropicsy Level: %d", texture.properties.aniso_level);
        imgui.c.igText("Wrap U/V: %s/%s", @tagName(texture.properties.wrap_u).ptr, @tagName(texture.properties.wrap_v).ptr);
        imgui.c.igText("Mipmap bias: %f", texture.properties.mipmap_bias);
        // NOTE: we're pulling a reference because we need a stable pointer to `.binding`!!!
        if (texture.graphics_data) |*graphics_data| {
            imgui.c.igText("Extents: %ux%ux%u", graphics_data.width, graphics_data.height, graphics_data.depth);
            imgui.c.igText("Format/Color Profile: %s %s", @tagName(graphics_data.texture_format).ptr, @tagName(graphics_data.profile).ptr);
            imgui.c.igText("Mipmap count: %u", graphics_data.mipmap_count);

            if (graphics_data.ready) {
                const render_scale = 512.0 / @as(f32, @floatFromInt(if (graphics_data.height > graphics_data.width) graphics_data.height else graphics_data.width));

                const width = render_scale * @as(f32, @floatFromInt(graphics_data.width));
                const height = render_scale * @as(f32, @floatFromInt(graphics_data.height));

                // We can only display 2D textures in ImGui
                if (texture_type == .Texture2D) {
                    // Put it into a stable array
                    self.temporary_graphics_bindings.appendAssumeCapacity(graphics_data.binding);

                    imgui.image(
                        &self.temporary_graphics_bindings.items[self.temporary_graphics_bindings.items.len - 1],
                        width,
                        height,
                    );
                }
            }
        } else {
            imgui.c.igText("No graphics data");
        }
    }
}

fn fillMeshes(self: *ImGuiManager) void {
    var mesh_iter = self.app.assets.meshes.iterator();
    while (mesh_iter.next()) |mesh_entry| {
        const asset_id, const mesh = .{ mesh_entry.key_ptr.*, mesh_entry.value_ptr };
        defer imgui.separator();

        imgui.c.igText("Mesh %d", asset_id.to());
        imgui.c.igText("Vertex Buffer Capacity: %u", mesh.vertex_buffer_capacity);
        imgui.c.igText("Index Buffer Capacity: %u", mesh.index_buffer_capacity);
        imgui.c.igText(
            "Buffer Present: %s/%s",
            if (mesh.vertex_buffer == null) "false".ptr else "true".ptr,
            if (mesh.index_buffer == null) "false".ptr else "true".ptr,
        );

        var name_buf: [64]u8 = undefined;
        // SAFETY: it's big enough
        const attributes_header = std.fmt.bufPrintZ(&name_buf, "Attributes##{d}", .{
            asset_id.to(),
        }) catch unreachable;

        if (imgui.collapsingHeader(attributes_header, 0)) {
            for (mesh.vertex_attributes, 0..) |attribute, i| {
                imgui.c.igText(
                    "Attribute %d, %s/%s",
                    @as(i32, @intCast(i)),
                    @tagName(attribute.format).ptr,
                    @tagName(attribute.type).ptr,
                );
            }
        }

        const submeshes_header = std.fmt.bufPrintZ(&name_buf, "Sub Meshes##{d}", .{
            asset_id.to(),
        }) catch unreachable;

        if (imgui.collapsingHeader(submeshes_header, 0)) {
            for (mesh.submeshes, 0..) |submesh, i| {
                imgui.c.igText(
                    "Submesh %d, %s, %u/%u, %fx%fx%f/%fx%fx%f",
                    @as(i32, @intCast(i)),
                    @tagName(submesh.topology).ptr,
                    submesh.index_start,
                    submesh.index_count,
                    submesh.bounds.center.x,
                    submesh.bounds.center.y,
                    submesh.bounds.center.z,
                    submesh.bounds.extents.x,
                    submesh.bounds.extents.y,
                    submesh.bounds.extents.z,
                );
            }
        }
    }
}

fn fillRenderSpaces(self: *ImGuiManager) void {
    self.app.game.render_spaces_lock.lockShared();
    defer self.app.game.render_spaces_lock.unlockShared();

    const render_spaces = self.app.game.render_spaces.values();

    for (render_spaces) |*render_space| {
        var name_buf: [64]u8 = undefined;
        // SAFETY: it's big enough
        const name = std.fmt.bufPrintZ(&name_buf, "Render Space {d}", .{render_space.id.to()}) catch unreachable;

        const render_window = imgui.begin(name, &render_space.imgui_data.render_window, 0);
        defer imgui.end();

        if (render_window) {
            self.fillRenderSpace(render_space);
        }
    }
}

fn fillRenderSpace(self: *ImGuiManager, render_space: *RenderSpace) void {
    _ = self; // autofix

    const root_transform = render_space.properties.root_transform;

    var name_buf: [64]u8 = undefined;

    imgui.c.igText("Active: %d", @as(u32, @intFromBool(render_space.properties.active)));
    imgui.c.igText("Overlay: %d", @as(u32, @intFromBool(render_space.properties.overlay)));
    imgui.c.igText("Private: %d", @as(u32, @intFromBool(render_space.properties.private)));
    imgui.c.igText("View Position Is External: %d", @as(u32, @intFromBool(render_space.properties.private)));
    imgui.c.igText(
        "Root Transform: %fx%fx%f, %f,%f,%f, %f,%f,%f,%f",
        root_transform.position.x,
        root_transform.position.y,
        root_transform.position.z,
        root_transform.scale.x,
        root_transform.scale.y,
        root_transform.scale.z,
        root_transform.rotation.x,
        root_transform.rotation.y,
        root_transform.rotation.z,
        root_transform.rotation.w,
    );
    if (render_space.properties.overridden_view_transform) |overridden_root_transform| {
        imgui.c.igText(
            "Overridden Root Transform: %fx%fx%f, %f,%f,%f, %f,%f,%f,%f",
            overridden_root_transform.position.x,
            overridden_root_transform.position.y,
            overridden_root_transform.position.z,
            overridden_root_transform.scale.x,
            overridden_root_transform.scale.y,
            overridden_root_transform.scale.z,
            overridden_root_transform.rotation.x,
            overridden_root_transform.rotation.y,
            overridden_root_transform.rotation.z,
            overridden_root_transform.rotation.w,
        );
    } else {
        imgui.c.igText("View transform not overridden.");
    }

    if (imgui.collapsingHeader("Transforms", 0)) {
        for (0..render_space.transforms.transforms.len) |i| {
            defer imgui.separator();

            const transform = render_space.transforms.transforms.get(i);

            imgui.c.igText("Transform %d", @as(i32, @intCast(i)));
            if (transform.parent != .invalid) {
                imgui.c.igText("Parent: %d", transform.parent.to());
            }
            imgui.c.igText(
                "Render Transform: %fx%fx%f, %fx%fx%f, %fx%fx%fx%f",
                transform.render_transform.position.x,
                transform.render_transform.position.y,
                transform.render_transform.position.z,
                transform.render_transform.scale.x,
                transform.render_transform.scale.x,
                transform.render_transform.scale.z,
                transform.render_transform.rotation.x,
                transform.render_transform.rotation.y,
                transform.render_transform.rotation.z,
                transform.render_transform.rotation.w,
            );
        }
    }

    if (imgui.collapsingHeader("Mesh Renderers", 0)) {
        for (render_space.mesh_renderer_manager.contents.items, 0..) |*mesh_renderer, i| {
            defer imgui.separator();

            imgui.c.igText("Mesh Renderer %d", @as(i32, @intCast(i)));
            fillMeshRendererShared(mesh_renderer.shared, i);
        }
    }

    if (imgui.collapsingHeader("Skinned Mesh Renderers", 0)) {
        for (render_space.skinned_mesh_renderer_manager.contents.items, 0..) |*skinned_mesh_renderer, i| {
            defer imgui.separator();

            imgui.c.igText("Skinned Mesh Renderer %d", @as(i32, @intCast(i)));
            fillMeshRendererShared(skinned_mesh_renderer.shared, i);
            imgui.c.igText("Update when offscreen: %d", @as(c_int, @intFromBool(skinned_mesh_renderer.update_when_offscreen)));
            imgui.c.igText(
                "Bounds: %fx%fx%f, %fx%fx%f",
                skinned_mesh_renderer.bounds.center.x,
                skinned_mesh_renderer.bounds.center.y,
                skinned_mesh_renderer.bounds.center.z,
                skinned_mesh_renderer.bounds.extents.x,
                skinned_mesh_renderer.bounds.extents.y,
                skinned_mesh_renderer.bounds.extents.z,
            );
            imgui.c.igText("Root bone: %d", skinned_mesh_renderer.root_bone.to());
            // SAFETY: it's big enough
            if (imgui.collapsingHeader(std.fmt.bufPrintZ(&name_buf, "Bones##{d}", .{i}) catch unreachable, 0)) {
                for (skinned_mesh_renderer.bones, 0..) |bone, bone_i| {
                    defer imgui.separator();

                    imgui.c.igText("[%d] Bone: %d", @as(usize, @intCast(bone_i)), bone.to());
                }
            }
        }
    }
}

fn fillMeshRendererShared(
    shared: mesh_renderer_manager.SharedMeshRenderable,
    i: usize,
) void {
    var name_buf: [64]u8 = undefined;
    imgui.c.igText("Transform: %d", shared.transform.to());
    imgui.c.igText("Mesh: %d", shared.mesh.to());
    imgui.c.igText("Shadow Cast Mode: %s", @tagName(shared.shadow_cast_mode).ptr);
    imgui.c.igText("Motion Vector Mode: %s", @tagName(shared.motion_vector_mode).ptr);
    imgui.c.igText("Sorting Order: %d", @as(c_int, shared.sorting_order));
    if (imgui.collapsingHeader(
        // SAFETY: it's big enough
        std.fmt.bufPrintZ(&name_buf, "Material Pairs##{d}", .{i}) catch unreachable,
        0,
    )) for (shared.material_pairs) |pair| {
        defer imgui.separator();

        imgui.c.igText("Material: %d", pair.material.to());
        imgui.c.igText("Property Block: %d", pair.property_block.to());
    };
}

fn fillPerformance(self: *ImGuiManager) void {
    const perf = self.app.game.perf.state;
    // TODO: truncate floats so they are prettier
    imgui.c.igText("FPS: %f", perf.fps);
    imgui.c.igText("Render time: %fms", perf.renderTime);
}

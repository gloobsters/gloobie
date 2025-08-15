const std = @import("std");

pub const c = @import("c");
pub const Io = c.ImGuiIO;
pub const DrawData = c.ImDrawData;
pub const ImVec2 = c.ImVec2;
const GuiStyle = c.ImGuiStyle;
const gpu_t = @import("gpu");
const sdl3_t = @import("sdl3");

pub const FontAtlas = struct {
    value: *c.ImFontAtlas,
};

pub const Context = struct {
    value: *c.ImGuiContext,

    pub fn create(shared_font_atlas: ?FontAtlas) !Context {
        const context = c.igCreateContext(if (shared_font_atlas) |sfa| sfa.value else null);

        return .{
            .value = context orelse return error.FailedToCreateContext,
        };
    }

    pub fn destroy(self: Context) void {
        return c.igDestroyContext(self.value);
    }

    pub fn setCurrent(self: Context) void {
        return c.igSetCurrentContext(self.value);
    }

    pub fn getIo(self: Context) *Io {
        return c.igGetIO_ContextPtr(self.value);
    }
};

pub fn init() void {
    return c.igInitialize();
}

pub fn deinit() void {
    return c.igShutdown();
}

pub fn newFrame() void {
    return c.igNewFrame();
}

pub fn render() void {
    return c.igRender();
}

pub fn begin(name: [:0]const u8, open: *bool, flags: c.ImGuiWindowFlags) bool {
    return c.igBegin(name.ptr, open, flags);
}

pub fn end() void {
    return c.igEnd();
}

pub fn collapsingHeader(name: [:0]const u8, flags: c.ImGuiTreeNodeFlags) bool {
    return c.igCollapsingHeader_TreeNodeFlags(name.ptr, flags);
}

pub fn separator() void {
    return c.igSeparator();
}

pub fn text(str: [:0]const u8) void {
    return c.igText(str.ptr);
}

pub fn progressBar(fraction: f32, size_arg: ImVec2, overlay: [:0]const u8) void {
    return c.igProgressBar(fraction, size_arg, overlay.ptr);
}

pub fn getDrawData() *DrawData {
    return c.igGetDrawData();
}

pub fn showDemoWindow(p_open: *bool) void {
    return c.igShowDemoWindow(p_open);
}

pub fn getStyle() *GuiStyle {
    return c.igGetStyle();
}

pub fn image(binding: *const gpu_t.TextureSamplerBinding, tex_width: f32, tex_height: f32) void {
    return c.igImage(
        .{ ._TexID = @intFromPtr(binding) },
        .{ .x = tex_width, .y = tex_height },
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 1 },
    );
}

pub const sdl3 = struct {
    pub fn initForOther(window: sdl3_t.video.Window) !void {
        // SAFETY: These should be compatible values of "window"
        return if (c.ImGui_ImplSDL3_InitForOther(@ptrCast(window.value))) {} else error.FailedToInitSdl3Backend;
    }

    pub fn shutdown() void {
        c.ImGui_ImplSDL3_Shutdown();
    }

    pub fn newFrame() void {
        c.ImGui_ImplSDL3_NewFrame();
    }

    pub fn processEvent(event: sdl3_t.events.Event) bool {
        return c.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&event.toSdl()));
    }
};

pub const gpu = struct {
    pub const InitInfo = extern struct {
        device: gpu_t.Device,
        color_target_format: gpu_t.TextureFormat,
        msaa_samples: gpu_t.SampleCount,

        comptime {
            std.debug.assert(@sizeOf(InitInfo) == @sizeOf(c.ImGui_ImplGPU_InitInfo));
            std.debug.assert(@offsetOf(InitInfo, "device") == @offsetOf(c.ImGui_ImplGPU_InitInfo, "Device"));
            std.debug.assert(@offsetOf(InitInfo, "color_target_format") == @offsetOf(c.ImGui_ImplGPU_InitInfo, "ColorTargetFormat"));
            std.debug.assert(@offsetOf(InitInfo, "msaa_samples") == @offsetOf(c.ImGui_ImplGPU_InitInfo, "MSAASamples"));
        }

        pub fn to(self: InitInfo) c.ImGui_ImplGPU_InitInfo {
            return @bitCast(self);
        }
    };

    pub fn init(info: InitInfo) !void {
        return if (c.ImGui_ImplGPU_Init(&info.to())) {} else return error.FailedToInitImGuiGpu;
    }

    pub fn shutdown() void {
        return c.ImGui_ImplGPU_Shutdown();
    }

    pub fn newFrame() void {
        return c.ImGui_ImplGPU_NewFrame();
    }

    pub fn prepareDrawData(draw_data: *c.ImDrawData, command_buffer: gpu_t.CommandBuffer) void {
        return c.ImGui_ImplGPU_PrepareDrawData(draw_data, @ptrCast(command_buffer.value));
    }

    pub fn renderDrawData(draw_data: *c.ImDrawData, command_buffer: gpu_t.CommandBuffer, render_pass: gpu_t.RenderPass, maybe_pipeline: ?gpu_t.GraphicsPipeline) void {
        return c.ImGui_ImplGPU_RenderDrawData(
            draw_data,
            @ptrCast(command_buffer.value),
            @ptrCast(render_pass.value),
            if (maybe_pipeline) |pipeline| @ptrCast(pipeline.value) else null,
        );
    }
};

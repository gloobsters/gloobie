const std = @import("std");

pub const c = @import("c");
pub const Io = c.ImGuiIO;
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
};

pub fn init() void {
    return c.igInitialize();
}

pub fn deinit() void {
    return c.igShutdown();
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

    pub fn processEvent(event: sdl3_t.events.Event) !void {
        return if (c.ImGui_ImplSDL3_ProcessEvent(&event.toSdl())) {} else error.FailedToProcessSdl3Event;
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

    pub fn deinit() void {
        return c.ImGui_ImplGPU_Shutdown();
    }

    pub fn newFrame() void {
        return c.ImGui_ImplGPU_NewFrame();
    }

    pub fn prepareDrawData(draw_data: *c.ImDrawData, command_buffer: gpu_t.CommandBuffer) void {
        return c.ImGui_ImplGPU_PrepareDrawData(draw_data, command_buffer.value);
    }

    pub fn renderDrawData(draw_data: *c.ImDrawData, command_buffer: gpu_t.CommandBuffer, render_pass: gpu_t.RenderPass, pipeline: gpu_t.GraphicsPipeline) void {
        return c.ImGui_ImplGPU_RenderDrawData(draw_data, command_buffer.value, render_pass.value, pipeline.value);
    }
};

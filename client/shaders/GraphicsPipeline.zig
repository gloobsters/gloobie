const gpu = @import("gpu");
const math = @import("math");

const GpuShader = @import("GpuShader.zig");

const GraphicsPipeline = @This();

pipeline: gpu.GraphicsPipeline,
target_format: gpu.TextureFormat,

pub fn create(
    device: gpu.Device,
    target_format: gpu.TextureFormat,
    vertex_shader: GpuShader,
    fragment_shader: GpuShader,
) !GraphicsPipeline {
    const pipeline = try device.createGraphicsPipeline(.{
        .vertex_shader = vertex_shader.shader,
        .fragment_shader = fragment_shader.shader,
        .target_info = .{
            .color_target_descriptions = &.{.{
                .format = target_format,
            }},
            .depth_stencil_format = .depth32_float,
        },
        .rasterizer_state = .{
            .cull_mode = .back,
            .front_face = .clockwise,
            .enable_depth_clip = true,
        },
        .vertex_input_state = .{
            .vertex_attributes = &.{
                .{ .location = 0, .buffer_slot = 0, .format = .f32x3, .offset = 0 },
            },
            .vertex_buffer_descriptions = &.{
                .{ .slot = 0, .pitch = @sizeOf(math.Vector3f), .input_rate = .vertex },
            },
        },
        .depth_stencil_state = .{
            .enable_stencil_test = false,
            .enable_depth_test = true,
            .enable_depth_write = true,
            .compare = .greater_or_equal,
        },
    });

    return .{
        .pipeline = pipeline,
        .target_format = target_format,
    };
}

pub fn deinit(self: GraphicsPipeline, device: gpu.Device) void {
    device.releaseGraphicsPipeline(self.pipeline);
}

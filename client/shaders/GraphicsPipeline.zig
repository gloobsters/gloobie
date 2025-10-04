const gpu = @import("gpu");
const math = @import("math");
const reflection = @import("reflection");

const GpuShader = @import("GpuShader.zig");

const GraphicsPipeline = @This();

pipeline: gpu.GraphicsPipeline,
target_format: gpu.TextureFormat,

pub fn create(
    device: gpu.Device,
    target_format: gpu.TextureFormat,
    vertex_shader: GpuShader,
    fragment_shader: GpuShader,
    comptime shader_data: reflection.Shader,
) !GraphicsPipeline {
    var vertex_attributes: [shader_data.vertex_inputs.len]gpu.VertexAttribute = @splat(undefined);
    var vertex_buffer_descriptions: [shader_data.vertex_inputs.len]gpu.VertexBufferDescription = @splat(undefined);
    for (&vertex_buffer_descriptions, &vertex_attributes, shader_data.vertex_inputs) |
        *description,
        *attribute,
        vertex_input,
    | {
        description.* = .{
            .input_rate = .vertex,
            .pitch = vertex_input.format.stride(),
            .slot = vertex_input.location,
        };
        attribute.* = .{
            .buffer_slot = vertex_input.location,
            .format = vertex_input.format,
            .location = vertex_input.location,
            .offset = 0,
        };
    }

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
            .vertex_attributes = &vertex_attributes,
            .vertex_buffer_descriptions = &vertex_buffer_descriptions,
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

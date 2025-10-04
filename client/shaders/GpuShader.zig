const std = @import("std");

const gpu = @import("gpu");
const options = @import("options").build_options;
const reflection = @import("reflection");

const log = @import("logger").Scoped(.graphics);

const GpuShader = @This();

shader: gpu.Shader,

pub fn create(
    device: gpu.Device,
    comptime shader_data: reflection.Shader,
    format: gpu.ShaderFormatFlags,
    entry_point: [:0]const u8,
    stage: gpu.ShaderStage,
) !GpuShader {
    const reflection_data = switch (stage) {
        .vertex => shader_data.vertex_stage,
        .fragment => shader_data.fragment_stage,
    };

    log.debug(@src(), "Creating shader with {d} uniform buffers and {d} storage buffers", .{ reflection_data.num_uniform_buffers, reflection_data.num_storage_buffers });

    // NOTE: when adding new shader binary types, add them here!
    const code =
        if ((comptime options.render_backends.vulkan) and format.spirv)
            shader_data.spirv
        else if ((comptime options.render_backends.d3d12) and format.dxil)
            shader_data.dxil
        else if ((comptime options.render_backends.metal) and format.metal_lib)
            shader_data.metal
        else
            return error.BadFormatFlags;

    const shader = try device.createShader(.{
        .code = code,
        .format = format,
        .entry_point = entry_point,
        .num_uniform_buffers = reflection_data.num_uniform_buffers,
        .num_storage_buffers = reflection_data.num_storage_buffers,
        .num_samplers = reflection_data.num_samplers,
        .num_storage_textures = reflection_data.num_storage_textures,
        .stage = stage,
    });

    return .{
        .shader = shader,
    };
}

pub fn deinit(self: GpuShader, device: gpu.Device) void {
    device.releaseShader(self.shader);
}

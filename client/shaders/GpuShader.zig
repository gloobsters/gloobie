const std = @import("std");

const gpu = @import("gpu");

const GpuShader = @This();

const ReflectionData = struct {
    const ParameterKind = enum {
        constantBuffer,
    };

    parameters: []const struct {
        name: []const u8,
        binding: struct {
            kind: []const u8,
            space: i64,
            index: i64,
        },
        type: struct {
            kind: ParameterKind,
            elementType: struct {
                kind: []const u8,
                name: []const u8,
                fields: []const struct {
                    name: []const u8,
                    type: struct {
                        kind: []const u8,
                        rowCount: i64,
                        columnCount: i64,
                        elementType: struct {
                            kind: []const u8,
                            scalarType: []const u8,
                        },
                    },
                    binding: struct {
                        kind: []const u8,
                        offset: i64,
                        size: i64,
                        elementStride: i64,
                    },
                },
            },
            containerVarLayout: struct {
                binding: struct {
                    kind: []const u8,
                    index: i64,
                },
            },
            elementVarLayout: struct {
                type: struct {
                    kind: []const u8,
                    name: []const u8,
                    fields: []const struct {
                        name: []const u8,
                        type: struct {
                            kind: []const u8,
                            rowCount: i64,
                            columnCount: i64,
                            elementType: struct {
                                kind: []const u8,
                                scalarType: []const u8,
                            },
                        },
                        binding: struct {
                            kind: []const u8,
                            offset: i64,
                            size: i64,
                            elementStride: i64,
                        },
                    },
                },
                binding: struct {
                    kind: []const u8,
                    offset: i64,
                    size: i64,
                    elementStride: i64,
                },
            },
        },
    },
    entryPoints: []const struct {
        name: []const u8,
        stage: []const u8,
        parameters: []const struct {
            name: []const u8,
            stage: []const u8,
            binding: struct {
                kind: []const u8,
                index: i64,
            },
            semanticName: ?[]const u8 = null,
            type: struct {
                kind: []const u8,
                name: []const u8,
                fields: []const struct {
                    name: []const u8,
                    type: struct {
                        kind: []const u8,
                        elementCount: i64,
                        elementType: struct {
                            kind: []const u8,
                            scalarType: []const u8,
                        },
                    },
                    stage: []const u8,
                    binding: struct {
                        kind: []const u8,
                        index: i64,
                    },
                    semanticName: []const u8,
                },
            },
        },
        result: struct {
            stage: []const u8,
            binding: struct {
                kind: []const u8,
                index: i64,
            },
            semanticName: ?[]const u8 = null,
            type: struct {
                kind: []const u8,
                elementCount: ?i64 = null,
                elementType: ?struct {
                    kind: []const u8,
                    scalarType: []const u8,
                } = null,
            },
        },
        bindings: []const struct {
            name: []const u8,
            binding: struct {
                kind: []const u8,
                space: i64,
                index: i64,
                used: i64,
            },
        },
    },
};

shader: gpu.Shader,

pub fn create(
    arena: std.mem.Allocator,
    device: gpu.Device,
    code: []const u8,
    reflection_data: []const u8,
    format: gpu.ShaderFormatFlags,
    entry_point: [:0]const u8,
    stage: gpu.ShaderStage,
) !GpuShader {
    const parsed_reflection_data: ReflectionData = try std.json.parseFromSliceLeaky(
        ReflectionData,
        arena,
        reflection_data,
        .{
            .allocate = .alloc_if_needed,
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .@"error",
        },
    );

    var num_uniform_buffers: u32 = 0;
    for (parsed_reflection_data.parameters) |parameter| {
        if (parameter.type.kind == .constantBuffer) {
            num_uniform_buffers += 1;
        }
    }

    const shader = try device.createShader(.{
        .code = code,
        .format = format,
        .entry_point = entry_point,
        .num_uniform_buffers = num_uniform_buffers,
        .stage = stage,
    });

    return .{
        .shader = shader,
    };
}

pub fn deinit(self: GpuShader, device: gpu.Device) void {
    device.releaseShader(self.shader);
}

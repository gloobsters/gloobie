const std = @import("std");

const gpu = @import("gpu");

const log = @import("logger").Scoped(.graphics);

const GpuShader = @This();

const ReflectionData = struct {
    const ParameterKind = enum {
        constantBuffer,
        resource,
    };

    const BaseShape = enum {
        structuredBuffer,
    };

    parameters: []const struct {
        name: []const u8,
        binding: struct {
            kind: []const u8,
            space: i64 = 0,
            index: i64,
        },
        type: struct {
            kind: ParameterKind,
            baseShape: ?BaseShape = null,
            elementType: ?struct {
                kind: []const u8,
                name: ?[]const u8 = null,
                fields: ?[]const struct {
                    name: []const u8,
                    type: struct {
                        kind: []const u8,
                        rowCount: ?i64 = null,
                        columnCount: ?i64 = null,
                        elementType: ?struct {
                            kind: []const u8,
                            scalarType: []const u8,
                        } = null,
                    },
                    binding: struct {
                        kind: []const u8,
                        offset: i64,
                        size: i64,
                        elementStride: i64,
                    },
                } = null,
            } = null,
            containerVarLayout: ?struct {
                binding: struct {
                    kind: []const u8,
                    index: i64,
                },
            } = null,
            elementVarLayout: ?struct {
                type: struct {
                    kind: []const u8,
                    name: []const u8,
                    fields: []const struct {
                        name: []const u8,
                        type: struct {
                            kind: []const u8,
                            rowCount: ?i64 = null,
                            columnCount: ?i64 = null,
                            elementType: ?struct {
                                kind: []const u8,
                                scalarType: []const u8,
                            } = null,
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
            } = null,
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
                space: i64 = 0,
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

    const entry_point_bindings = parsed_reflection_data.entryPoints[0].bindings;

    var num_uniform_buffers: u32 = 0;
    var num_storage_buffers: u32 = 0;
    for (parsed_reflection_data.parameters) |parameter| {
        if (parameter.type.kind == .constantBuffer) {
            num_uniform_buffers += 1;

            // don't include parameters not used
            for (entry_point_bindings) |binding| {
                if (std.mem.eql(u8, binding.name, parameter.name) and binding.binding.used == 0) {
                    num_uniform_buffers -= 1;
                }
            }
        }

        if (parameter.type.kind == .resource) {
            if (parameter.type.baseShape) |base_shape| {
                if (base_shape == .structuredBuffer) {
                    num_storage_buffers += 1;

                    // don't include parameters not used
                    for (entry_point_bindings) |binding| {
                        if (std.mem.eql(u8, binding.name, parameter.name) and binding.binding.used == 0) {
                            num_storage_buffers -= 1;
                        }
                    }
                }
            }
        }
    }

    log.debug(@src(), "Creating shader with {d} uniform buffers and {d} storage buffers", .{ num_uniform_buffers, num_storage_buffers });

    const shader = try device.createShader(.{
        .code = code,
        .format = format,
        .entry_point = entry_point,
        .num_uniform_buffers = num_uniform_buffers,
        .num_storage_buffers = num_storage_buffers,
        .stage = stage,
    });

    return .{
        .shader = shader,
    };
}

pub fn deinit(self: GpuShader, device: gpu.Device) void {
    device.releaseShader(self.shader);
}

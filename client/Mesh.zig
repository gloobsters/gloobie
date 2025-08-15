const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");

const graphics = @import("graphics.zig");

const log = @import("logger").Scoped(.mesh);

const Mesh = @This();

const VertexAttribute = struct {
    type: renderite.Shared.VertexAttributeType,
    format: gpu.VertexElementFormat,
};

const MeshLayout = struct {
    vertex_stride: u32,
    index_buffer_start: u32,
    num_indices: u32,
    index_buffer_byte_size: u32,
};

const SubMesh = struct {
    topology: renderite.Shared.SubmeshTopology,
    index_start: u32,
    index_count: u32,
    bounds: renderite.Shared.RenderBoundingBox,
};

vertex_buffer: ?gpu.Buffer,
vertex_buffer_capacity: u32,
index_buffer: ?gpu.Buffer,
index_buffer_capacity: u32,

vertex_attributes: []const VertexAttribute,
submeshes: []const SubMesh,
mesh_layout: MeshLayout,

pub fn init(
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.SharedMemoryAccessor,
    data_request: renderite.Shared.MeshUploadData,
) !Mesh {
    var mesh: Mesh = .{
        .mesh_layout = undefined,
        .vertex_buffer = null,
        .index_buffer = null,
        .vertex_attributes = &.{},
        .submeshes = &.{},
        .index_buffer_capacity = 0,
        .vertex_buffer_capacity = 0,
    };

    try mesh.setData(gpa, frame_context, accessor, data_request);

    return mesh;
}

fn convertVertexAttributes(gpa: std.mem.Allocator, renderite_vertex_attributes: []const renderite.Shared.VertexAttributeDescriptor) ![]VertexAttribute {
    const vertex_attributes = try gpa.alloc(VertexAttribute, renderite_vertex_attributes.len);
    errdefer gpa.free(vertex_attributes);

    for (vertex_attributes, renderite_vertex_attributes) |*vertex_attribute, renderite_vertex_attribute| {
        vertex_attribute.* = .{
            .type = renderite_vertex_attribute.attribute,
            .format = renderiteVertexAttributeDescriptorToVertexElementFormat(renderite_vertex_attribute) orelse return error.UnsupportedVertexAttribute,
        };
    }

    return vertex_attributes;
}

fn convertSubMeshes(gpa: std.mem.Allocator, renderite_submeshes: []const renderite.Shared.SubmeshBufferDescriptor) ![]SubMesh {
    const submeshes = try gpa.alloc(SubMesh, renderite_submeshes.len);
    errdefer gpa.free(submeshes);

    for (submeshes, renderite_submeshes) |*submesh, renderite_submesh| {
        submesh.* = .{
            .bounds = renderite_submesh.bounds,
            .index_count = @intCast(renderite_submesh.indexCount),
            .index_start = @intCast(renderite_submesh.indexStart),
            .topology = renderite_submesh.topology,
        };
    }

    return submeshes;
}

pub fn setData(
    self: *Mesh,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.SharedMemoryAccessor,
    data_request: renderite.Shared.MeshUploadData,
) !void {
    // log.debug(@src(), "Got mesh upload {any}", .{data_request});

    const slice = try accessor.getOrCreate(u8, gpa, data_request.buffer) orelse {
        const vertex_attributes = try convertVertexAttributes(gpa, data_request.vertexAttributes);
        errdefer gpa.free(vertex_attributes);

        const submeshes = try convertSubMeshes(gpa, data_request.submeshes);
        errdefer gpa.free(submeshes);

        self.* = .{
            .index_buffer = null,
            .vertex_buffer = null,
            .index_buffer_capacity = 0,
            .vertex_buffer_capacity = 0,
            .mesh_layout = try calculateMeshLayout(data_request),
            .submeshes = submeshes,
            .vertex_attributes = vertex_attributes,
        };

        return;
    };
    defer slice.release(accessor);

    const data = slice.data;

    var buffer_name_buf: [64]u8 = undefined;
    // SAFETY: it's big enough
    const vertex_buffer_name = std.fmt.bufPrintZ(&buffer_name_buf, "Vertex Buffer {d}", .{data_request.assetId}) catch unreachable;

    const mesh_layout = try calculateMeshLayout(data_request);

    const vertex_buffer_byte_size = mesh_layout.index_buffer_start;

    const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(.{ .size = data.len, .value = .download });
    defer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM while releasing transfer buffer pool entry");

    const vertex_buffer = create_vertex_buffer: {
        // If the vertex buffer is already big enough, then just use that
        if (self.vertex_buffer_capacity >= vertex_buffer_byte_size) {
            // SAFETY: vertex buffer is always defined when capacity >0
            break :create_vertex_buffer self.vertex_buffer.?;
        }

        if (self.vertex_buffer) |current_vertex_buffer| {
            frame_context.device.releaseBuffer(current_vertex_buffer);
        }

        break :create_vertex_buffer try frame_context.device.createBuffer(.{
            .props = .{ .name = vertex_buffer_name },
            .size = vertex_buffer_byte_size,
            .usage = .{
                .vertex = true,
            },
        });
    };
    errdefer frame_context.device.releaseBuffer(vertex_buffer);

    // SAFETY: it's big enough
    const index_buffer_name = std.fmt.bufPrintZ(&buffer_name_buf, "Index Buffer {d}", .{data_request.assetId}) catch unreachable;

    const index_buffer = create_index_buffer: {
        // If the index buffer is already big enough, then just use that
        if (self.index_buffer_capacity >= mesh_layout.index_buffer_byte_size) {
            // SAFETY: index buffer is always defined when capacity >0
            break :create_index_buffer self.index_buffer.?;
        }

        if (self.index_buffer) |current_index_buffer| {
            frame_context.device.releaseBuffer(current_index_buffer);
        }

        break :create_index_buffer try frame_context.device.createBuffer(.{
            .props = .{ .name = index_buffer_name },
            .size = mesh_layout.index_buffer_byte_size,
            .usage = .{
                .index = true,
            },
        });
    };
    errdefer frame_context.device.releaseBuffer(index_buffer);

    {
        const write_ptr = try frame_context.device.mapTransferBuffer(transfer_buffer_entry.value, true);
        defer frame_context.device.unmapTransferBuffer(transfer_buffer_entry.value);

        @memcpy(write_ptr, data);
    }

    const copy_pass = try frame_context.getSharedCopyPass();

    copy_pass.uploadToBuffer(.{
        .offset = 0,
        .transfer_buffer = transfer_buffer_entry.value,
    }, .{
        .buffer = vertex_buffer,
        .offset = 0,
        .size = mesh_layout.index_buffer_start,
    }, true);

    copy_pass.uploadToBuffer(.{
        .offset = mesh_layout.index_buffer_start,
        .transfer_buffer = transfer_buffer_entry.value,
    }, .{
        .buffer = index_buffer,
        .offset = 0,
        .size = mesh_layout.index_buffer_byte_size,
    }, true);

    gpa.free(self.submeshes);
    const submeshes = try convertSubMeshes(gpa, data_request.submeshes);
    errdefer gpa.free(submeshes);

    gpa.free(self.vertex_attributes);
    const vertex_attributes = try convertVertexAttributes(gpa, data_request.vertexAttributes);
    errdefer gpa.free(vertex_attributes);

    try frame_context.messaging_host.background.sendTimeout(.{
        .MeshUploadResult = .{
            .assetId = data_request.assetId,
            .instanceChanged = true,
        },
    }, std.time.ns_per_s * 10);

    self.* = .{
        .vertex_buffer = vertex_buffer,
        .vertex_buffer_capacity = mesh_layout.index_buffer_start,
        .index_buffer = index_buffer,
        .index_buffer_capacity = mesh_layout.index_buffer_byte_size,
        .vertex_attributes = vertex_attributes,
        .submeshes = submeshes,
        .mesh_layout = mesh_layout,
    };
}

pub fn deinit(self: Mesh, gpa: std.mem.Allocator, device: gpu.Device) void {
    if (self.vertex_buffer) |vertex_buffer| {
        device.releaseBuffer(vertex_buffer);
    }
    if (self.index_buffer) |index_buffer| {
        device.releaseBuffer(index_buffer);
    }

    gpa.free(self.vertex_attributes);
    gpa.free(self.submeshes);
}

fn calculateMeshLayout(data_request: renderite.Shared.MeshUploadData) !MeshLayout {
    var vertex_stride: u32 = 0;
    for (data_request.vertexAttributes) |attribute| {
        const format = renderiteVertexAttributeDescriptorToVertexElementFormat(attribute) orelse return error.InvalidVertexAttributeDescriptor;

        vertex_stride += format.stride();
    }

    const index_buffer_start = vertex_stride * @as(u32, @intCast(data_request.vertexCount));

    var num_indices: u32 = 0;
    for (data_request.submeshes) |submesh| {
        num_indices = @max(num_indices, submesh.indexStart + submesh.indexCount);
    }

    const index_buffer_byte_size = num_indices * renderiteIndexBufferFormatToGpu(data_request.indexBufferFormat).byteSize();

    return .{
        .vertex_stride = vertex_stride,
        .index_buffer_start = index_buffer_start,
        .num_indices = num_indices,
        .index_buffer_byte_size = index_buffer_byte_size,
    };
}

fn renderiteIndexBufferFormatToGpu(index_buffer_format: renderite.Shared.IndexBufferFormat) gpu.IndexElementSize {
    return switch (index_buffer_format) {
        .UInt16 => .indices_16bit,
        .UInt32 => .indices_32bit,
    };
}

fn renderiteVertexAttributeDescriptorToVertexElementFormat(descriptor: renderite.Shared.VertexAttributeDescriptor) ?gpu.VertexElementFormat {
    return switch (descriptor.format) {
        .Float32 => switch (descriptor.dimensions) {
            1 => .f32x1,
            2 => .f32x2,
            3 => .f32x3,
            4 => .f32x4,
            else => null,
        },
        .Half16 => switch (descriptor.dimensions) {
            1 => null,
            2 => .f16x2,
            3 => null,
            4 => .f16x4,
            else => null,
        },
        .SInt16 => switch (descriptor.dimensions) {
            1 => null,
            2 => .i16x2,
            3 => null,
            4 => .i16x4,
            else => null,
        },
        .SInt32 => switch (descriptor.dimensions) {
            1 => .i32x1,
            2 => .i32x2,
            3 => .i32x3,
            4 => .i32x4,
            else => null,
        },
        .SInt8 => switch (descriptor.dimensions) {
            1 => null,
            2 => .i8x2,
            3 => null,
            4 => .i8x4,
            else => null,
        },
        .UInt16 => switch (descriptor.dimensions) {
            1 => null,
            2 => .u16x2,
            3 => null,
            4 => .u16x4,
            else => null,
        },
        .UInt32 => switch (descriptor.dimensions) {
            1 => .u32x1,
            2 => .u32x2,
            3 => .u32x3,
            4 => .u32x4,
            else => null,
        },
        .UInt8 => switch (descriptor.dimensions) {
            1 => null,
            2 => .u8x2,
            3 => null,
            4 => .u8x4,
            else => null,
        },
        .UNorm16 => switch (descriptor.dimensions) {
            1 => null,
            2 => .u16x2_normalized,
            3 => null,
            4 => .u16x4_normalized,
            else => null,
        },
        .UNorm8 => switch (descriptor.dimensions) {
            1 => null,
            2 => .u8x2_normalized,
            3 => null,
            4 => .u8x4_normalized,
            else => null,
        },
    };
}

test renderiteVertexAttributeDescriptorToVertexElementFormat {
    try std.testing.expectEqual(gpu.VertexElementFormat.f16x2, renderiteVertexAttributeDescriptorToVertexElementFormat(.{
        .attribute = .Position,
        .dimensions = 2,
        .format = .Half16,
    }));

    try std.testing.expectEqual(gpu.VertexElementFormat.f32x3, renderiteVertexAttributeDescriptorToVertexElementFormat(.{
        .attribute = .Position,
        .dimensions = 3,
        .format = .Float32,
    }));

    try std.testing.expectEqual(gpu.VertexElementFormat.i16x2, renderiteVertexAttributeDescriptorToVertexElementFormat(.{
        .attribute = .Position,
        .dimensions = 2,
        .format = .SInt16,
    }));
}

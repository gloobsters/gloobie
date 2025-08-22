const std = @import("std");

const gpu = @import("gpu");
const renderite = @import("renderite");
const shared = renderite.shared;

const graphics = @import("../graphics.zig");

const log = @import("logger").Scoped(.mesh);

const Mesh = @This();

const VertexAttribute = struct {
    type: shared.VertexAttributeType,
    format: gpu.VertexElementFormat,
};

const MeshLayout = struct {
    interleaved_vertex_stride: u32,
    index_buffer_start: u32,
    num_indices: u32,
    index_buffer_byte_size: u32,
    num_vertices: u32,
    index_element_type: gpu.IndexElementSize,
};

const SubMesh = struct {
    topology: shared.SubmeshTopology,
    index_start: u32,
    index_count: u32,
    bounds: shared.RenderBoundingBox,
};

vertex_buffer: ?gpu.Buffer,
vertex_buffer_capacity: u32,
index_buffer: ?gpu.Buffer,
index_buffer_capacity: u32,

vertex_attributes: []const VertexAttribute,
submeshes: []const SubMesh,
mesh_layout: MeshLayout,

bone_count: u32,
bone_weight_count: u32,

pub fn init(
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    data_request: shared.MeshUploadData,
) !Mesh {
    var mesh: Mesh = .{
        .mesh_layout = undefined,
        .vertex_buffer = null,
        .index_buffer = null,
        .vertex_attributes = &.{},
        .submeshes = &.{},
        .index_buffer_capacity = 0,
        .vertex_buffer_capacity = 0,
        .bone_count = 0,
        .bone_weight_count = 0,
    };

    try mesh.setData(gpa, frame_context, accessor, data_request);

    return mesh;
}

fn convertVertexAttributes(gpa: std.mem.Allocator, renderite_vertex_attributes: []const shared.VertexAttributeDescriptor) ![]VertexAttribute {
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

fn convertSubMeshes(gpa: std.mem.Allocator, renderite_submeshes: []const shared.SubmeshBufferDescriptor) ![]SubMesh {
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

fn hasVertexStreams(upload_hint: shared.MeshUploadHint_Flag) bool {
    return upload_hint.Positions or
        upload_hint.Normals or
        upload_hint.Tangents or
        upload_hint.Colors or
        upload_hint.UV0s or
        upload_hint.UV1s or
        upload_hint.UV2s or
        upload_hint.UV3s or
        upload_hint.UV4s or
        upload_hint.UV5s or
        upload_hint.UV6s or
        upload_hint.UV7s;
}

const TransferBufferContext = struct {
    transfer_buffer: gpu.TransferBuffer,
    data: []u8,
    capacity: usize,
    index: u32,

    /// An upload pending to be uploaded once the transfer buffer is free
    pub const PendingUpload = struct {
        transfer_buffer: gpu.TransferBuffer,
        target: gpu.Buffer,
        transfer_buffer_offset: u32,
        size: u32,

        pub fn upload(self: PendingUpload, copy_pass: gpu.CopyPass) void {
            copy_pass.uploadToBuffer(.{
                .transfer_buffer = self.transfer_buffer,
                .offset = self.transfer_buffer_offset,
            }, .{
                .buffer = self.target,
                .size = self.size,
                .offset = 0,
            }, true);
        }
    };

    pub fn get(self: *TransferBufferContext, len: u32) struct { []u8, u32 } {
        defer self.index += len;
        return .{ self.data[self.index .. self.index + len], self.index };
    }
};

const VertexIndexUploadResult = struct {
    vertex_buffer: ?gpu.Buffer,
    new_vertex_buffer_capacity: u32,
    index_buffer: ?gpu.Buffer,
    new_index_buffer_capacity: u32,
};

fn uploadVertex(
    self: *Mesh,
    frame_context: *graphics.FrameContext,
    transfer_buffer_context: *TransferBufferContext,
    mesh_layout: MeshLayout,
    data: []const u8,
    data_request: shared.MeshUploadData,
) !struct { ?gpu.Buffer, u32, ?TransferBufferContext.PendingUpload } {
    const vertex_buffer_byte_size = mesh_layout.index_buffer_start;

    // No vertex streams
    if (!hasVertexStreams(data_request.uploadHint._flags) or vertex_buffer_byte_size == 0) {
        return .{ self.vertex_buffer, self.vertex_buffer_capacity, null };
    }

    const src = data[0..vertex_buffer_byte_size];
    const dst, const transfer_buffer_start_idx = transfer_buffer_context.get(vertex_buffer_byte_size);

    const vertex_stride = mesh_layout.interleaved_vertex_stride;
    const vertex_count = mesh_layout.num_vertices;

    var first_source_element_start_position: u32 = 0;
    var first_destination_element_start_position: u32 = 0;
    for (data_request.vertexAttributes) |vertex_attribute| {
        const attribute_stride = renderiteVertexAttributeDescriptorToVertexElementFormat(vertex_attribute).?.stride();

        for (0..vertex_count) |i| {
            const attribute_start = (vertex_stride * i) + first_source_element_start_position;

            const attribute_data = src[attribute_start .. attribute_start + attribute_stride];

            const destination_start = first_destination_element_start_position + (attribute_stride * i);
            const attribute_destination = dst[destination_start .. destination_start + attribute_stride];

            @memcpy(attribute_destination, attribute_data);
        }

        first_source_element_start_position += attribute_stride;
        first_destination_element_start_position += attribute_stride * vertex_count;
    }

    const vertex_buffer, const vertex_buffer_capacity = get_vertex_buffer: {
        if (self.vertex_buffer_capacity >= vertex_buffer_byte_size) {
            break :get_vertex_buffer .{ self.vertex_buffer.?, self.vertex_buffer_capacity };
        }

        if (self.vertex_buffer) |vertex_buffer| {
            frame_context.device.releaseBuffer(vertex_buffer);
            self.vertex_buffer = null;
        }

        const vertex_buffer = try frame_context.device.createBuffer(.{
            .size = vertex_buffer_byte_size,
            .usage = .{ .vertex = true },
        });
        errdefer frame_context.device.releaseBuffer(vertex_buffer);

        break :get_vertex_buffer .{ vertex_buffer, vertex_buffer_byte_size };
    };
    errdefer frame_context.device.releaseBuffer(vertex_buffer);

    return .{
        vertex_buffer, vertex_buffer_capacity, .{
            .transfer_buffer = transfer_buffer_context.transfer_buffer,
            .target = vertex_buffer,
            .transfer_buffer_offset = transfer_buffer_start_idx,
            .size = vertex_buffer_byte_size,
        },
    };
}

fn uploadIndex(
    self: *Mesh,
    frame_context: *graphics.FrameContext,
    transfer_buffer_context: *TransferBufferContext,
    mesh_layout: MeshLayout,
    data: []const u8,
    data_request: shared.MeshUploadData,
) !struct { ?gpu.Buffer, u32, ?TransferBufferContext.PendingUpload } {
    const should_upload_index_buffer = data_request.uploadHint._flags.Geometry or data_request.uploadHint._flags.SubmeshLayout;

    const index_buffer_byte_size = mesh_layout.index_buffer_byte_size;

    if (!should_upload_index_buffer or index_buffer_byte_size == 0) {
        return .{ self.index_buffer, self.index_buffer_capacity, null };
    }

    const src = data[mesh_layout.index_buffer_start .. mesh_layout.index_buffer_start + index_buffer_byte_size];
    const dst, const transfer_buffer_start_idx = transfer_buffer_context.get(index_buffer_byte_size);

    @memcpy(dst, src);

    const index_buffer, const index_buffer_capacity = get_index_buffer: {
        if (self.index_buffer_capacity >= index_buffer_byte_size) {
            break :get_index_buffer .{ self.index_buffer.?, self.index_buffer_capacity };
        }

        if (self.index_buffer) |index_buffer| {
            frame_context.device.releaseBuffer(index_buffer);
            self.index_buffer = null;
        }

        const index_buffer = try frame_context.device.createBuffer(.{
            .size = index_buffer_byte_size,
            .usage = .{ .index = true },
        });
        errdefer frame_context.device.releaseBuffer(index_buffer);

        break :get_index_buffer .{ index_buffer, index_buffer_byte_size };
    };
    errdefer frame_context.device.releaseBuffer(index_buffer);

    return .{
        index_buffer, index_buffer_capacity, .{
            .transfer_buffer = transfer_buffer_context.transfer_buffer,
            .target = index_buffer,
            .transfer_buffer_offset = transfer_buffer_start_idx,
            .size = index_buffer_byte_size,
        },
    };
}

pub fn setData(
    self: *Mesh,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    data_request: shared.MeshUploadData,
) !void {
    // log.debug(@src(), "Got mesh upload {any}", .{data_request});

    const slice = try accessor.getOrCreate(u8, gpa, data_request.buffer);
    defer slice.release(accessor);

    const data = slice.data;

    const mesh_layout = try calculateMeshLayout(data_request);

    const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(.{ .size = data.len, .value = .download });
    defer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM while releasing transfer buffer pool entry");

    const mapped_ptr = try frame_context.device.mapTransferBuffer(transfer_buffer_entry.value, true);
    const vertex_upload, const index_upload = upload_vertex_index: {
        defer frame_context.device.unmapTransferBuffer(transfer_buffer_entry.value);

        var transfer_buffer_context: TransferBufferContext = .{
            .transfer_buffer = transfer_buffer_entry.value,
            .capacity = data.len,
            .data = mapped_ptr[0..data.len],
            .index = 0,
        };

        const vertex_upload = try self.uploadVertex(
            frame_context,
            &transfer_buffer_context,
            mesh_layout,
            data,
            data_request,
        );
        errdefer if (vertex_upload[0]) |buffer| frame_context.device.releaseBuffer(buffer);
        const index_upload = try self.uploadIndex(
            frame_context,
            &transfer_buffer_context,
            mesh_layout,
            data,
            data_request,
        );
        errdefer if (index_upload[0]) |buffer| frame_context.device.releaseBuffer(buffer);

        break :upload_vertex_index .{ vertex_upload, index_upload };
    };
    errdefer {
        if (vertex_upload[0]) |buffer| frame_context.device.releaseBuffer(buffer);
        if (index_upload[0]) |buffer| frame_context.device.releaseBuffer(buffer);
    }

    const copy_pass = try frame_context.getSharedCopyPass();
    if (vertex_upload[2]) |pending_upload| {
        pending_upload.upload(copy_pass);
    }
    if (index_upload[2]) |pending_upload| {
        pending_upload.upload(copy_pass);
    }

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
        .vertex_buffer = vertex_upload[0],
        .vertex_buffer_capacity = vertex_upload[1],
        .index_buffer = index_upload[0],
        .index_buffer_capacity = index_upload[1],
        .vertex_attributes = vertex_attributes,
        .submeshes = submeshes,
        .mesh_layout = mesh_layout,
        .bone_count = @intCast(data_request.boneCount),
        .bone_weight_count = @intCast(data_request.boneWeightCount),
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

fn calculateMeshLayout(data_request: shared.MeshUploadData) !MeshLayout {
    var interleaved_vertex_stride: u32 = 0;
    for (data_request.vertexAttributes) |attribute| {
        const format = renderiteVertexAttributeDescriptorToVertexElementFormat(attribute) orelse return error.InvalidVertexAttributeDescriptor;

        interleaved_vertex_stride += format.stride();
    }

    const index_buffer_start = interleaved_vertex_stride * @as(u32, @intCast(data_request.vertexCount));

    var num_indices: u32 = 0;
    for (data_request.submeshes) |submesh| {
        num_indices = @max(num_indices, submesh.indexStart + submesh.indexCount);
    }

    const index_element_type = renderiteIndexBufferFormatToGpu(data_request.indexBufferFormat);

    const index_buffer_byte_size = num_indices * index_element_type.byteSize();

    return .{
        .interleaved_vertex_stride = interleaved_vertex_stride,
        .index_buffer_start = index_buffer_start,
        .num_indices = num_indices,
        .index_buffer_byte_size = index_buffer_byte_size,
        .num_vertices = @intCast(data_request.vertexCount),
        .index_element_type = index_element_type,
    };
}

fn renderiteIndexBufferFormatToGpu(index_buffer_format: shared.IndexBufferFormat) gpu.IndexElementSize {
    return switch (index_buffer_format) {
        .UInt16 => .indices_16bit,
        .UInt32 => .indices_32bit,
    };
}

fn renderiteVertexAttributeDescriptorToVertexElementFormat(descriptor: shared.VertexAttributeDescriptor) ?gpu.VertexElementFormat {
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

const std = @import("std");

const gpu = @import("gpu");
const math = @import("math");
const renderite = @import("renderite");
const shared = renderite.shared;

const graphics = @import("../graphics.zig");

const log = @import("logger").Scoped(.mesh);

const Mesh = @This();

const VertexAttribute = struct {
    /// The type of data contained within
    type: shared.VertexAttributeType,
    /// The format of the vertex element
    format: gpu.VertexElementFormat,
};

const BufferRegion = struct {
    byte_start: u32,
    byte_end: u32,

    pub fn len(self: BufferRegion) u32 {
        return self.byte_end - self.byte_start;
    }

    pub fn slice(self: BufferRegion, data: anytype) @TypeOf(data) {
        return data[self.byte_start..self.byte_end];
    }
};

const MeshLayout = struct {
    num_vertices: u32,
    /// How many bytes per vertex in it's original interleaved form
    interleaved_vertex_stride: u32,
    /// The number of indices
    num_indices: u32,
    /// The type of index contained within the index buffer
    index_element_type: gpu.IndexElementSize,
    /// The data region containing the vertex buffer
    vertex_buffer: BufferRegion,
    /// The data region containing the index buffer
    index_buffer: BufferRegion,
    /// The data region containing the amount of bones a vertex is effected by
    bone_counts_buffer: BufferRegion,
    /// The data region containing the bone weights of each vertex
    bone_weights_buffer: BufferRegion,
    /// The data region containing the inverse bind poses for each bone
    inverse_bind_poses_buffer: BufferRegion,
    /// The data region containing the data for all blend shapes
    blendshapes_buffer: BufferRegion,
    /// The total number of blendshapes
    num_blendshapes: u32,
};

const SubMesh = struct {
    /// The topology of the submesh
    topology: shared.SubmeshTopology,
    /// The index into the index buffer where indices for this submesh starts
    index_start: u32,
    /// The amount of indices in this submesh
    index_count: u32,
    /// The bounding box for this submesh
    bounds: shared.RenderBoundingBox,
};

const SkinningData = struct {
    /// The inverse of all the bind poses
    inverse_bind_poses: []math.Matrix4x4f,
    /// The amount of bones on the mesh
    bone_count: u32,
    /// The buffer storing the bone weights and ids
    bone_buffer: ?gpu.Buffer,
    /// The starting index of the vertex weights
    weights_start_idx: u32,
    /// The starting index of the vertex bone IDs
    ids_start_idx: u32,
    /// The GPU buffer storing the blendshape vertex offsets
    blendshape_buffer: ?gpu.Buffer,

    pub fn deinit(self: SkinningData, gpa: std.mem.Allocator, device: gpu.Device) void {
        gpa.free(self.inverse_bind_poses);
        if (self.bone_buffer) |buffer| device.releaseBuffer(buffer);
        if (self.blendshape_buffer) |buffer| device.releaseBuffer(buffer);
    }
};

/// The buffer storing all the vertex data for all submeshes
vertex_buffer: ?gpu.Buffer,
/// The capacity of the vertex buffer, eg. how big is the buffer, regardless of how much data is within
vertex_buffer_capacity: u32,
/// The buffer storing all the index data for all submeshes
index_buffer: ?gpu.Buffer,
/// The capacity of the index buffer, eg. how big is the buffer, regardless of how much data is within
index_buffer_capacity: u32,

/// The details of all vertex attributes this mesh uses
vertex_attributes: []const VertexAttribute,
/// The sub-meshes contained within this mesh, this is used for having different materials or topology per sub-mesh
submeshes: []const SubMesh,
/// The layout of the mesh
mesh_layout: MeshLayout,
/// Contains all the data related to skinning this mesh
skinning_data: SkinningData,

/// Whether or not this is ready for use
ready: bool,
/// The upload nonce unique for this upload
upload_nonce: u64,

/// Creates a new mesh with some starting data
pub fn init(
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    data_request: shared.MeshUploadData,
) !Mesh {
    var mesh: Mesh = .{
        // SAFETY: this will always get filled out by the call to setData
        .mesh_layout = undefined,
        .vertex_buffer = null,
        .index_buffer = null,
        .vertex_attributes = &.{},
        .submeshes = &.{},
        .index_buffer_capacity = 0,
        .vertex_buffer_capacity = 0,
        .skinning_data = .{
            .bone_count = 0,
            .inverse_bind_poses = &.{},
            .bone_buffer = null,
            .ids_start_idx = 0,
            .weights_start_idx = 0,
            .blendshape_buffer = null,
        },
        .ready = false,
        .upload_nonce = 0,
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
            .index_count = @intCast(renderite_submesh.index_count),
            .index_start = @intCast(renderite_submesh.index_start),
            .topology = renderite_submesh.topology,
        };
    }

    return submeshes;
}

fn hasVertexStreams(upload_hint: shared.MeshUploadHintFlag) bool {
    return upload_hint.positions or
        upload_hint.normals or
        upload_hint.tangents or
        upload_hint.colors or
        upload_hint.uv0s or
        upload_hint.uv1s or
        upload_hint.uv2s or
        upload_hint.uv3s or
        upload_hint.uv4s or
        upload_hint.uv5s or
        upload_hint.uv6s or
        upload_hint.uv7s;
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
    // No vertex streams
    if (!hasVertexStreams(data_request.upload_hint.flags) or mesh_layout.vertex_buffer.len() == 0) {
        return .{ self.vertex_buffer, self.vertex_buffer_capacity, null };
    }

    const src = mesh_layout.vertex_buffer.slice(data);
    const dst, const transfer_buffer_start_idx = transfer_buffer_context.get(mesh_layout.vertex_buffer.len());

    const vertex_stride = mesh_layout.interleaved_vertex_stride;
    const vertex_count = mesh_layout.num_vertices;

    var first_source_element_start_position: u32 = 0;
    var first_destination_element_start_position: u32 = 0;
    for (data_request.vertex_attributes) |vertex_attribute| {
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
        if (self.vertex_buffer_capacity >= mesh_layout.vertex_buffer.len()) {
            break :get_vertex_buffer .{ self.vertex_buffer.?, self.vertex_buffer_capacity };
        }

        if (self.vertex_buffer) |vertex_buffer| {
            frame_context.device.releaseBuffer(vertex_buffer);
            self.vertex_buffer = null;
        }

        const vertex_buffer = try frame_context.device.createBuffer(.{
            .size = mesh_layout.vertex_buffer.len(),
            .usage = .{ .vertex = true },
        });
        errdefer frame_context.device.releaseBuffer(vertex_buffer);

        break :get_vertex_buffer .{ vertex_buffer, mesh_layout.vertex_buffer.len() };
    };
    errdefer frame_context.device.releaseBuffer(vertex_buffer);

    return .{
        vertex_buffer, vertex_buffer_capacity, .{
            .transfer_buffer = transfer_buffer_context.transfer_buffer,
            .target = vertex_buffer,
            .transfer_buffer_offset = transfer_buffer_start_idx,
            .size = mesh_layout.vertex_buffer.len(),
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
    const should_upload_index_buffer = data_request.upload_hint.flags.geometry or data_request.upload_hint.flags.submesh_layout;

    if (!should_upload_index_buffer or mesh_layout.index_buffer.len() == 0) {
        return .{ self.index_buffer, self.index_buffer_capacity, null };
    }

    const src = mesh_layout.index_buffer.slice(data);
    const dst, const transfer_buffer_start_idx = transfer_buffer_context.get(mesh_layout.index_buffer.len());

    @memcpy(dst, src);

    const index_buffer, const index_buffer_capacity = get_index_buffer: {
        if (self.index_buffer_capacity >= mesh_layout.index_buffer.len()) {
            break :get_index_buffer .{ self.index_buffer.?, self.index_buffer_capacity };
        }

        if (self.index_buffer) |index_buffer| {
            frame_context.device.releaseBuffer(index_buffer);
            self.index_buffer = null;
        }

        const index_buffer = try frame_context.device.createBuffer(.{
            .size = mesh_layout.index_buffer.len(),
            .usage = .{ .index = true },
        });
        errdefer frame_context.device.releaseBuffer(index_buffer);

        break :get_index_buffer .{ index_buffer, mesh_layout.index_buffer.len() };
    };
    errdefer frame_context.device.releaseBuffer(index_buffer);

    return .{
        index_buffer, index_buffer_capacity, .{
            .transfer_buffer = transfer_buffer_context.transfer_buffer,
            .target = index_buffer,
            .transfer_buffer_offset = transfer_buffer_start_idx,
            .size = mesh_layout.index_buffer.len(),
        },
    };
}

fn getChunk(
    src: []align(1) const math.Vector3f,
    num_vertices: u32,
    chunks_read: *u32,
) []align(1) const math.Vector3f {
    defer chunks_read.* += 1;

    const start = chunks_read.* * num_vertices;
    return src[start .. start + num_vertices];
}

fn uploadSkinningData(
    self: *Mesh,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    data_request: shared.MeshUploadData,
    mesh_layout: MeshLayout,
    data: []const u8,
) !SkinningData {
    gpa.free(self.skinning_data.inverse_bind_poses);
    self.skinning_data.inverse_bind_poses = &.{};

    // ME BONES
    if (self.skinning_data.bone_count == 0) {
        return .{
            .bone_buffer = null,
            .bone_count = 0,
            .ids_start_idx = 0,
            .inverse_bind_poses = &.{},
            .weights_start_idx = 0,
            .blendshape_buffer = null,
        };
    }

    // Upload all the bind poses
    const incoming_inverse_bind_poses: []align(1) const math.Matrix4x4f = @ptrCast(mesh_layout.inverse_bind_poses_buffer.slice(data));
    std.debug.assert(incoming_inverse_bind_poses.len == data_request.bone_count);

    const inverse_bind_poses = try gpa.alloc(math.Matrix4x4f, @intCast(data_request.bone_count));
    errdefer gpa.free(inverse_bind_poses);
    @memcpy(inverse_bind_poses, incoming_inverse_bind_poses);

    const bytes_per_vertex = @sizeOf(math.Vector4f) + @sizeOf(math.Vector4i);

    const bone_buffer = create_bone_buffer: {
        const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(.{
            .size = bytes_per_vertex * mesh_layout.num_vertices,
            .value = .upload,
        });
        defer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM");

        {
            const mapped_data = try frame_context.device.mapTransferBuffer(transfer_buffer_entry.value, true);
            defer frame_context.device.unmapTransferBuffer(transfer_buffer_entry.value);

            const vertices_bone_weights_start = @sizeOf(math.Vector4i) * mesh_layout.num_vertices;
            const vertices_bone_ids: []align(1) math.Vector4i = @ptrCast(mapped_data[0..vertices_bone_weights_start]);
            const vertices_bone_weights: []align(1) math.Vector4f = @ptrCast(mapped_data[vertices_bone_weights_start .. vertices_bone_weights_start + (@sizeOf(math.Vector4f) * mesh_layout.num_vertices)]);

            const bone_counts = mesh_layout.bone_counts_buffer.slice(data);
            std.debug.assert(bone_counts.len == mesh_layout.num_vertices);

            const bone_weights: []align(1) const shared.BoneWeight = @ptrCast(mesh_layout.bone_weights_buffer.slice(data));
            var bone_weight_ptr: [*]align(1) const shared.BoneWeight = bone_weights.ptr;
            for (bone_counts, vertices_bone_ids, vertices_bone_weights) |bone_count, *vertex_bone_ids, *vertex_bone_weights| {
                // TODO: actually handle bone counts over 4!
                const vertex_bone_weights_src: []align(1) const shared.BoneWeight = bone_weight_ptr[0..@min(bone_count, 4)];

                const vertex_bone_weights_array_dst: *align(1) [4]f32 = @ptrCast(vertex_bone_weights);
                @memset(vertex_bone_weights_array_dst, 0.0);
                const vertex_bone_ids_array_dst: *align(1) [4]i32 = @ptrCast(vertex_bone_ids);
                @memset(vertex_bone_ids_array_dst, 0);

                for (vertex_bone_weights_src, 0..) |weight, i| {
                    vertex_bone_weights_array_dst[i] = weight.weight;
                    vertex_bone_ids_array_dst[i] = weight.bone_index;
                }

                bone_weight_ptr += bone_count;
            }
        }

        const bone_buffer = try frame_context.device.createBuffer(.{
            .size = @intCast(transfer_buffer_entry.key.size),
            .usage = .{ .vertex = true },
        });
        errdefer frame_context.device.releaseBuffer(bone_buffer);

        const copy_pass = try frame_context.getSharedCopyPass();
        copy_pass.uploadToBuffer(.{
            .offset = 0,
            .transfer_buffer = transfer_buffer_entry.value,
        }, .{
            .buffer = bone_buffer,
            .offset = 0,
            .size = @intCast(transfer_buffer_entry.key.size),
        }, true);

        break :create_bone_buffer bone_buffer;
    };
    errdefer frame_context.device.releaseBuffer(bone_buffer);

    const blendshape_buffer = create_blendshape_buffer: {
        const buffer_size = mesh_layout.num_blendshapes * mesh_layout.num_vertices * @sizeOf(graphics.BlendshapeOffset);

        const transfer_buffer_entry = try frame_context.transfer_buffer_pool.acquire(.{
            .size = buffer_size,
            .value = .upload,
        });
        defer frame_context.transfer_buffer_pool.release(gpa, transfer_buffer_entry) catch @panic("OOM");

        {
            const mapped_data = try frame_context.device.mapTransferBuffer(transfer_buffer_entry.value, true);
            defer frame_context.device.unmapTransferBuffer(transfer_buffer_entry.value);

            // NOTE: these technically aren't bytes, but `0x00000000` as a float is `0.0`, so this is what we want!
            @memset(mapped_data[0..buffer_size], 0);

            const blendshape_buffer_src: []align(1) const math.Vector3f = @ptrCast(mesh_layout.blendshapes_buffer.slice(data));
            const final_offsets: []align(1) graphics.BlendshapeOffset = @ptrCast(mapped_data[0..buffer_size]);

            var chunks_read: u32 = 0;
            for (data_request.blendshape_buffers) |blendshape_buffer_descriptor| {
                const offset_start = @as(u32, @intCast(blendshape_buffer_descriptor.blendshape_index)) * mesh_layout.num_vertices;

                const blendshape_offsets_dst = final_offsets[offset_start .. offset_start + mesh_layout.num_vertices];

                // NOTE: Renderite.Unity appears to *always* look for the positions, so I've done so here aswell!
                if (blendshape_buffer_descriptor.data_flags.positions or true) {
                    const chunk = getChunk(blendshape_buffer_src, mesh_layout.num_vertices, &chunks_read);

                    for (chunk, blendshape_offsets_dst) |src_offset, *offset| {
                        offset.position_offset = src_offset;
                    }
                }

                // Copy in normal offsets, if present
                if (blendshape_buffer_descriptor.data_flags.normals) {
                    const chunk = getChunk(blendshape_buffer_src, mesh_layout.num_vertices, &chunks_read);

                    for (chunk, blendshape_offsets_dst) |src_offset, *offset| {
                        offset.normal_offset = src_offset;
                    }
                }

                // Copy in the tangent offsets, if present
                if (blendshape_buffer_descriptor.data_flags.tangets) {
                    const chunk = getChunk(blendshape_buffer_src, mesh_layout.num_vertices, &chunks_read);

                    for (chunk, blendshape_offsets_dst) |src_offset, *offset| {
                        offset.tangent_offset = src_offset;
                    }
                }
            }
        }

        const blendshape_buffer = try frame_context.device.createBuffer(.{
            .size = buffer_size,
            .usage = .{ .graphics_storage_read = true },
        });
        errdefer frame_context.device.releaseBuffer(blendshape_buffer);

        const copy_pass = try frame_context.getSharedCopyPass();
        copy_pass.uploadToBuffer(.{
            .offset = 0,
            .transfer_buffer = transfer_buffer_entry.value,
        }, .{
            .buffer = blendshape_buffer,
            .offset = 0,
            .size = buffer_size,
        }, true);

        break :create_blendshape_buffer blendshape_buffer;
    };
    errdefer frame_context.device.releaseBuffer(blendshape_buffer);

    return .{
        .bone_count = @intCast(data_request.bone_count),
        .inverse_bind_poses = inverse_bind_poses,
        .bone_buffer = bone_buffer,
        .ids_start_idx = 0,
        .weights_start_idx = @sizeOf(math.Vector4i) * mesh_layout.num_vertices,
        .blendshape_buffer = blendshape_buffer,
    };
}

/// Sets the data of a mesh, re-using buffers/memory when applicable.
pub fn setData(
    self: *Mesh,
    gpa: std.mem.Allocator,
    frame_context: *graphics.FrameContext,
    accessor: *renderite.buffer.SharedMemoryAccessor,
    data_request: shared.MeshUploadData,
) !void {
    log.trace(@src(), "Got mesh upload {any}", .{data_request});

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
    const vertex_attributes = try convertVertexAttributes(gpa, data_request.vertex_attributes);
    errdefer gpa.free(vertex_attributes);

    const skinning_data = try self.uploadSkinningData(
        gpa,
        frame_context,
        data_request,
        mesh_layout,
        data,
    );

    try frame_context.messaging_host.background.sendTimeout(.{
        .mesh_upload_result = .{
            .asset_id = data_request.asset_id,
            .instance_changed = true,
        },
    }, std.time.ns_per_s * 10);

    const nonce = frame_context.upload_nonce.fetchAdd(1, .seq_cst);

    self.* = .{
        .vertex_buffer = vertex_upload[0],
        .vertex_buffer_capacity = vertex_upload[1],
        .index_buffer = index_upload[0],
        .index_buffer_capacity = index_upload[1],
        .vertex_attributes = vertex_attributes,
        .submeshes = submeshes,
        .mesh_layout = mesh_layout,
        .skinning_data = skinning_data,
        .ready = false,
        .upload_nonce = nonce,
    };

    try frame_context.mesh_readiness_queue.append(gpa, .{
        .handle = .from(data_request.asset_id),
        .nonce = nonce,
    });
}

pub fn deinit(self: Mesh, gpa: std.mem.Allocator, device: gpu.Device) void {
    self.skinning_data.deinit(gpa, device);

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
    const num_vertices: u32 = @intCast(data_request.vertex_count);

    var idx: u32 = 0;

    var interleaved_vertex_stride: u32 = 0;
    for (data_request.vertex_attributes) |attribute| {
        const format = renderiteVertexAttributeDescriptorToVertexElementFormat(attribute) orelse return error.InvalidVertexAttributeDescriptor;

        interleaved_vertex_stride += format.stride();
    }

    idx += interleaved_vertex_stride * @as(u32, @intCast(data_request.vertex_count));

    const index_buffer_start = idx;
    var num_indices: u32 = 0;
    for (data_request.submeshes) |submesh| {
        num_indices = @max(num_indices, submesh.index_start + submesh.index_count);
    }

    const index_element_type = renderiteIndexBufferFormatToGpu(data_request.index_buffer_format);

    const index_buffer_byte_size = num_indices * index_element_type.byteSize();
    idx += index_buffer_byte_size;

    const bone_counts_buffer_byte_start = idx;
    const bone_counts_buffer_byte_size: u32 = @intCast(data_request.vertex_count);
    idx += bone_counts_buffer_byte_size;

    const bone_weights_buffer_byte_start = idx;
    const num_bone_weights: u32 = @intCast(data_request.bone_weight_count);
    const bone_weights_buffer_byte_size = num_bone_weights * @sizeOf(shared.BoneWeight);
    idx += bone_weights_buffer_byte_size;

    const bind_poses_buffer_byte_start = idx;
    const num_bones: u32 = @intCast(data_request.bone_count);
    const bind_poses_buffer_byte_size = num_bones * @sizeOf(math.Matrix4x4f);
    idx += bone_weights_buffer_byte_size;

    var num_blendshapes: u32 = 0;
    const blendshape_buffer_byte_start = idx;
    var blendshape_buffer_byte_size: u32 = 0;
    for (data_request.blendshape_buffers) |blendshape_buffer| {
        if (blendshape_buffer.data_flags.normals) {
            blendshape_buffer_byte_size += @sizeOf(math.Vector3f) * num_vertices;
        }
        if (blendshape_buffer.data_flags.positions) {
            blendshape_buffer_byte_size += @sizeOf(math.Vector3f) * num_vertices;
        }
        if (blendshape_buffer.data_flags.tangets) {
            blendshape_buffer_byte_size += @sizeOf(math.Vector3f) * num_vertices;
        }

        num_blendshapes = @max(num_blendshapes, @as(u32, @intCast(blendshape_buffer.blendshape_index + 1)));
    }

    return .{
        .vertex_buffer = .{ .byte_start = 0, .byte_end = index_buffer_start },
        .index_buffer = .{ .byte_start = index_buffer_start, .byte_end = index_buffer_start + index_buffer_byte_size },
        .bone_counts_buffer = .{ .byte_start = bone_counts_buffer_byte_start, .byte_end = bone_counts_buffer_byte_start + bone_counts_buffer_byte_size },
        .bone_weights_buffer = .{ .byte_start = bone_weights_buffer_byte_start, .byte_end = bone_counts_buffer_byte_start + bone_counts_buffer_byte_size },
        .inverse_bind_poses_buffer = .{ .byte_start = bind_poses_buffer_byte_start, .byte_end = bind_poses_buffer_byte_start + bind_poses_buffer_byte_size },
        .blendshapes_buffer = .{ .byte_start = blendshape_buffer_byte_start, .byte_end = blendshape_buffer_byte_start + blendshape_buffer_byte_size },
        .num_blendshapes = num_blendshapes,
        .interleaved_vertex_stride = interleaved_vertex_stride,
        .num_indices = num_indices,
        .num_vertices = num_vertices,
        .index_element_type = index_element_type,
    };
}

fn renderiteIndexBufferFormatToGpu(index_buffer_format: shared.IndexBufferFormat) gpu.IndexElementSize {
    return switch (index_buffer_format) {
        .u_int16 => .indices_16bit,
        .u_int32 => .indices_32bit,
    };
}

fn renderiteVertexAttributeDescriptorToVertexElementFormat(descriptor: shared.VertexAttributeDescriptor) ?gpu.VertexElementFormat {
    return switch (descriptor.format) {
        .float32 => switch (descriptor.dimensions) {
            1 => .f32x1,
            2 => .f32x2,
            3 => .f32x3,
            4 => .f32x4,
            else => null,
        },
        .half16 => switch (descriptor.dimensions) {
            1 => null,
            2 => .f16x2,
            3 => null,
            4 => .f16x4,
            else => null,
        },
        .s_int16 => switch (descriptor.dimensions) {
            1 => null,
            2 => .i16x2,
            3 => null,
            4 => .i16x4,
            else => null,
        },
        .s_int32 => switch (descriptor.dimensions) {
            1 => .i32x1,
            2 => .i32x2,
            3 => .i32x3,
            4 => .i32x4,
            else => null,
        },
        .s_int8 => switch (descriptor.dimensions) {
            1 => null,
            2 => .i8x2,
            3 => null,
            4 => .i8x4,
            else => null,
        },
        .u_int16 => switch (descriptor.dimensions) {
            1 => null,
            2 => .u16x2,
            3 => null,
            4 => .u16x4,
            else => null,
        },
        .u_int32 => switch (descriptor.dimensions) {
            1 => .u32x1,
            2 => .u32x2,
            3 => .u32x3,
            4 => .u32x4,
            else => null,
        },
        .u_int8 => switch (descriptor.dimensions) {
            1 => null,
            2 => .u8x2,
            3 => null,
            4 => .u8x4,
            else => null,
        },
        .u_norm16 => switch (descriptor.dimensions) {
            1 => null,
            2 => .u16x2_normalized,
            3 => null,
            4 => .u16x4_normalized,
            else => null,
        },
        .u_norm8 => switch (descriptor.dimensions) {
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
        .attribute = .position,
        .dimensions = 2,
        .format = .half16,
    }));

    try std.testing.expectEqual(gpu.VertexElementFormat.f32x3, renderiteVertexAttributeDescriptorToVertexElementFormat(.{
        .attribute = .position,
        .dimensions = 3,
        .format = .float32,
    }));

    try std.testing.expectEqual(gpu.VertexElementFormat.i16x2, renderiteVertexAttributeDescriptorToVertexElementFormat(.{
        .attribute = .position,
        .dimensions = 2,
        .format = .s_int16,
    }));
}

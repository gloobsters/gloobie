pub const StageData = struct {
    num_samplers: u32,
    num_uniform_buffers: u32,
    num_storage_textures: u32,
    num_storage_buffers: u32,
};
pub const ComputeData = struct {
    num_samplers: u32,
    num_readonly_storage_textures: u32,
    num_readonly_storage_buffers: u32,
    num_readwrite_storage_textures: u32,
    num_readwrite_storage_buffers: u32,
    num_uniform_buffers: u32,
    threadcount_x: u32,
    threadcount_y: u32,
    threadcount_z: u32,
};
pub const Shader = struct {
    spirv: []const u8,
    dxil: []const u8,
    metal: []const u8,

    vertex_stage: StageData,
    fragment_stage: StageData,
    compute_stage: ComputeData,
};

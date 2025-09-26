#language slang 2026

struct Vertex
{
    float3 position : POSITION;
    int4 bone_ids : BONE_IDS;           // Added bone IDs for skinned animation
    float4 bone_weights : BONE_WEIGHTS; // Added bone weights for skinned animation
};

struct FragmentStageInput
{
    float4 color : COLOR;
}

struct VertexStageOutput
{
    FragmentStageInput frag_input : FragmentStageInput;
    float4 position : SV_Position;
};

struct RenderData
{
    float4x4 view_matrix;
    float4x4 projection_matrix;
}

struct ModelData
{
    float4x4 model_matrix;
    uint32_t num_vertices;
    uint32_t num_blendshapes;
}

struct BlendshapeOffset
{
    float3 position_offset;
    float3 normal_offset;
    float3 tangent_offset;
}

[vk::binding(0, 0)]
StructuredBuffer<int32_t> skinning_matrices;
[vk::binding(1, 0)]
StructuredBuffer<BlendshapeOffset> vertex_offsets;
[vk::binding(2, 0)]
StructuredBuffer<float> blendshape_weights;

[vk::binding(0, 1)]
ConstantBuffer<RenderData> render_data;
[vk::binding(1, 1)]
ConstantBuffer<ModelData> model_data;

#define MAX_BONE_INFLUENCES 4

[shader("vertex")]
VertexStageOutput vertexMain(Vertex vertex, uint vertex_id: SV_VertexID)
{
    VertexStageOutput output;

    float3 vertex_position = vertex.position;

    // Apply blendshape offsets
    for (uint32_t blendshape_index = 0; blendshape_index < model_data.num_blendshapes; blendshape_index++)
    {
        float weight = blendshape_weights[blendshape_index];

        BlendshapeOffset offset = vertex_offsets[(blendshape_index * model_data.num_vertices) + vertex_id];

        vertex_position.xyz += offset.position_offset * weight;
    }

    // Apply bone transformations
    float3 skinned_position = float3(0.0, 0.0, 0.0);
    for (int i = 0; i < MAX_BONE_INFLUENCES; i++)
    {
        // NOTE: for an invalid bone_id (which can in theory be any value but will be 0 in practice), we rely on the weight being 0.0 aswell
        //       this let's us avoid branching, i didnt do the performance checks but i don't imagine it can be *that* much worse. and it probably is better.
        int bone_id = vertex.bone_ids[i];
        float weight = vertex.bone_weights[i];

        float4x4 skinning_matrix = skinning_matrices[bone_id];
        skinned_position += mul(skinning_matrix, float4(vertex.position, 1.0)).xyz * weight;
    }

    output.position = mul(model_data.model_matrix * render_data.view_matrix * render_data.projection_matrix, float4(skinned_position, 1.0));
    output.frag_input.color = float4((vertex.position.x * 10.0) % 1.0, (vertex.position.y * 10.0) % 1.0, (vertex.position.z * 10.0) % 1.0, 1.0); // test nonsense

    return output;
}

[shader("fragment")]
float4 fragmentMain(FragmentStageInput input: FragmentStageInput)
    : SV_Target
{
    return input.color;
}

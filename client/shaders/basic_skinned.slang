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
}

[[vk_binding(1, 0)]]
StructuredBuffer<float4x4> bone_matrices; // Buffer for bone matrices

[[vk_binding(0, 1)]]
ConstantBuffer<RenderData> render_data;
[[vk_binding(1, 1)]]
ConstantBuffer<ModelData> model_data;

[shader("vertex")]
VertexStageOutput vertexMain(Vertex vertex)
{
    VertexStageOutput output;

    float4 transformed_position = float4(0.0f);
    for (int i = 0; i < 4; i++)
    {
        if (vertex.bone_ids[i] == -1)
            continue;

        float4 local_position = mul(bone_matrices[vertex.bone_ids[i]], float4(vertex.position, 1.0f));
        transformed_position += local_position * vertex.bone_weights[i];
    }

    output.position = mul(model_data.model_matrix * render_data.view_matrix * render_data.projection_matrix, transformed_position);
    output.frag_input.color = float4((vertex.position.x * 10.0) % 1.0, (vertex.position.y * 10.0) % 1.0, (vertex.position.z * 10.0) % 1.0, 1.0); // test nonsense

    return output;
}

[shader("fragment")]
float4 fragmentMain(FragmentStageInput input: FragmentStageInput)
    : SV_Target
{
    return input.color;
}

#language slang 2026

module basic;

struct Vertex
{
    float3 position : POSITION;
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
    int32_t model_matrix_idx;
}

[vk::binding(0, 0)]
StructuredBuffer<float4x4> transform_matrices;

[vk::binding(0, 1)]
ConstantBuffer<RenderData> render_data;
[vk::binding(1, 1)]
ConstantBuffer<ModelData> model_data;

[shader("vertex")]
VertexStageOutput vertexMain(Vertex vertex)
{
    VertexStageOutput output;

    float4x4 model_matrix = transform_matrices[model_data.model_matrix_idx];

    output.position = mul(model_matrix * render_data.view_matrix * render_data.projection_matrix, float4(vertex.position, 1.0));
    output.frag_input.color = float4((vertex.position.x * 10.0) % 1.0, (vertex.position.y * 10.0) % 1.0, (vertex.position.z * 10.0) % 1.0, 1.0); // test nonsense

    return output;
}

[shader("fragment")]
float4 fragmentMain(FragmentStageInput input)
    : SV_Target
{
    return input.color;
}

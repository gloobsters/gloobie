typedef float4x4 mat4;

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
    mat4 render_matrix;
}

struct ModelData
{
    mat4 model_matrix;
}

[[vk_binding(0, 1)]]
ConstantBuffer<RenderData> render_data;
[[vk_binding(1, 1)]]
ConstantBuffer<ModelData> model_data;

[shader("vertex")]
VertexStageOutput vertexMain(Vertex vertex)
{
    VertexStageOutput output;

    output.frag_input.color = float4(1.0, 0.0, 0.0, 1.0); // Red color
    output.position = mul(mul(render_data.render_matrix, model_data.model_matrix), float4(vertex.position, 1.0));

    return output;
}

[shader("fragment")]
float4 fragmentMain(FragmentStageInput input: FragmentStageInput)
    : SV_Target
{
    return input.color;
}

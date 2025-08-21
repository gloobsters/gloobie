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
    mat4 view_matrix;
    mat4 projection_matrix;
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

    output.position = mul(model_data.model_matrix * render_data.view_matrix * render_data.projection_matrix, float4(vertex.position, 1.0));
    output.frag_input.color = float4((vertex.position.x * 10.0) % 1.0, (vertex.position.y * 10.0) % 1.0, (vertex.position.z * 10.0) % 1.0, 1.0); // test nonsense

    return output;
}

[shader("fragment")]
float4 fragmentMain(FragmentStageInput input: FragmentStageInput)
    : SV_Target
{
    return input.color;
}

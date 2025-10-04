#language slang 2026

module basic;

import materials;
import common;

struct FragmentStageInput
{
    Vertex vertex : VERTEX;
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

// Transform matrices
[vk::binding(0, 0)]
StructuredBuffer<float4x4> transform_matrices;
// Skinning data
[vk::binding(1, 0)]
Conditional<StructuredBuffer<BlendshapeOffset>, g_skinning> vertex_offsets;
[vk::binding(2, 0)]
Conditional<StructuredBuffer<float>, g_skinning> blendshape_weights;

[vk::binding(0, 1)]
ConstantBuffer<RenderData> render_data;
[vk::binding(1, 1)]
ConstantBuffer<ModelData> model_data;

[shader("vertex")]
VertexStageOutput vertexMain(Vertex vertex)
{
    VertexStageOutput output;
    output.frag_input.vertex = vertex;

    float4x4 model_matrix = transform_matrices[model_data.model_matrix_index];

    // Apply skinning if enabled
    if (g_skinning)
    {
        vertex = applySkinning(
            vertex,
            model_data,
            vertex_offsets.get().value,
            blendshape_weights.get().value,
            transform_matrices);
    }

    float4x4 mvp = mul(render_data.projection_matrix, mul(render_data.view_matrix, model_matrix));

    output.position = mul(mvp, float4(vertex.position, 1.0));

    return output;
}

[shader("fragment")]
float4 fragmentMain(FragmentStageInput input)
    : SV_Target
{
    TestMaterial mat = TestMaterial(input.vertex.position);

    return mat.eval();
}

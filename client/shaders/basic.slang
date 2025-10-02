#language slang 2026

module basic;

import materials;
import common;

extern struct Material : IMaterial = TestMaterial;

struct FragmentStageInput
{
    float4 color : COLOR;
}

struct VertexStageOutput
{
    FragmentStageInput fragInput : FragmentStageInput;
    float4 position : SV_Position;
};

struct RenderData
{
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
}

struct ModelData
{
    int32_t modelMatrixIdx;
}

[vk::binding(0, 0)]
StructuredBuffer<float4x4> transformMatrices;

[vk::binding(0, 1)]
ConstantBuffer<RenderData> renderData;
[vk::binding(1, 1)]
ConstantBuffer<ModelData> modelData;

[shader("vertex")]
VertexStageOutput vertexMain(Vertex vertex)
{
    VertexStageOutput output;

    float4x4 modelMatrix = transformMatrices[modelData.modelMatrixIdx];

    float4x4 mvp = mul(renderData.projectionMatrix, mul(renderData.viewMatrix, modelMatrix));

    Material mat = Material();

    output.position = mul(mvp, float4(vertex.position, 1.0));
    output.fragInput.color = mat.eval(vertex);

    return output;
}

[shader("fragment")]
float4 fragmentMain(FragmentStageInput input)
    : SV_Target
{
    return input.color;
}

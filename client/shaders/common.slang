#language slang 2026

module common;

public extern static const bool g_has_normal = false;
public extern static const bool g_has_tangent = false;
public extern static const bool g_has_color = false;

public extern static const bool g_has_uv0 = false;
public extern static const bool g_has_uv1 = false;
public extern static const bool g_has_uv2 = false;
public extern static const bool g_has_uv3 = false;
public extern static const bool g_has_uv4 = false;
public extern static const bool g_has_uv5 = false;
public extern static const bool g_has_uv6 = false;
public extern static const bool g_has_uv7 = false;

// Whether skinning is enabled for this shader
public extern static const bool g_skinning = false;

public struct Vertex
{
    uint vertex_id : SV_VulkanVertexID;

    public float3 position : POSITION;

    public Conditional<float3, g_has_normal> normal : NORMAL;
    public Conditional<float3, g_has_tangent> tangent : TANGENT;
    public Conditional<float4, g_has_color> color : COLOR;

    public Conditional<float2, g_has_uv0> uv0 : TEXCOORD0;
    public Conditional<float2, g_has_uv1> uv1 : TEXCOORD1;
    public Conditional<float2, g_has_uv2> uv2 : TEXCOORD2;
    public Conditional<float2, g_has_uv3> uv3 : TEXCOORD3;
    public Conditional<float2, g_has_uv4> uv4 : TEXCOORD4;
    public Conditional<float2, g_has_uv5> uv5 : TEXCOORD5;
    public Conditional<float2, g_has_uv6> uv6 : TEXCOORD6;
    public Conditional<float2, g_has_uv7> uv7 : TEXCOORD7;

    public Conditional<float4, g_skinning> bone_weights : BONE_WEIGHTS;
    public Conditional<int4, g_skinning> bone_indices : BONE_IDS;
};

public struct ModelData
{
    public struct SkinningData
    {
        public uint32_t num_vertices;
        public uint32_t num_blendshapes;
    };

    public int32_t model_matrix_index;
    public Conditional<SkinningData, g_skinning> skinning_data;
};

public struct BlendshapeOffset
{
    float3 position_offset;
    Conditional<float3, g_has_normal> normal_offset;
    Conditional<float3, g_has_tangent> tangent_offset;
}

public static Vertex applySkinning(
    Vertex in_vertex,
    const ModelData model_data,
    const StructuredBuffer<BlendshapeOffset> blendshape_offsets,
    const StructuredBuffer<float> blendshape_weights,
    const StructuredBuffer<float4x4> transform_matrices)
{
    // If the vertex doesn't have bone weights or indices, return it unchanged
    if (!g_skinning)
    {
        return in_vertex;
    }

    var vertex = in_vertex;

    let skinning_data = model_data.skinning_data.get().value;

    for (uint32_t blendshape_index = 0; blendshape_index < skinning_data.num_blendshapes; blendshape_index++)
    {
        float weight = blendshape_weights[blendshape_index];
        BlendshapeOffset offset = blendshape_offsets[(blendshape_index * skinning_data.num_vertices) + vertex.vertex_id];

        vertex.position += offset.position_offset * weight;

        if (let normal_offset = offset.normal_offset.get())
        {
            float3 normal = vertex.normal.get().value + (normal_offset * weight);

            vertex.normal.set(normal);
        }

        if (let tangent_offset = offset.tangent_offset.get())
        {
            float3 tangent = vertex.tangent.get().value + (tangent_offset * weight);

            vertex.tangent.set(tangent);
        }
    }

    float4 weights = vertex.bone_weights.get().value;
    int4 indices = vertex.bone_indices.get().value;

    float4x4 skin_matrix =
        transform_matrices[indices.x] * weights.x +
        transform_matrices[indices.y] * weights.y +
        transform_matrices[indices.z] * weights.z +
        transform_matrices[indices.w] * weights.w;

    vertex.position = mul(skin_matrix, float4(vertex.position, 1.0)).xyz;

    if (g_has_normal)
    {
        float3 normal = vertex.normal.get().value;
        normal = normalize(mul(float3x3(skin_matrix), normal));
        vertex.normal.set(normal);
    }

    if (g_has_tangent)
    {
        float3 tangent = vertex.tangent.get().value;
        tangent = normalize(mul(float3x3(skin_matrix), tangent));
        vertex.tangent.set(tangent);
    }

    return vertex;
}

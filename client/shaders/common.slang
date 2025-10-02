#language slang 2026

module common;

extern static const bool hasNormal = false;
extern static const bool hasTangent = false;
extern static const bool hasColor = false;

extern static const bool hasUV0 = false;
extern static const bool hasUV1 = false;
extern static const bool hasUV2 = false;
extern static const bool hasUV3 = false;
extern static const bool hasUV4 = false;
extern static const bool hasUV5 = false;
extern static const bool hasUV6 = false;
extern static const bool hasUV7 = false;

extern static const bool hasBoneWeights = false;
extern static const bool hasBoneIndices = false;

public struct Vertex
{
    public float3 position : POSITION;

    public Conditional<float3, hasNormal> normal : NORMAL;
    public Conditional<float3, hasTangent> tangent : TANGENT;
    public Conditional<float4, hasColor> color : COLOR;

    public Conditional<float2, hasUV0> uv0 : TEXCOORD0;
    public Conditional<float2, hasUV1> uv1 : TEXCOORD1;
    public Conditional<float2, hasUV2> uv2 : TEXCOORD2;
    public Conditional<float2, hasUV3> uv3 : TEXCOORD3;
    public Conditional<float2, hasUV4> uv4 : TEXCOORD4;
    public Conditional<float2, hasUV5> uv5 : TEXCOORD5;
    public Conditional<float2, hasUV6> uv6 : TEXCOORD6;
    public Conditional<float2, hasUV7> uv7 : TEXCOORD7;

    public Conditional<float4, hasBoneWeights> boneWeights : BONE_WEIGHTS;
    public Conditional<int4, hasBoneIndices> boneIndices : BONE_IDS;
};

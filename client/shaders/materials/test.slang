#language slang 2026

implementing materials;

public struct TestMaterial : IMaterial
{
    public float4 eval(Vertex vertex)
    {
        return abs(float4((vertex.position.x * 10.0) % 1.0, (vertex.position.y * 10.0) % 1.0, (vertex.position.z * 10.0) % 1.0, 1.0));
    }
}

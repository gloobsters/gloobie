#language slang 2026

implementing materials;

public struct TestMaterial : IMaterial
{
    public float3 eval()
    {
        return float3(1, 0, 0);
    }
}

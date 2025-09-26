#language slang 2026

implementing materials;

public struct TestMaterial : IMaterial
{
    float3 eval()
    {
        return float3(1, 0, 0);
    }
}

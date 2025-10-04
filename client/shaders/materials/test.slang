#language slang 2026

implementing materials;

public struct TestMaterial : IMaterial
{
    public float3 position;

    public __init(float3 position)
    {
        this.position = position / 1.0;
    }

    public float4 eval()
    {
        return abs(float4(this.position.x % 1.0, this.position.y % 1.0, this.position.z % 1.0, 1.0));
    }
}

#language slang 2026

module materials;

__include "test.slang";

public interface IMaterial
{
    float3 eval();
}

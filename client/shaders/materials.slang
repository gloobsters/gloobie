#language slang 2026

module materials;

import common;

__include "materials/test.slang";

public interface IMaterial
{
    public float4 eval(Vertex vertex);
}

using System.Reflection;

namespace RenderiteGenerator;

public struct EnumInfo
{
    public string Name;
    public int BitSize;
    public Type UnderlyingType;
    public List<EnumItemInfo> Items;
}
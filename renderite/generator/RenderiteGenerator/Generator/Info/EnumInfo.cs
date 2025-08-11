namespace RenderiteGenerator.Generator.Info;

public struct EnumInfo
{
    public string Name;
    public int BitSize;
    public Type UnderlyingType;
    public List<EnumItemInfo> Items;
}
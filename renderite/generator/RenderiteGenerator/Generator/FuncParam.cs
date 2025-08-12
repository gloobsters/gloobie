namespace RenderiteGenerator.Generator;

public class FuncParam
{
    public string Name;
    public string Type;

    public FuncParam(string name, string type)
    {
        Name = name;
        Type = type;
    }

    public override string ToString()
    {
        return $"{this.Name}: {this.Type}";
    }
}
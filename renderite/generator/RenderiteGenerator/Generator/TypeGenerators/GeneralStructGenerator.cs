using System.Reflection;

namespace RenderiteGenerator.Generator.TypeGenerators;

public class GeneralStructGenerator : StructGenerator
{
    public GeneralStructGenerator(GeneratorContext context) : base(context)
    {
    }

    public override bool CanGenerateType(Type type)
    {
        return type.IsValueType && !type.IsEnum;
    }

    protected override bool Packable => false;

    public override bool Pack(Type t, Writer w, FieldInfo[] fields, bool write)
    {
        return false;
    }
}
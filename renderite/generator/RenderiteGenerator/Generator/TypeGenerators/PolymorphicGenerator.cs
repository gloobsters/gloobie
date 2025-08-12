namespace RenderiteGenerator.Generator.TypeGenerators;

public class PolymorphicGenerator : TypeGenerator
{
    private readonly Type _polymorphicType;

    public PolymorphicGenerator(GeneratorContext context) : base(context)
    {
        this._polymorphicType = context.Types.First(t => t.Name == "PolymorphicMemoryPackableEntity`1").GetGenericTypeDefinition();
    }

    public override void Generate(Type type, GeneratorContext context, Writer w)
    {
        w.Note(type.Name);
    }

    public override bool CanGenerateType(Type type)
    {
        if (type.BaseType is not { IsGenericType: true })
            return false;
        return type.BaseType.GetGenericTypeDefinition() == this._polymorphicType;
    }
}
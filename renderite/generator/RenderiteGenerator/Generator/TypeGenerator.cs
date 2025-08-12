namespace RenderiteGenerator.Generator;

public abstract class TypeGenerator
{
    protected GeneratorContext Context;

    protected TypeGenerator(GeneratorContext context)
    {
        Context = context;
    }

    public abstract void Generate(Type type, GeneratorContext context, Writer w);
    public abstract bool CanGenerateType(Type type);
}
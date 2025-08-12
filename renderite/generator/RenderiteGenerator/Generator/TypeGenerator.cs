namespace RenderiteGenerator.Generator;

public abstract class TypeGenerator
{
    protected GeneratorContext Context;

    protected TypeGenerator(GeneratorContext context)
    {
        this.Context = context;
    }

    public abstract void Generate(Type type, Writer w);
    public abstract bool CanGenerateType(Type type);
}
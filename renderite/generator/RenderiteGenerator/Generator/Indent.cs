namespace RenderiteGenerator.Generator;

public class Indent : IDisposable
{
    private readonly GeneratorContext _context;

    public Indent(GeneratorContext context)
    {
        this._context = context;
        context.CurrentIndent++;
    }

    public void Dispose()
    {
        this._context.CurrentIndent--;
    }
}
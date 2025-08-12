namespace RenderiteGenerator.Generator.Blocks;

public class Indent : IDisposable
{
    private readonly GeneratorContext _context;
    protected readonly Writer Writer;

    public Indent(Writer writer)
    {
        this.Writer = writer;
        this._context = writer.Context;
        this._context.CurrentIndent += 1;
    }

    public virtual void Dispose()
    {
        this._context.CurrentIndent--;
    }
}
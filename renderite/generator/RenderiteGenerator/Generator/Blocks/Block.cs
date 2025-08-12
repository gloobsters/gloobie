namespace RenderiteGenerator.Generator;

public class Block : Indent
{
    public Block(Writer writer) : base(writer)
    {}

    public override void Dispose()
    {
        base.Dispose();
        this.Writer.CloseBlock();
    }
}
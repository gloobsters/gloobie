namespace RenderiteGenerator.Generator.Blocks;

public class Block : Indent
{
    private readonly bool _endWithSemicolon;

    public Block(Writer writer, bool endWithSemicolon = true) : base(writer)
    {
        this._endWithSemicolon = endWithSemicolon;
    }

    public override void Dispose()
    {
        base.Dispose();
        this.Writer.CloseBlock(this._endWithSemicolon);
    }
}
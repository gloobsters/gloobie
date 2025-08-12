namespace RenderiteGenerator.Generator;

public class Writer : IDisposable
{
    private readonly Stream _fileStream;
    private readonly StreamWriter _writer;

    internal GeneratorContext Context;

    public Writer(GeneratorContext context, string path)
    {
        this.Context = context;
        this._fileStream = File.OpenWrite(path);
        this._writer = new StreamWriter(this._fileStream);
    }

    private void Indents()
    {
        for (int i = 0; i < this.Context.CurrentIndent; i++)
            this._writer.Write("    ");
    }

    private void Comment(string type, string comment)
    {
        this.Indents();
        this._writer.Write("// ");
        this._writer.Write(type);
        this._writer.Write(": ");
        this._writer.WriteLine(comment);
    }
    
    public void Comment(string comment)
    {
        this.Indents();
        this._writer.Write("// ");
        this._writer.WriteLine(comment);
    }

    public void Fixme(string comment) => this.Comment("FIXME", comment);
    public void Bug(string comment) => this.Comment("BUG", comment);
    public void Todo(string comment) => this.Comment("TODO", comment);
    public void Note(string comment) => this.Comment("NOTE", comment);

    public void Any(string line)
    {
        this.Indents();
        this._writer.WriteLine(line);
    }

    public void Line() => this._writer.WriteLine();
    
    public void ImportZig(string name)
    {
        this.Indents();
        this._writer.Write("const ");
        this._writer.Write(name);
        this._writer.Write(" = ");
        this._writer.Write("@import(\"");
        this._writer.Write(name);
        this._writer.WriteLine(".zig\");");
    }
    
    public void Import(string name)
    {
        this.Indents();
        this._writer.Write("const ");
        this._writer.Write(name);
        this._writer.Write(" = ");
        this._writer.Write("@import(\"");
        this._writer.Write(name);
        this._writer.WriteLine("\");");
    }

    public void Import(string name, string from)
    {
        this.Indents();
        this._writer.Write("const ");
        this._writer.Write(name);
        this._writer.Write(" = ");
        this._writer.Write("@import(\"");
        this._writer.Write(from);
        this._writer.WriteLine("\");");
    }
    
    public void Define(string name, string from)
    {
        this.Indents();
        this._writer.Write("const ");
        this._writer.Write(name);
        this._writer.Write(" = ");
        this._writer.Write(from);
        this._writer.Write('.');
        this._writer.Write(name);
        this._writer.WriteLine(";");
    }
    
    private void PubEql(string name)
    {
        this.Indents();
        this._writer.Write("pub const ");
        this._writer.Write(name);
        this._writer.Write(" = ");
    }

    public void Dispose()
    {
        this._writer.Flush();
        this._fileStream.Flush();
        
        this._writer.Dispose();
        this._fileStream.Dispose();
        GC.SuppressFinalize(this);
    }
    

    public Block BeginEnum(string name, string type)
    {
        this.Indents();
        this.PubEql(name);
        this._writer.Write("enum(");
        this._writer.Write(type);
        this._writer.Write(") {");
        return new Block(this);
    }

    public void EnumMember(string name)
    {
        this.Indents();
        this._writer.Write(name);
        this._writer.WriteLine(',');
    }
    
    public Block BeginUnion(string name)
    {
        this.Indents();
        this.PubEql(name);
        this._writer.Write("union(");
        this._writer.Write(name);
        this._writer.Write("Types) {");
        return new Block(this);
    }

    public void StructMember(string name, string type)
    {
        this.Indents();
        this._writer.Write(name);
        this._writer.Write(": ");
        this._writer.Write(type);
        this._writer.WriteLine(',');
    }

    public void CloseBlock()
    {
        this._writer.WriteLine("};");
    }
}
using System.Reflection;
using RenderiteGenerator.Generator.Blocks;

namespace RenderiteGenerator.Generator.TypeGenerators;

public abstract class StructGenerator : TypeGenerator
{
    protected StructGenerator(GeneratorContext context) : base(context)
    {}
    
    public override void Generate(Type type, Writer w)
    {
        using Block _ = this.BeginStruct(w, type.Name);

        FieldInfo[] fields = type.GetFields(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);

        foreach (FieldInfo field in fields)
        {
            w.StructMember(field.Name, MapToZigType(field.FieldType));
        }

        if (this.Packable && fields.Length > 0)
        {
            // ReSharper disable once RedundantAssignment
            bool generated = false;
        
            w.Line();
            using (Block __ = w.BeginFunction("write", "!void", new FuncParam("self", type.Name), new FuncParam("ipc", "IpcSerializer")))
            {
                generated = Pack(type, w, fields, true);
                if(!generated) WritePackDiscard(true, w);
            }
            
            using (Block __ = w.BeginFunction("read", $"!{type.Name}", new FuncParam("ipc", "IpcDeserializer")))
            {
                w.Any($"var self: {type.Name} = undefined;");
                generated = Pack(type, w, fields, false);
                if(!generated) WritePackDiscard(false, w);
                w.Any("return self;");
            }
        }
        
        this.PackFinish(type, w, fields);
    }

    protected virtual bool Packable => true;

    public abstract bool Pack(Type t, Writer w, FieldInfo[] fields, bool write);
    public virtual void PackFinish(Type t, Writer w, FieldInfo[] fields) {}

    public virtual Block BeginStruct(Writer w, string name)
    {
        return w.BeginStruct(name);
    }
    
    protected void WritePackDiscard(bool write, Writer w)
    {
        if (write)
            w.Any("_ = self;");
        else
            w.Any("_ = &self; // FIXME: Type not generating any members");

        w.Any("_ = ipc;");
    }
}
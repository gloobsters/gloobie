using System.Reflection;
using RenderiteGenerator.Generator.Blocks;

namespace RenderiteGenerator.Generator.TypeGenerators;

public class PackableGenerator : TypeGenerator
{
    private readonly Type _iMemoryPackable;

    public PackableGenerator(GeneratorContext context) : base(context)
    {
        this._iMemoryPackable = context.Types.First(t => t.Name == "IMemoryPackable");
    }

    public override void Generate(Type type, Writer w)
    {
        using Block _ = w.BeginStruct(type.Name);

        FieldInfo[] fields = type.GetFields();
        foreach (FieldInfo field in fields)
        {
            w.StructMember(field.Name, MapToZigType(field.FieldType));
        }

        if (fields.Length > 0)
        {
            // ReSharper disable once RedundantAssignment
            bool generated = false;
        
            w.Line();
            using (Block __ = w.BeginFunction("write", "!void", new FuncParam("self", type.Name), new FuncParam("ipc", "IpcSerializer")))
            {
                // generated = WritePackFunction(type, type.GetMethod("Pack")!);
                // if(!generated) WritePackDiscard();
            }
            
            using (Block __ = w.BeginFunction("read", $"!{type.Name}", new FuncParam("self", type.Name), new FuncParam("ipc", "IpcDeserializer")))
            {
                w.Any($"var self: {type.Name} = undefined;");
                // generated = WritePackFunction(type, type.GetMethod("Pack")!);
                // if(!generated) WritePackDiscard();
                w.Any("return self;");
            }
        }
    }

    public override bool CanGenerateType(Type type)
    {
        return type != this._iMemoryPackable && !type.IsAbstract && type.IsAssignableTo(this._iMemoryPackable);
    }
}
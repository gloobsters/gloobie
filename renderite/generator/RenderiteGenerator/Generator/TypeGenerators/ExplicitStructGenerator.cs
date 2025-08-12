using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using RenderiteGenerator.Generator.Blocks;

namespace RenderiteGenerator.Generator.TypeGenerators;

public class ExplicitStructGenerator : StructGenerator
{
    public ExplicitStructGenerator(GeneratorContext context) : base(context)
    {}
    
    public override bool Pack(Type t, Writer w, FieldInfo[] fields, bool write) => WriteExplicitPackFunction(t, fields, w, !write);
    
    public override Block BeginStruct(Writer w, string name)
    {
        return w.BeginExternStruct(name);
    }

    public override bool CanGenerateType(Type type)
    {
        return (type.Attributes & TypeAttributes.ExplicitLayout) != 0;
    }

    private bool WriteExplicitPackFunction(Type type, FieldInfo[] fields, Writer w, bool read)
    {
        const bool ipcStruct = false;
        
        int last = 0;
        bool written = false;
        foreach (FieldInfo field in fields)
        {
            FieldOffsetAttribute? offset = field.GetCustomAttribute<FieldOffsetAttribute>();
            Debug.Assert(offset != null);

            Type fieldType = field.FieldType;
            if (fieldType.IsEnum)
            {
                FieldInfo valueField = fieldType.GetField("value__")!;
                fieldType = valueField.FieldType;
            }

            int size = Marshal.SizeOf(fieldType);
            int gap = offset.Value - last;

            if (gap != 0) w.Note($"field with gap/overlap, {field.Name} = offset:{offset.Value}, size:{size}, gap:{gap}");

            string name = field.Name;

            if (!ipcStruct)
            {
                if (read)
                    w.Any($"self.{name} = try ipc.read(@TypeOf(self.{name}));");
                else
                    w.Any($"try ipc.write(@TypeOf(self.{name}), self.{name});");

                written = true;
            }
            
            last = offset.Value + size;
        }

        if (ipcStruct)
        {
            if(read)
                w.Any($"self = try ipc.readStruct({type.Name});");
            else
                w.Any($"try ipc.writeStruct({type.Name}, self);");

            written = true;
        }

        return written;
    }
}
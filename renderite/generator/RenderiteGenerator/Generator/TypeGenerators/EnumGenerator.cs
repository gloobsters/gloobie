using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using RenderiteGenerator.Generator.Blocks;
using RenderiteGenerator.Generator.Info;

namespace RenderiteGenerator.Generator.TypeGenerators;

public class EnumGenerator : TypeGenerator
{
    public EnumGenerator(GeneratorContext context) : base(context)
    {}

    public override void Generate(Type type, Writer w)
    {
        FieldInfo valueField = type.GetField("value__")!;
        Type underlyingType = valueField.FieldType;

        Array values = Enum.GetValues(type);

        EnumInfo info = new()
        {
            Name = type.Name,
            UnderlyingType = underlyingType,
            BitSize = Marshal.SizeOf(underlyingType) * 8,
        };
        
        if (type.DeclaringType != null)
        {
            info.Name = type.DeclaringType.Name + '_' + info.Name;
        }

        List<EnumItemInfo> itemInfo = [];
        foreach (object value in values)
        {
            string? name = value.ToString();
            Debug.Assert(name != null);

            if(itemInfo.Any(i => i.Name == name))
                continue;

            // workaround for enums that aren't int. this effectively casts to the underlying enum type
            object? num = valueField.GetValue(value);
            Debug.Assert(num != null);

            itemInfo.Add(new EnumItemInfo
            {
                Name = name,
                Value = num,
            });
        }

        info.Items = itemInfo;
        
        bool flags = type.GetCustomAttribute<FlagsAttribute>() != null;

        if(flags)
            WriteFlagEnum(w, info);
        else
            WriteValueEnum(w, info);
    }
    
    private void WriteFlagEnum(Writer w, EnumInfo info)
    {
        using Block _ = w.BeginPackedStruct(info.Name, MapToZigType(info.UnderlyingType));
        int bits = info.BitSize;
        foreach (EnumItemInfo value in info.Items)
        {
            if (Convert.ToInt32(value.Value) == 0)
            {
                w.Note($"\t// Skipped {value.Name}");
                continue;
            }
            
            w.StructMember(value.Name, "bool");
            bits--;
        }

        if (bits != 0)
            w.StructMember("padding", $"u{bits}", "0");
    }
    
    private void WriteValueEnum(Writer w, EnumInfo info)
    {
        using Block _ = w.BeginEnum(info.Name, MapToZigType(info.UnderlyingType));

        foreach (EnumItemInfo value in info.Items)
        {
            w.EnumMember(value.Name, value.Value.ToString()!);
        }
    }

    public override bool CanGenerateType(Type type)
    {
        return type.IsEnum;
    }
}
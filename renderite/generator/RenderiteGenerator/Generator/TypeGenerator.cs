using System.Collections;

namespace RenderiteGenerator.Generator;

public abstract class TypeGenerator
{
    protected readonly GeneratorContext Context;

    protected TypeGenerator(GeneratorContext context)
    {
        this.Context = context;
    }

    public abstract void Generate(Type type, Writer w);
    public abstract bool CanGenerateType(Type type);
    
    protected string MapToZigType(Type type, bool inList = false)
    {
        if (type == typeof(string))
            return "[]const u16";
        
        if (type == typeof(byte))
            return "u8";
        if (type == typeof(sbyte))
            return "i8";
        
        if (type == typeof(short))
            return "i16";
        if (type == typeof(ushort))
            return "u16";
        
        if (type == typeof(int))
            return "i32";
        if (type == typeof(uint))
            return "u32";
        
        if (type == typeof(long))
            return "i64";
        if (type == typeof(ulong))
            return "u64";
        
        if (type == typeof(Int128))
            return "i128";
        if (type == typeof(UInt128))
            return "u128";

        if (type == typeof(float))
            return "f32";
        if (type == typeof(double))
            return "f64";

        if (type == typeof(bool))
            return "bool";

        if (type == typeof(DateTime))
            return "i128";

        switch (type.Name)
        {
            case "RenderVector2":
                return "math.Vector2f";
            case "RenderVector2i":
                return "math.Vector2i";
            case "RenderVector3":
                return "math.Vector3f";
            case "RenderVector3i":
                return "math.Vector3i";
            case "RenderVector4":
                return "math.Vector4f";
            case "RenderVector4i":
                return "math.Vector4i";
            case "RenderQuaternion":
                return "math.Quaternionf";
            case "RenderMatrix4x4":
                return "math.Matrix4x4f";
        }

        // set inList so we don't end up with nullable types in lists
        if (typeof(IEnumerable).IsAssignableFrom(type))
            return $"[]const {MapToZigType(type.GenericTypeArguments.First(), true)}";
        
        if(type.Name == "Nullable`1")
            return $"?{MapToZigType(type.GenericTypeArguments.First(), inList)}";

        // all c# classes are nullable
        // they're also always written with WriteObject as Write only works for unmanaged types
        if (type.IsClass && !inList)
        {
            QueueType(type);
            return $"?{type.Name.HumanizeType()}";
        }

        if (type.Name.StartsWith("SharedMemoryBufferDescriptor"))
        {
            _ = MapToZigType(type.GenericTypeArguments.First(), inList);
            return "SharedMemoryBufferDescriptor";
        }

        if (type.IsGenericType)
            return $"{type.Name.Remove(type.Name.IndexOf('`'))}({string.Join(", ", type.GenericTypeArguments.Select(t => MapToZigType(t, inList)))})".HumanizeType();

        if (type.DeclaringType != null)
        {
            QueueType(type);
            QueueType(type.DeclaringType);
            return (type.DeclaringType.Name + '_' + type.Name).HumanizeType();
        }
        
        QueueType(type);

        return type.Name.HumanizeType();
    }

    protected void QueueType(Type type)
    {
        if (this.Context.GeneratedTypes.Contains(type) || this.Context.TypeQueue.Contains(type)) return;

        if (type.Assembly == this.Context.Assembly || type == typeof(Guid))
            this.Context.TypeQueue.Enqueue(type);
    }
}
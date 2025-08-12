using System.Reflection;
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;
using RenderiteGenerator.Extensions;
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
                generated = WritePackFunction(type, type.GetMethod("Pack")!, w);
                if(!generated) WritePackDiscard(true, w);
            }
            
            using (Block __ = w.BeginFunction("read", $"!{type.Name}", new FuncParam("ipc", "IpcDeserializer")))
            {
                w.Any($"var self: {type.Name} = undefined;");
                generated = WritePackFunction(type, type.GetMethod("Unpack")!, w);
                if(!generated) WritePackDiscard(false, w);
                w.Any("return self;");
            }
        }
    }

    public override bool CanGenerateType(Type type)
    {
        return type != this._iMemoryPackable && !type.IsAbstract && type.IsAssignableTo(this._iMemoryPackable);
    }
    
    private bool WritePackFunction(Type type, MethodInfo method, Writer w)
    {
        bool written = false;
        
        if(this.Context.Options.IlVerbose)
            w.Comment($"{method.Name} {type.Name}");

        TypeDefinition typeDef = this.Context.AssemblyCecil.MainModule.GetType(type.Namespace + '.' + type.Name);
        MethodDefinition? methodDef = typeDef.GetMethods().FirstOrDefault(m => m.Name == method.Name);
        if (methodDef == null)
        {
            if (type.BaseType == null)
            {
                // this should never happen
                w.Bug($"{type.Name} has no explicitly defined method named {method.Name}, and has no base type");
                return written;
            }
            
            if(this.Context.Options.IlVerbose)
                w.Note($"{type.Name} has no explicitly defined method named {method.Name}, trying {type.BaseType?.Name}.{method.Name}");

            written |= WritePackFunction(type.BaseType!, type.BaseType!.GetMethod(method.Name)!, w);
            return written;
        }

        Queue<string> names = new();
        foreach (Instruction instruction in methodDef.Body.Instructions)
        {
            // if (this._ilVerbose)
                // w.Any($"{instruction} ({instruction.OpCode.FlowControl})");

            FlowControl flow = instruction.OpCode.FlowControl;
            if (flow != FlowControl.Next && flow != FlowControl.Call && flow != FlowControl.Return)
            {
                w.Any($"FIXME: Unknown {flow} instruction:\n{instruction}");
            }

            if (instruction.OpCode.Code is Code.Ldfld or Code.Ldflda)
            {
                string name = ((FieldReference)instruction.Operand).Name;
                names.Enqueue(name);
                // if (this._ilVerbose)
                    // w.Any($"{instruction.OpCode.Code} {name}");
            }

            if (instruction.OpCode.Code is Code.Call && instruction.Operand is MethodReference callRef)
            {
                switch (callRef.Name)
                {
                    // Write single value or packed boolean
                    case "Write" when callRef.Parameters.Count == 1:
                    case "WriteObject":
                    {
                        string name = names.DequeueLast();
                        w.Any($"try ipc.write(@TypeOf(self.{name}), self.{name});");
                        written = true;
                        break;
                    }
                    case "Write" when callRef.Parameters.All(p => p.ParameterType.Name == "Boolean"):
                    {
                        List<string> paramsList = names.Select(n => "self." + n).ToList();
                        while (paramsList.Count < 8)
                        {
                            paramsList.Add("false");
                        }
                        w.Any($"try ipc.write{paramsList.Count}PackedBools({string.Join(", ", paramsList)});");
                        names.Clear();
                        written = true;
                        break;
                    }
                    // Read single value or packed boolean
                    case "Read" when callRef.Parameters.Count == 1:
                    case "ReadObject":
                    {
                        string name = names.DequeueLast();
                        w.Any($"self.{name} = try ipc.read(@TypeOf(self.{name}));");
                        written = true;
                        break;
                    }
                    case "Read" when callRef.Parameters.All(p => p.ParameterType.Name == "Boolean&"):
                    {
                        List<string> paramsList = names.Select(n => "self." + n).ToList();
                        // TODO: ceil to nearest multiple of 8
                        // FE doesn't pack more than 1 byte at a time so its not particularly important
                        while (paramsList.Count < 8)
                        {
                            paramsList.Add("_");
                        }
                        w.Any($"{string.Join(", ", paramsList)} = try ipc.read{paramsList.Count}PackedBools();");
                        names.Clear();
                        written = true;
                        break;
                    }
                    // Write list
                    case "WriteValueList":
                    case "WriteObjectList":
                    case "WriteStringList":
                    {
                        string name = names.DequeueLast();
                        w.Any($"try ipc.writeList(@TypeOf(self.{name}), self.{name});");
                        written = true;
                        break;
                    }
                    case "WriteNestedValueList":
                    {
                        string name = names.DequeueLast();
                        w.Any($"try ipc.writeNestedList(@TypeOf(self.{name}), self.{name});");
                        written = true;
                        break;
                    }
                    case "WritePolymorphicList":
                    {
                        string name = names.DequeueLast();
                        w.Any($"try ipc.writePolymorphicList(@TypeOf(self.{name}), self.{name});");
                        written = true;
                        break;
                    }
                    // Read list
                    case "ReadValueList":
                    case "ReadObjectList":
                    case "ReadStringList":
                    {
                        string name = names.DequeueLast();
                        w.Any($"self.{name} = try ipc.readList(@TypeOf(self.{name}));");
                        written = true;
                        break;
                    }
                    case "ReadNestedValueList":
                    {
                        string name = names.DequeueLast();
                        w.Any($"self.{name} = try ipc.readNestedList(@TypeOf(self.{name}));");
                        written = true;
                        break;
                    } 
                    case "ReadPolymorphicList":
                    {
                        string name = names.DequeueLast();
                        w.Any($"self.{name} = try ipc.readPolymorphicList(@TypeOf(self.{name}));");
                        written = true;
                        break;
                    }
                    // Packing methods
                    case "Pack" or "Unpack":
                    {
                        MethodInfo? subMethod = type.BaseType?.GetMethod(method.Name);
                        if (subMethod == null)
                        {
                            w.Fixme($"Could not find {method.Name} on {type.BaseType}");
                            written = true;
                            continue;
                        }
                        written |= WritePackFunction(type.BaseType!, subMethod, w);
                        break;
                    }
                    default:
                        w.Fixme($"Unknown {callRef.GetType().Name} {callRef}");
                        break;
                }
            }
        }

        if(this.Context.Options.IlVerbose)
            w.Any($"{type.Name} {method.Name.ToLower()}ed");

        return written;
    }
    
    private void WritePackDiscard(bool write, Writer w)
    {
        if (write)
            w.Any("_ = self;");
        else
            w.Any("_ = &self; // FIXME: Type not generating any members");

        w.Any("_ = ipc;");
    }
}
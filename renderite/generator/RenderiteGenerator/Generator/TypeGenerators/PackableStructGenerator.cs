using System.Diagnostics;
using System.Reflection;
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;
using RenderiteGenerator.Extensions;
using RenderiteGenerator.Generator.Blocks;
using RenderiteGenerator.Generator.Info;

namespace RenderiteGenerator.Generator.TypeGenerators;

public class PackableStructGenerator : StructGenerator
{
    private readonly Type _iMemoryPackable;

    public PackableStructGenerator(GeneratorContext context) : base(context)
    {
        this._iMemoryPackable = context.Types.First(t => t.Name == "IMemoryPackable");
    }
    
    public override bool Pack(Type t, Writer w, FieldInfo[] fields, bool write) => WritePackFunction(t, t.GetMethod(write ? "Pack" : "Unpack")!, w);

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

        bool skip = false;
        Queue<string> names = new();
        List<IfStatementInfo> ifStatements = [];
        foreach (Instruction instruction in methodDef.Body.Instructions)
        {
            if (skip)
            {
                skip = false;
                continue;
            }
            // if (this._ilVerbose)
                // w.Any($"{instruction} ({instruction.OpCode.FlowControl})");

            FlowControl flow = instruction.OpCode.FlowControl;
            if (flow != FlowControl.Next && flow != FlowControl.Call && flow != FlowControl.Return && flow != FlowControl.Cond_Branch && instruction.OpCode.Code != Code.Brfalse_S)
            {
                w.Fixme($"Unknown {flow} instruction");
                w.Comment(instruction.ToString());
            }

            if (instruction.OpCode.Code == Code.Brfalse_S)
            {
                string name = names.DequeueLastHumanizeField();
                ifStatements.Add(new IfStatementInfo(w.BeginIf("self." + name), (Instruction)instruction.Operand));
            }
            
            foreach (IfStatementInfo ifStatement in ifStatements)
            {
                if(ifStatement.JumpDestination == instruction)
                    ifStatement.Dispose();
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
                if (instruction.Next.OpCode.Code is Code.Stfld)
                {
                    names.Enqueue(((FieldReference)instruction.Next.Operand).Name);
                }
                
                switch (callRef.Name)
                {
                    // Write single value or packed boolean
                    case "Write" when callRef.Parameters.Count == 1:
                    case "WriteObject":
                    {
                        string name = names.DequeueLastHumanizeField();
                        w.Any($"try ipc.write(@TypeOf(self.{name}), self.{name});");
                        written = true;
                        break;
                    }
                    case "Write" when callRef.Parameters.All(p => p.ParameterType.Name == "Boolean"):
                    {
                        List<string> paramsList = names.Select(n => "self." + n.HumanizeField()).ToList();
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
                        string name = names.DequeueLastHumanizeField();
                        w.Any($"self.{name} = try ipc.read(@TypeOf(self.{name}));");
                        written = true;
                        break;
                    }
                    case "Read" when callRef.Parameters.All(p => p.ParameterType.Name == "Boolean&"):
                    {
                        List<string> paramsList = names.Select(n => "self." + n.HumanizeField()).ToList();
                        // TODO: ceil to nearest multiple of 8
                        // FE doesn't pack more than 1 byte at a time so its not particularly important
                        while (paramsList.Count < 8)
                        {
                            paramsList.Add("_");
                        }
                        Debug.Assert(paramsList.Count == 8);
                        w.Any($"{string.Join(", ", paramsList)} = try ipc.read{paramsList.Count}PackedBools();");
                        names.Clear();
                        written = true;
                        break;
                    }
                    // Time functions
                    case "get_UtcNow":
                    {
                        string name = names.DequeueLastHumanizeField();
                        w.Any($"self.{name} = std.time.nanoTimestamp();");
                        written = true;
                        break;
                    }
                    // Write list
                    case "WriteValueList":
                    case "WriteObjectList":
                    case "WriteStringList":
                    {
                        string name = names.DequeueLastHumanizeField();
                        w.Any($"try ipc.writeList(@TypeOf(self.{name}), self.{name});");
                        written = true;
                        break;
                    }
                    case "WriteNestedValueList":
                    {
                        string name = names.DequeueLastHumanizeField();
                        w.Any($"try ipc.writeNestedList(@TypeOf(self.{name}), self.{name});");
                        written = true;
                        break;
                    }
                    case "WritePolymorphicList":
                    {
                        string name = names.DequeueLastHumanizeField();
                        w.Any($"try ipc.writePolymorphicList(@TypeOf(self.{name}), self.{name});");
                        written = true;
                        break;
                    }
                    // Read list
                    case "ReadValueList":
                    case "ReadObjectList":
                    case "ReadStringList":
                    {
                        string name = names.DequeueLastHumanizeField();
                        w.Any($"self.{name} = try ipc.readList(@TypeOf(self.{name}));");
                        written = true;
                        break;
                    }
                    case "ReadNestedValueList":
                    {
                        string name = names.DequeueLastHumanizeField();
                        w.Any($"self.{name} = try ipc.readNestedList(@TypeOf(self.{name}));");
                        written = true;
                        break;
                    } 
                    case "ReadPolymorphicList":
                    {
                        string name = names.DequeueLastHumanizeField();
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
}
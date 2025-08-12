using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;
using RenderiteGenerator.Generator.Blocks;

namespace RenderiteGenerator.Generator.TypeGenerators;

public class PolymorphicGenerator : TypeGenerator
{
    private readonly Type _polymorphicType;

    public PolymorphicGenerator(GeneratorContext context) : base(context)
    {
        this._polymorphicType = context.Types.First(t => t.Name == "PolymorphicMemoryPackableEntity`1").GetGenericTypeDefinition();
    }

    public override void Generate(Type type, Writer w)
    {
        List<string> typeNames = [];
        
        TypeDefinition typeDef = this.Context.AssemblyCecil.MainModule.GetType(type.FullName);
        MethodDefinition? ctor = typeDef.GetStaticConstructor();
        if (ctor == null)
            throw new Exception($"Couldn't find static constructor for {type.Name}");
            
        using (Block _ = w.BeginEnum($"{type.Name}Types", "i32"))
        {
            foreach (Instruction instruction in ctor.Body.Instructions)
            {
                if (instruction.OpCode.Code != Code.Ldtoken) continue;

                TypeDefinition insnType = (TypeDefinition)instruction.Operand;

                Type originalType = this.Context.Assembly.GetType(insnType.FullName)!;
                this.QueueType(originalType);

                string name = insnType.Name;
                w.EnumMember(name);
                typeNames.Add(name);
            }
        }

        using (Block _ = w.BeginUnion(type.Name))
        {
            foreach (string name in typeNames)
            {
                w.StructMember(name, name);
            }
        }
    }

    public override bool CanGenerateType(Type type)
    {
        if (type.BaseType is not { IsGenericType: true })
            return false;
        return type.BaseType.GetGenericTypeDefinition() == this._polymorphicType;
    }
}
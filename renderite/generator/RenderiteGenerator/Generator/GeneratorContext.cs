using System.Reflection;
using Mono.Cecil;
using RenderiteGenerator.Options;

namespace RenderiteGenerator.Generator;

#nullable disable

public class GeneratorContext
{
    public string EngineVersion;

    public GeneratorOptions Options;
    public Generator Generator;
    
    public Assembly Assembly;
    public AssemblyDefinition AssemblyCecil;

    public Type[] Types;
    public Queue<Type> RemainingTypes = [];
    public List<Type> GeneratedTypes = [];

    public int CurrentIndent;
}
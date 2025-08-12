using System.Reflection;
using Mono.Cecil;
using NotEnoughLogs;
using RenderiteGenerator.Options;

namespace RenderiteGenerator.Generator;

#nullable disable

public class GeneratorContext
{
    public string EngineVersion;

    public GeneratorOptions Options;
    public Generator Generator;
    public Logger Logger;
    
    public Assembly Assembly;
    public AssemblyDefinition AssemblyCecil;

    public Type[] Types;
    public readonly Queue<Type> TypeQueue = [];
    public readonly List<Type> GeneratedTypes = [];

    public int CurrentIndent;
}
using CommandLine;

namespace RenderiteGenerator;

public class GeneratorOptions
{
    [Option('v', "verbose", Required = false, HelpText = "Output verbose messaging as Zig types are generated.")]
    public bool Verbose { get; set; }
    
    [Option("il-verbose", Required = false, HelpText = "Output verbose IL details to the Zig file as Zig types are generated.")]
    public bool IlVerbose { get; set; }

    [Option('i', "assembly-path", Required = true, HelpText = "The absolute path to the Renderite.Shared.dll file.")]
    public string AssemblyPath { get; set; } = null!;

    [Option('o', "output-zig-file", Required = false, Default = null, HelpText = "The destination .zig file to generate.")]
    public string? OutputZigFile { get; set; } = null;
}
using System.Diagnostics;
using CommandLine;

namespace RenderiteGenerator.Options;

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
    
    public void DetermineDefaultOutputPath()
    {
        Process process = Process.Start(new ProcessStartInfo
        {
            FileName = "git",
            Arguments = "rev-parse --show-toplevel",
            UseShellExecute = false,
            RedirectStandardOutput = true,
        })!;
        process.WaitForExit();
        if (process.ExitCode != 0)
            throw new Exception("Git exited with exit code " + process.ExitCode);

        string? output = process.StandardOutput.ReadLine();
        if (output == null)
            throw new Exception("Git returned no output");

        this.OutputZigFile = Path.Combine(output, "renderite", "shared.zig");
    }
}
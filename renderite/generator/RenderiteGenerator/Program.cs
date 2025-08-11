using System.Runtime;
using CommandLine;
using RenderiteGenerator;

GCSettings.LatencyMode = GCLatencyMode.Batch;

Parser.Default.ParseArguments<GeneratorOptions>(args)
    .WithParsed(o =>
    {
        using(Generator generator = new(o))
        {
            generator.Run();
        }
        
        Zig.Format(o.OutputZigFile!);
    });
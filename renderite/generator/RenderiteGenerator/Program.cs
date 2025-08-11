using System.Diagnostics.CodeAnalysis;
using System.Runtime;
using CommandLine;
using NotEnoughLogs;
using NotEnoughLogs.Behaviour;
using RenderiteGenerator;
using RenderiteGenerator.Generator;
using RenderiteGenerator.Logging;
using RenderiteGenerator.Options;

GCSettings.LatencyMode = GCLatencyMode.Batch;

using Logger logger = new(new LoggerConfiguration
{
    Behaviour = new DirectLoggingBehaviour(),
    #if DEBUG
    MaxLevel = LogLevel.Trace,
    #else
    MaxLevel = LogLevel.Info,
    #endif
});

Parser.Default.ParseArguments<GeneratorOptions>(args)
    .WithParsed([SuppressMessage("ReSharper", "AccessToDisposedClosure")] (o) =>
    {
        logger.LogDebug(LogCategory.Generator, "Parsed generator options");
        if (o.OutputZigFile == null) o.DetermineDefaultOutputPath();
        
        using(LegacyGenerator generator = new(o))
        {
            generator.Run();
        }
        
        Zig.Format(o.OutputZigFile!);
    });
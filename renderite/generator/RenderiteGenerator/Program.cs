using CommandLine;
using RenderiteGenerator;

Parser.Default.ParseArguments<GeneratorOptions>(args)
    .WithParsed(o =>
    {
        using Generator generator = new(o);
        generator.Run();
    });
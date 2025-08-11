using NotEnoughLogs;
using RenderiteGenerator.Options;

namespace RenderiteGenerator.Generator;

public class ZigGenerator
{
    private readonly GeneratorOptions _options;
    private readonly Logger _logger;

    public ZigGenerator(Logger logger, GeneratorOptions options)
    {
        this._options = options;
    }
}
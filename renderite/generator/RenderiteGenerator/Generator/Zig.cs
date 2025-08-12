using System.Diagnostics;

namespace RenderiteGenerator.Generator;

public static class Zig
{
    public static void Format(string file)
    {
        string path = Path.GetFullPath(file);
        Process process = Process.Start("zig", ["fmt", path]);
        process.WaitForExit();

        if (process.ExitCode != 0)
            throw new Exception("Zig format exited with code " + process.ExitCode);
    }
}
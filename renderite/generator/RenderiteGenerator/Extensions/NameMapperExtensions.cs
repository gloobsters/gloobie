using Humanizer;

namespace RenderiteGenerator.Generator;

public static class NameMapperExtensions
{
    private static string EscapeIdentifiers(this string name)
    {
        bool invalid = name switch
        {
            "addrspace" => true,
            "align" => true,
            "allowzero" => true,
            "and" => true,
            "anyframe" => true,
            "anytype" => true,
            "asm" => true,
            "break" => true,
            "callconv" => true,
            "catch" => true,
            "comptime" => true,
            "const" => true,
            "continue" => true,
            "defer" => true,
            "else" => true,
            "enum" => true,
            "errdefer" => true,
            "error" => true,
            "export" => true,
            "extern" => true,
            "fn" => true,
            "for" => true,
            "if" => true,
            "inline" => true,
            "linksection" => true,
            "noalias" => true,
            "noinline" => true,
            "nosuspend" => true,
            "opaque" => true,
            "or" => true,
            "orelse" => true,
            "packed" => true,
            "pub" => true,
            "resume" => true,
            "return" => true,
            "struct" => true,
            "suspend" => true,
            "switch" => true,
            "test" => true,
            "threadlocal" => true,
            "try" => true,
            "union" => true,
            "unreachable" => true,
            "var" => true,
            "volatile" => true,
            "while" => true,
            _ => false,
        };

        return invalid ? $"@\"{name}\"" : name;
    }
    
    public static string HumanizeField(this string name)
    {
        name = name.Replace("2D", "_2D_", StringComparison.OrdinalIgnoreCase);
        name = name.Replace("3D", "_3D_", StringComparison.OrdinalIgnoreCase);
        
        name = name.Underscore().Trim('_').ToLower().EscapeIdentifiers();

        name = name.Replace("2_d", "2d");
        name = name.Replace("3_d", "3d");

        name = name.Replace("i_ds", "ids");

        return name;
    }

    public static string HumanizeType(this string name)
    {
        // Check for integers
        if (name.Length > 1 && name[0] is 'i' or 'f' or 'u' && name[1..].All(char.IsNumber))
        {
            return name;
        }

        if (name == "bool")
        {
            return name;
        }
        
        // Only humanize the type, not the namespace
        int idx = name.LastIndexOf('.');
        if (idx != -1)
        {
            return $"{name[0..idx]}.{name[(idx + 1)..].HumanizeType()}";
        }

        idx = name.LastIndexOf("[]const", StringComparison.Ordinal);
        if (idx != -1)
        {
            return $"{name[..idx]} []const {name[(idx + "[]const".Length)..].HumanizeType()}";
        }
        
        idx = name.LastIndexOf("[]", StringComparison.Ordinal);
        if (idx != -1)
        {
            return $"{name[..idx]} []{name[(idx + "[]".Length)..].HumanizeType()}";
        }
        
        return name.Replace("_", "").Pascalize();
    }
}
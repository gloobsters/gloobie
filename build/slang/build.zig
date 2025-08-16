const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const bin_dep_name = switch (builtin.cpu.arch) {
        .x86_64 => switch (builtin.os.tag) {
            .linux => "linux_x86_64",
            .windows => "windows_x86_64",
            else => @compileError("Unsupported platform " ++ builtin.os.tag),
        },
        .aarch64 => switch (builtin.os.tag) {
            .linux => "linux_aarch64",
            .windows => "windows_aarch64",
            else => @compileError("Unsupported platform " ++ builtin.os.tag),
        },
        else => @compileError("Unsupported platform " ++ builtin.cpu.arch),
    };

    if (b.lazyDependency(bin_dep_name, .{})) |slang_bin_dep| {
        const bin_folder = slang_bin_dep.path("bin");

        const compiler_bin_name = switch (builtin.os.tag) {
            .linux => "slangc",
            .windows => "slangc.exe",
            else => @compileError("Unsupported platform " ++ builtin.os.tag),
        };

        const compiler_path = bin_folder.path(b, compiler_bin_name);

        b.addNamedLazyPath("compiler", compiler_path);
    }
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use_llvm", "Whether to compile using LLVM") orelse true;
    const use_lld = b.option(bool, "use_lld", "Whether to link using LLD") orelse true;

    const sdl3_dep = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .c_sdl_preferred_linkage = .dynamic,
    });

    const sdl3_mod = sdl3_dep.module("sdl3");

    const gpu_root = b.path("gpu/");
    const gpu_mod = b.addModule("gpu", .{
        .target = target,
        .optimize = optimize,

        .root_source_file = gpu_root.path(b, "gpu.zig"),

        .imports = &.{
            .{ .name = "sdl3", .module = sdl3_mod },
        },
    });

    gpu_mod.addCSourceFiles(.{
        .root = gpu_root,
        .language = .c,
        .files = &.{"hashtable/hashtable.c"},
    });

    gpu_mod.addCSourceFiles(.{
        .root = gpu_root,
        .files = &.{
            "gpu.c",
            "vulkan/gpu_vulkan.c",
        },
        .language = .c,
    });
    gpu_mod.addCMacro("GPU_VULKAN", "1");

    const gloobie_mod = b.addModule("gloobie", .{
        .root_source_file = b.path("client/main.zig"),

        .optimize = optimize,
        .target = target,

        .imports = &.{
            .{ .name = "sdl3", .module = sdl3_mod },
            .{ .name = "gpu", .module = gpu_mod },
        },
    });

    const gloobie_exe = b.addExecutable(.{
        .name = "gloobie",
        .root_module = gloobie_mod,
        .use_lld = use_lld,
        .use_llvm = use_llvm,
        .version = .{
            .major = 0,
            .minor = 0,
            .patch = 1,
            .pre = "alpha",
        },
    });

    b.installArtifact(gloobie_exe);

    const run_step = b.step("run", "Runs the gloobie executable");

    const gloobie_exe_run = b.addRunArtifact(gloobie_exe);
    run_step.dependOn(&gloobie_exe_run.step);
}

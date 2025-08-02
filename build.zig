const std = @import("std");

const XrBackend = enum {
    openxr,
    openvr,
};

const Options = struct {
    use_llvm: ?bool,
    use_lld: ?bool,

    render_backends: struct {
        vulkan: bool,
    },

    xr_backend: XrBackend,

    safety: bool,
};

fn addPlatformDefines(module: anytype, options: Options, target: std.Build.ResolvedTarget) void {
    const addMacro = switch (@TypeOf(module)) {
        *std.Build.Module => std.Build.Module.addCMacro,
        *std.Build.Step.TranslateC => std.Build.Step.TranslateC.defineCMacro,
        else => |unknown_type| @compileError("unhandled type: " ++ @typeName(unknown_type)),
    };

    if (options.render_backends.vulkan) {
        addMacro(module, "GPU_VULKAN", "1");
    }

    switch (options.xr_backend) {
        .openxr => addMacro(module, "XR_OPENXR", "1"),
        .openvr => addMacro(module, "XR_OPENVR", "1"),
    }

    switch (target.result.os.tag) {
        .windows => {
            addMacro(module, "PLATFORM_WIN32", "1");
        },
        .linux => {
            addMacro(module, "PLATFORM_LINUX", "1");
        },
        else => |os_tag| std.debug.panic("TODO: add platform define for platform {s}", .{@tagName(os_tag)}),
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options: Options = .{
        .use_lld = b.option(bool, "use_lld", "Link using LLD"),
        .use_llvm = b.option(bool, "use_llvm", "Compile using LLVM"),

        .xr_backend = b.option(XrBackend, "xr_backend", "The XR backend to use") orelse .openxr,

        .render_backends = .{
            .vulkan = b.option(bool, "vulkan", "Enable Vulkan render backend") orelse true,
        },

        .safety = optimize == .ReleaseSafe or optimize == .Debug,
    };

    const options_module = create_options_module: {
        const options = b.addOptions();
        options.addOption(Options, "build_options", build_options);
        const options_module = options.createModule();

        break :create_options_module options_module;
    };

    const sdl3_dep = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,

        .c_sdl_preferred_linkage = .static,
    });

    const upstream_sdl3_dep = sdl3_dep.builder.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const upstream_sdl3_inc = upstream_sdl3_dep.path("include/");

    const vulkan_headers_dep = b.dependency("vulkan-headers", .{});
    const vulkan_headers = vulkan_headers_dep.path("include/");
    const openxr_headers_dep = b.dependency("openxr-headers", .{});
    const openxr_headers = openxr_headers_dep.path("include/");

    const vulkan_mod = b.dependency("vulkan-zig", .{
        .registry = b.dependency("vulkan-headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const sdl3_mod = sdl3_dep.module("sdl3");

    // openxr wrapper
    const openxr_mod = create_openxr_mod: {
        const openxr_root = b.path("openxr/");

        const translate_c = b.addTranslateC(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = openxr_root.path(b, "c.h"),
        });
        addPlatformDefines(translate_c, build_options, target);
        translate_c.addIncludePath(openxr_headers);

        if (build_options.render_backends.vulkan) {
            translate_c.addIncludePath(vulkan_headers);
        }

        const translate_c_mod = translate_c.createModule();

        const openxr_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = openxr_root.path(b, "openxr.zig"),

            .imports = &.{
                .{ .name = "c", .module = translate_c_mod },
            },
        });

        addPlatformDefines(openxr_mod, build_options, target);

        break :create_openxr_mod openxr_mod;
    };

    const gpu_mod = create_gpu_mod: {
        const gpu_root = b.path("gpu/");

        const translate_c = b.addTranslateC(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = gpu_root.path(b, "gpu.h"),
        });
        addPlatformDefines(translate_c, build_options, target);
        translate_c.addIncludePath(upstream_sdl3_inc);

        if (build_options.render_backends.vulkan) {
            translate_c.addIncludePath(vulkan_headers);
        }

        const translate_c_mod = translate_c.createModule();

        const gpu_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = gpu_root.path(b, "gpu.zig"),

            .imports = &.{
                .{ .name = "sdl3", .module = sdl3_mod },
                .{ .name = "c", .module = translate_c_mod },
                .{ .name = "options", .module = options_module },
            },
        });
        gpu_mod.addIncludePath(upstream_sdl3_inc);

        gpu_mod.addCSourceFiles(.{
            .root = gpu_root,
            .language = .c,
            .files = &.{"hashtable/hashtable.c"},
        });

        gpu_mod.addCSourceFiles(.{
            .root = gpu_root,
            .files = &.{"gpu.c"},
            .language = .c,
        });

        switch (build_options.xr_backend) {
            .openxr => {
                gpu_mod.addImport("openxr", openxr_mod);

                translate_c.addIncludePath(openxr_headers);
                gpu_mod.addIncludePath(openxr_headers);
            },
            else => |xr_backend| std.debug.panic("TODO: implement backend {s}", .{@tagName(xr_backend)}),
        }

        if (build_options.render_backends.vulkan) {
            gpu_mod.addIncludePath(vulkan_headers);

            gpu_mod.addCSourceFiles(.{
                .root = gpu_root,
                .files = &.{"vulkan/gpu_vulkan.c"},
                .language = .c,
            });
        }

        addPlatformDefines(gpu_mod, build_options, target);

        break :create_gpu_mod gpu_mod;
    };

    const xr_mod = create_xr_mod: {
        const xr_root = b.path("xr/");

        const xr_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = xr_root.path(b, "xr.zig"),

            .imports = &.{
                .{ .name = "sdl3", .module = sdl3_mod },
                .{ .name = "options", .module = options_module },
            },
        });

        switch (build_options.xr_backend) {
            .openxr => xr_mod.addImport("openxr", openxr_mod),
            else => |xr_backend| std.debug.panic("TODO: implement backend {s}", .{@tagName(xr_backend)}),
        }

        if (build_options.render_backends.vulkan) {
            gpu_mod.addIncludePath(vulkan_headers);

            gpu_mod.addImport("vulkan", vulkan_mod);
        }

        addPlatformDefines(xr_mod, build_options, target);

        break :create_xr_mod xr_mod;
    };

    const renderite_mod = create_renderite_mod: {
        const renderite_root = b.path("renderite/shared/");

        const renderite_mod = b.createModule(.{
            .root_source_file = renderite_root.path(b, "renderite.zig"),
        });

        break :create_renderite_mod renderite_mod;
    };

    const zinterprocess_mod = b.dependency("zinterprocess", .{
        .target = target,
        .optimize = optimize,
    }).module("zinterprocess");

    const gloobie_mod = b.addModule("gloobie", .{
        .root_source_file = b.path("client/main.zig"),

        .optimize = optimize,
        .target = target,

        .imports = &.{
            .{ .name = "sdl3", .module = sdl3_mod },
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "xr", .module = xr_mod },
            .{ .name = "renderite", .module = renderite_mod },
            .{ .name = "zinterprocess", .module = zinterprocess_mod },
            .{ .name = "options", .module = options_module },
        },
    });

    addPlatformDefines(gloobie_mod, build_options, target);

    const gloobie_exe = b.addExecutable(.{
        .name = "gloobie",
        .root_module = gloobie_mod,
        .use_lld = build_options.use_lld,
        .use_llvm = build_options.use_llvm,
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

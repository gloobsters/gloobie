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
    const sdl3_mod = sdl3_dep.module("sdl3");

    const upstream_sdl3_dep = sdl3_dep.builder.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const upstream_sdl3_inc = upstream_sdl3_dep.path("include/");

    const imgui_dep = b.dependency("imgui", .{});
    const imgui_inc = imgui_dep.path(".");

    const vulkan_headers_dep = b.dependency("vulkan-headers", .{});
    const vulkan_headers_inc = vulkan_headers_dep.path("include/");
    const openxr_headers_dep = b.dependency("openxr-headers", .{});
    const openxr_headers_inc = openxr_headers_dep.path("include/");

    const vulkan_mod = b.dependency("vulkan-zig", .{
        .registry = b.dependency("vulkan-headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const mailbox_mod = b.dependency("mailbox", .{
        .target = target,
        .optimize = optimize,
    }).module("mailbox");

    // openxr wrapper
    const openxr_mod = create_openxr_mod: {
        const openxr_root = b.path("openxr/");

        const translate_c = b.addTranslateC(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = openxr_root.path(b, "c.h"),
        });
        addPlatformDefines(translate_c, build_options, target);
        translate_c.addIncludePath(openxr_headers_inc);

        if (build_options.render_backends.vulkan) {
            translate_c.addIncludePath(vulkan_headers_inc);
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

    const math_mod = create_math_mod: {
        const math_root = b.path("math/");

        const math_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = math_root.path(b, "math.zig"),

            .imports = &.{
                .{ .name = "openxr", .module = openxr_mod },
            },
        });

        break :create_math_mod math_mod;
    };

    const gpu_mod, const gpu_inc = create_gpu_mod: {
        const gpu_root = b.path("gpu/");

        const translate_c = b.addTranslateC(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = gpu_root.path(b, "gpu.h"),
        });
        addPlatformDefines(translate_c, build_options, target);
        translate_c.addIncludePath(upstream_sdl3_inc);

        if (build_options.render_backends.vulkan) {
            translate_c.addIncludePath(vulkan_headers_inc);
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

            .link_libc = true,
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

                translate_c.addIncludePath(openxr_headers_inc);
                gpu_mod.addIncludePath(openxr_headers_inc);
            },
            else => |xr_backend| std.debug.panic("TODO: implement backend {s}", .{@tagName(xr_backend)}),
        }

        if (build_options.render_backends.vulkan) {
            gpu_mod.addIncludePath(vulkan_headers_inc);

            gpu_mod.addCSourceFiles(.{
                .root = gpu_root,
                .files = &.{"vulkan/gpu_vulkan.c"},
                .language = .c,
            });
        }

        addPlatformDefines(gpu_mod, build_options, target);

        break :create_gpu_mod .{ gpu_mod, gpu_root };
    };

    const imgui_mod = create_imgui_mod: {
        const imgui_root = b.path("imgui/");

        const translate_c = b.addTranslateC(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = imgui_root.path(b, "c.h"),
        });
        addPlatformDefines(translate_c, build_options, target);
        translate_c.addIncludePath(upstream_sdl3_inc);
        translate_c.addIncludePath(gpu_inc);

        const translate_c_mod = translate_c.createModule();

        const imgui_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = imgui_root.path(b, "imgui.zig"),

            .imports = &.{
                .{ .name = "c", .module = translate_c_mod },
                .{ .name = "gpu", .module = gpu_mod },
                .{ .name = "sdl3", .module = sdl3_mod },
            },

            .link_libc = true,
            .link_libcpp = true,

            // imgui has Problems
            .sanitize_c = .off,
        });
        addPlatformDefines(imgui_mod, build_options, target);

        if (build_options.render_backends.vulkan) {
            imgui_mod.addIncludePath(vulkan_headers_inc);
            translate_c.addIncludePath(vulkan_headers_inc);
        }

        switch (build_options.xr_backend) {
            .openxr => {
                imgui_mod.addIncludePath(openxr_headers_inc);
                translate_c.addIncludePath(openxr_headers_inc);
            },
            else => |xr_backend| std.debug.panic("TODO: xr backend {s}", .{@tagName(xr_backend)}),
        }

        imgui_mod.addIncludePath(imgui_inc);
        imgui_mod.addIncludePath(gpu_inc);
        imgui_mod.addIncludePath(upstream_sdl3_inc);
        imgui_mod.addCSourceFiles(.{
            .root = imgui_inc,
            .files = &.{
                "imgui.cpp",
                "imgui_draw.cpp",
                "imgui_tables.cpp",
                "imgui_demo.cpp",
                "imgui_widgets.cpp",
            },
            .language = .cpp,
        });

        // custom implementation
        imgui_mod.addCSourceFiles(.{
            .root = imgui_root,
            .files = &.{
                "cimgui.cpp",
                "imgui_impl_gpu.cpp",
                "imgui_impl_sdl3.cpp",
            },
            .language = .cpp,
        });

        break :create_imgui_mod imgui_mod;
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
            gpu_mod.addIncludePath(vulkan_headers_inc);

            gpu_mod.addImport("vulkan", vulkan_mod);
        }

        addPlatformDefines(xr_mod, build_options, target);

        break :create_xr_mod xr_mod;
    };

    const zinterprocess_mod = b.dependency("zinterprocess", .{
        .target = target,
        .optimize = optimize,
    }).module("zinterprocess");

    const renderite_mod = create_renderite_mod: {
        const renderite_root = b.path("renderite/");

        const renderite_mod = b.createModule(.{
            .root_source_file = renderite_root.path(b, "renderite.zig"),
            .imports = &.{
                .{ .name = "zinterprocess", .module = zinterprocess_mod },
            },
        });

        break :create_renderite_mod renderite_mod;
    };

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
            .{ .name = "imgui", .module = imgui_mod },
            .{ .name = "math", .module = math_mod },
            .{ .name = "mailbox", .module = mailbox_mod },
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

    const test_step = b.step("test", "Runs tests on the various gloobie subsystems");

    const gloobie_test_exe = b.addTest(.{
        .name = "gloobie",
        .root_module = gloobie_mod,
        .use_lld = build_options.use_lld,
        .use_llvm = build_options.use_llvm,
    });

    const gloobie_test_exe_run = b.addRunArtifact(gloobie_test_exe);
    test_step.dependOn(&gloobie_test_exe_run.step);
}

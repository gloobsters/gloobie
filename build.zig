const std = @import("std");
const builtin = @import("builtin");

const compile_commands = @import("build/compile_commands.zig");

const XrBackend = enum {
    none,
    openxr,
};

const Options = struct {
    use_llvm: ?bool,
    use_lld: ?bool,

    render_backends: struct {
        vulkan: bool,
        d3d12: bool,
        metal: bool,

        pub fn toShaderTargets(self: @This(), gpa: std.mem.Allocator) ![]const ShaderTarget {
            var targets: std.ArrayListUnmanaged(ShaderTarget) = .empty;

            if (self.vulkan) {
                try targets.append(gpa, .spirv);
            }
            if (self.d3d12) {
                try targets.append(gpa, .dxil);
            }
            if (self.metal) {
                try targets.append(gpa, .metal);
            }

            return targets.toOwnedSlice(gpa);
        }
    },

    xr_backend: XrBackend,

    maximum_log_level: LogLevel,

    safety: bool,

    tracy: struct {
        enable: bool,
        enable_allocation: bool,
        enable_callstack: bool,
        callstack_depth: usize,
    },
};

pub const LogLevel = enum(u8) {
    err = 0,
    warn,
    info,
    debug,
    trace,
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
        .none => {},
        .openxr => addMacro(module, "XR_OPENXR", "1"),
    }

    switch (target.result.os.tag) {
        .ios, .macos => {
            addMacro(module, "PLATFORM_APPLE", "1");
        },
        .windows => {
            addMacro(module, "PLATFORM_WIN32", "1");
        },
        .linux => {
            addMacro(module, "PLATFORM_LINUX", "1");
        },
        else => |os_tag| std.debug.panic("TODO: add platform define for platform {s}", .{@tagName(os_tag)}),
    }
}

const SlangModule = struct {
    path: std.Build.LazyPath,
};

pub const ShaderTarget = enum {
    spirv,
    dxil,
    metal,
};

const Shader = struct {
    module_name: []const u8,
};

pub fn build(b: *std.Build) !void {
    const shared_c_cpp_flags: []const []const u8 = &.{
        "-gen-cdb-fragment-path",
        b.fmt("{s}/{s}", .{ b.cache_root.path.?, "cdb" }),
    };

    const c_flags = shared_c_cpp_flags;
    const cpp_flags: []const []const u8 = try std.mem.concat(b.allocator, []const u8, &.{
        shared_c_cpp_flags,
        &.{"-std=c++23"},
    });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tracy = b.option(bool, "tracy", "Enable tracy integration") orelse false;

    const ci = b.option(bool, "ci", "Whether to enable extra logging/tooling for CI") orelse false;

    const build_options: Options = .{
        .use_lld = if (enable_tracy) true else b.option(bool, "use_lld", "Link using LLD"),
        .use_llvm = if (enable_tracy) true else b.option(bool, "use_llvm", "Compile using LLVM"),

        .xr_backend = b.option(XrBackend, "xr_backend", "The XR backend to use") orelse .openxr,

        .render_backends = .{
            .vulkan = b.option(bool, "vulkan", "Enable Vulkan render backend") orelse true,
            .d3d12 = b.option(bool, "d3d12", "Enable D3D12 render backend") orelse false,
            .metal = b.option(bool, "metal", "Enable Metal render backend") orelse false,
        },

        .safety = optimize == .ReleaseSafe or optimize == .Debug,
        .maximum_log_level = b.option(LogLevel, "max_log_level", "The maximum log level to compile into the executable") orelse
            if (optimize == .Debug or optimize == .ReleaseSafe)
                .trace
            else
                .debug,

        .tracy = .{
            .enable = enable_tracy,
            .enable_allocation = b.option(bool, "tracy_allocation", "Enable tracy allocation integration") orelse enable_tracy,
            .enable_callstack = b.option(bool, "tracy_callstack", "Enable tracy callstack capture") orelse false,
            .callstack_depth = b.option(usize, "tracy_callstack_depth", "The depth to capture callstacks at") orelse 0,
        },
    };

    const enabled_shader_formats = try build_options.render_backends.toShaderTargets(b.allocator);

    const options_mod = create_options_module: {
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

    const win32_dep = b.dependency("zigwin32", .{});
    const win32_mod = win32_dep.module("win32");

    const bounded_array_dep = b.dependency("bounded_array", .{});
    const bounded_array_mod = bounded_array_dep.module("bounded_array");

    const cpp_args_dep = b.dependency("cpp-args", .{});
    const cpp_args_inc = cpp_args_dep.path("");

    const vulkan_mod = b.dependency("vulkan-zig", .{
        .registry = b.dependency("vulkan-headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const mailbox_mod = b.dependency("mailbox", .{
        .target = target,
        .optimize = optimize,
    }).module("mailbox");

    const logger_mod = create_logger_mod: {
        const logger_root = b.path("logger");

        const logger_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = logger_root.path(b, "logger.zig"),

            .imports = &.{
                .{ .name = "options", .module = options_mod },
            },
        });

        break :create_logger_mod logger_mod;
    };

    const tracy_mod = create_tracy_mod: {
        const tracy_root = b.path("tracy/");

        const tracy_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,

            .root_source_file = tracy_root.path(b, "tracy.zig"),

            .imports = &.{
                .{ .name = "options", .module = options_mod },
            },

            // tracy is silly goofy
            .sanitize_c = .off,
        });

        if (build_options.tracy.enable) {
            if (b.lazyDependency("tracy", .{})) |tracy_dep| {
                tracy_mod.addCSourceFile(.{
                    .file = tracy_dep.path("public/TracyClient.cpp"),
                    .flags = cpp_flags,
                    .language = .cpp,
                });
            }

            tracy_mod.addCMacro("TRACY_ENABLE", "1");

            // needed for tracy under windows
            if (target.result.os.tag == .windows) {
                tracy_mod.linkSystemLibrary("Ws2_32", .{});
                tracy_mod.linkSystemLibrary("Dbghelp", .{});
            }
        }

        break :create_tracy_mod tracy_mod;
    };

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
                .{ .name = "openxr", .module = openxr_mod },
                .{ .name = "options", .module = options_mod },
            },

            .link_libc = true,
        });
        gpu_mod.addIncludePath(upstream_sdl3_inc);

        gpu_mod.addCSourceFiles(.{
            .root = gpu_root,
            .language = .c,
            .files = &.{ "hashtable/hashtable.c", "gpu.c" },
            .flags = c_flags,
        });

        // Always add OpenXR headers, since the types are required for compilation
        translate_c.addIncludePath(openxr_headers_inc);
        gpu_mod.addIncludePath(openxr_headers_inc);

        switch (build_options.xr_backend) {
            .none => {},
            .openxr => {
                gpu_mod.addImport("openxr", openxr_mod);

                gpu_mod.addCSourceFiles(.{
                    .root = gpu_root.path(b, "xr"),
                    .files = &.{
                        "gpu_openxr.c",
                        "gpu_openxrdyn.c",
                    },
                    .language = .c,
                    .flags = c_flags,
                });
            },
        }

        if (build_options.render_backends.vulkan) {
            gpu_mod.addIncludePath(vulkan_headers_inc);

            gpu_mod.addCSourceFiles(.{
                .root = gpu_root,
                .files = &.{"vulkan/gpu_vulkan.c"},
                .language = .c,
                .flags = c_flags,
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

        imgui_mod.addIncludePath(openxr_headers_inc);
        translate_c.addIncludePath(openxr_headers_inc);

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
            .flags = cpp_flags,
        });

        // custom implementation
        imgui_mod.addCSourceFiles(.{
            .root = imgui_root,
            .files = &.{
                "cimgui.cpp",
                "imgui_impl_gpu.cpp",
                "imgui_impl_sdl3.cpp",
                "imgui_impl_sdlrenderer3.cpp",
            },
            .language = .cpp,
            .flags = cpp_flags,
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
                .{ .name = "gpu", .module = gpu_mod },
                .{ .name = "options", .module = options_mod },
                .{ .name = "logger", .module = logger_mod },
            },
        });

        switch (build_options.xr_backend) {
            .none => {},
            .openxr => xr_mod.addImport("openxr", openxr_mod),
        }

        if (build_options.render_backends.vulkan) {
            gpu_mod.addIncludePath(vulkan_headers_inc);

            gpu_mod.addImport("vulkan", vulkan_mod);
        }

        addPlatformDefines(xr_mod, build_options, target);

        break :create_xr_mod xr_mod;
    };

    const zinterprocess_mod = create_zinterprocess_mod: {
        const zinterprocess_root = b.path("zinterprocess/");

        const zinterprocess_mod = b.addModule("zinterprocess", .{
            .target = target,
            .optimize = optimize,

            .root_source_file = zinterprocess_root.path(b, "root.zig"),
            .imports = &.{
                .{ .name = "win32", .module = win32_mod },
            },
        });

        break :create_zinterprocess_mod zinterprocess_mod;
    };

    const renderite_mod = create_renderite_mod: {
        const renderite_root = b.path("renderite/");

        const renderite_mod = b.addModule("renderite", .{
            .target = target,
            .optimize = optimize,

            .root_source_file = renderite_root.path(b, "root.zig"),
            .imports = &.{
                .{ .name = "zinterprocess", .module = zinterprocess_mod },
                .{ .name = "tracy", .module = tracy_mod },
                .{ .name = "math", .module = math_mod },
                .{ .name = "logger", .module = logger_mod },
                .{ .name = "bounded_array", .module = bounded_array_mod },
            },
        });
        math_mod.addImport("renderite", renderite_mod);

        break :create_renderite_mod renderite_mod;
    };

    const bootstrap_mod = create_bootstrap_mod: {
        const bootstrap_root = b.path("bootstrap");

        const bootstrap_mod = b.addModule("bootstrap", .{
            .root_source_file = bootstrap_root.path(b, "main.zig"),

            .optimize = optimize,
            .target = target,

            .imports = &.{
                .{ .name = "sdl3", .module = sdl3_mod },
                .{ .name = "gpu", .module = gpu_mod },
                .{ .name = "imgui", .module = imgui_mod },
                .{ .name = "renderite", .module = renderite_mod },
                .{ .name = "zinterprocess", .module = zinterprocess_mod },
                .{ .name = "options", .module = options_mod },
                .{ .name = "logger", .module = logger_mod },
                .{ .name = "bounded_array", .module = bounded_array_mod },
            },
        });

        break :create_bootstrap_mod bootstrap_mod;
    };

    const gloobie_shader_compiler_exe, const shader_reflection_mod = create_shader_compiler: {
        const spirv_reflect_dep = b.dependency("spirv-reflect", .{});

        const dep_name = switch (builtin.cpu.arch) {
            .x86_64 => switch (builtin.os.tag) {
                .linux => "slang_linux_x86_64",
                .windows => "slang_windows_x86_64",
                else => std.debug.panic("Unsupported platform {s}", .{@tagName(builtin.os.tag)}),
            },
            .aarch64 => switch (builtin.os.tag) {
                .linux => "slang_linux_aarch64",
                .windows => "slang_windows_aarch64",
                else => std.debug.panic("Unsupported platform {s}", .{@tagName(builtin.os.tag)}),
            },
            else => std.debug.panic("Unsupported platform {s}", .{@tagName(builtin.cpu.arch)}),
        };

        const maybe_slang_dep = b.lazyDependency(dep_name, .{});

        const gloobie_compiler_mod = b.createModule(.{
            .link_libc = true,
            .link_libcpp = true,
            .target = b.resolveTargetQuery(.fromTarget(&builtin.target)),
            .optimize = .Debug,
        });

        gloobie_compiler_mod.addCSourceFiles(.{
            .files = &.{"gloobie_compiler.cc"},
            .flags = cpp_flags,
            .language = .cpp,
            .root = b.path("build/slang/"),
        });
        gloobie_compiler_mod.addCSourceFiles(.{
            .files = &.{"spirv_reflect.c"},
            .flags = c_flags,
            .root = spirv_reflect_dep.path(""),
        });

        if (maybe_slang_dep) |slang_dep| {
            gloobie_compiler_mod.addLibraryPath(slang_dep.path("lib"));
            gloobie_compiler_mod.addRPath(slang_dep.path("lib"));
            gloobie_compiler_mod.addIncludePath(slang_dep.path("include"));
        }
        gloobie_compiler_mod.addIncludePath(cpp_args_inc);
        gloobie_compiler_mod.addIncludePath(spirv_reflect_dep.path(""));

        gloobie_compiler_mod.linkSystemLibrary("slang", .{
            .search_strategy = .paths_first,
            .use_pkg_config = .no,
        });

        const gloobie_compiler_exe = b.addExecutable(.{
            .name = "gloobie_compiler",
            .root_module = gloobie_compiler_mod,
        });

        const shader_reflection_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("build/slang/reflection.zig"),
        });

        break :create_shader_compiler .{ gloobie_compiler_exe, shader_reflection_mod };
    };

    const gloobie_mod = create_gloobie_mod: {
        const gloobie_root = b.path("client");

        const shaders_root = gloobie_root.path(b, "shaders");

        var modules: std.StringArrayHashMap(SlangModule) = .init(b.allocator);
        try modules.putNoClobber("basic", .{ .path = shaders_root.path(b, "basic.slang") });
        try modules.putNoClobber("materials", .{ .path = shaders_root.path(b, "materials/materials.slang") });

        const shaders: []const Shader = &.{
            .{ .module_name = "basic" },
        };

        const gloobie_mod = b.createModule(.{
            .root_source_file = gloobie_root.path(b, "main.zig"),

            .optimize = optimize,
            .target = target,

            .imports = &.{
                .{ .name = "sdl3", .module = sdl3_mod },
                .{ .name = "gpu", .module = gpu_mod },
                .{ .name = "xr", .module = xr_mod },
                .{ .name = "renderite", .module = renderite_mod },
                .{ .name = "zinterprocess", .module = zinterprocess_mod },
                .{ .name = "options", .module = options_mod },
                .{ .name = "imgui", .module = imgui_mod },
                .{ .name = "math", .module = math_mod },
                .{ .name = "mailbox", .module = mailbox_mod },
                .{ .name = "tracy", .module = tracy_mod },
                .{ .name = "logger", .module = logger_mod },
                .{ .name = "bounded_array", .module = bounded_array_mod },
                .{ .name = "reflection", .module = shader_reflection_mod },
            },
        });

        {
            const run_shader_compiler = b.addRunArtifact(gloobie_shader_compiler_exe);
            if (ci) {
                run_shader_compiler.addArg("-v");
            }
            run_shader_compiler.addArg(switch (optimize) {
                .Debug => "-O0",
                .ReleaseSafe => "-O1",
                .ReleaseSmall => "-O2",
                .ReleaseFast => "-O3",
            });
            run_shader_compiler.addArg(switch (optimize) {
                .Debug => "-gmaximal",
                .ReleaseSafe => "-gstandard",
                .ReleaseFast => "-gminimal",
                .ReleaseSmall => "-gnone",
            });

            for (modules.keys(), modules.values()) |module_name, module| {
                run_shader_compiler.addPrefixedFileArg(b.fmt("-i{s}:", .{module_name}), module.path);
            }

            for (shaders) |shader| {
                const shader_mod = b.createModule(.{
                    .root_source_file = run_shader_compiler.addPrefixedOutputFileArg(
                        b.fmt("-r{s}:", .{shader.module_name}),
                        b.fmt("{s}.zig", .{shader.module_name}),
                    ),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "reflection", .module = shader_reflection_mod },
                        .{ .name = "options", .module = options_mod },
                    },
                });

                for (enabled_shader_formats) |shader_target| {
                    const compiled_bin = run_shader_compiler.addPrefixedOutputFileArg(
                        b.fmt("-o{s}:{s}:", .{ shader.module_name, @tagName(shader_target) }),
                        b.fmt("{s}.{s}", .{ shader.module_name, @tagName(shader_target) }),
                    );

                    shader_mod.addAnonymousImport(@tagName(shader_target), .{
                        .root_source_file = compiled_bin,
                    });
                }

                gloobie_mod.addImport(b.fmt("shaders.{s}", .{shader.module_name}), shader_mod);
            }
        }

        break :create_gloobie_mod gloobie_mod;
    };

    addPlatformDefines(gloobie_mod, build_options, target);
    addPlatformDefines(bootstrap_mod, build_options, target);

    // NOTE: Use a special name on Linux to temporarily workaround Resonite looking up by process name on Linux
    // https://github.com/Yellow-Dog-Man/Resonite-Issues/issues/5222
    const gloobie_exe_name = switch (target.result.os.tag) {
        .linux => "Renderite.Gloobie",
        else => "gloobie",
    };

    const gloobie_exe = b.addExecutable(.{
        .name = gloobie_exe_name,
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

    const bootstrap_exe = b.addExecutable(.{
        .name = "bootstrap",
        .root_module = bootstrap_mod,
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
    b.installArtifact(bootstrap_exe);
    b.installArtifact(gloobie_shader_compiler_exe);

    const manifest_file = b.path("client/Gloobie.renderer.json");
    const manifest_file_step = b.addInstallBinFile(manifest_file, "Renderers/Gloobie.renderer.json");
    b.getInstallStep().dependOn(&manifest_file_step.step);

    const run_step = b.step("run", "Runs the gloobie executable");
    const gloobie_exe_run = b.addRunArtifact(gloobie_exe);
    run_step.dependOn(&gloobie_exe_run.step);

    const bootstrap_run_step = b.step("bootstrap", "Runs the bootstrap executable");
    const bootstrap_exe_run = b.addRunArtifact(bootstrap_exe);
    bootstrap_run_step.dependOn(&bootstrap_exe_run.step);

    const test_step = b.step("test", "Runs tests on the various gloobie subsystems");

    const gloobie_test_exe = b.addTest(.{
        .name = "gloobie",
        .root_module = gloobie_mod,
        .use_lld = build_options.use_lld,
        .use_llvm = build_options.use_llvm,
    });

    const imgui_test_exe = b.addTest(.{
        .name = "imgui",
        .root_module = imgui_mod,
        .use_lld = build_options.use_lld,
        .use_llvm = build_options.use_llvm,
    });

    const renderite_test_exe = b.addTest(.{
        .name = "renderite",
        .root_module = renderite_mod,
        .use_lld = build_options.use_lld,
        .use_llvm = build_options.use_llvm,
    });

    const gloobie_test_exe_run = b.addRunArtifact(gloobie_test_exe);
    test_step.dependOn(&gloobie_test_exe_run.step);

    const imgui_test_exe_run = b.addRunArtifact(imgui_test_exe);
    test_step.dependOn(&imgui_test_exe_run.step);

    const renderite_test_exe_run = b.addRunArtifact(renderite_test_exe);
    test_step.dependOn(&renderite_test_exe_run.step);

    const cc_step = b.step("cc", "Generate Compile Commands Database");
    const gen_file_step = try compile_commands.createStep(
        b,
        b.fmt("{s}/{s}", .{ b.cache_root.path orelse "./", "cdb" }),
        "compile_commands.json",
    );
    gen_file_step.dependOn(&gloobie_exe.step);
    gen_file_step.dependOn(&gloobie_shader_compiler_exe.step);
    cc_step.dependOn(gen_file_step);
}

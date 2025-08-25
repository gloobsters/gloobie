const std = @import("std");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");
const imgui = @import("imgui");
const logger = @import("logger");

const Manifest = @import("Manifest.zig");
const ParsedManifest = std.json.Parsed(Manifest);

const DedicatedBootstrapper = @This();
const log = logger.Scoped(.bootstrap);

engine_init_thread: std.Thread,
ready_to_boot: bool,
manifests: []ParsedManifest,

pub fn init(args: []const []const u8, gpa: std.mem.Allocator) !DedicatedBootstrapper {
    var bootstrapper: DedicatedBootstrapper = .{
        .ready_to_boot = false,
        .engine_init_thread = undefined,
        .manifests = undefined,
    };

    const thread = try std.Thread.spawn(.{}, bootstrapEngine, .{ &bootstrapper, args, gpa });
    bootstrapper.engine_init_thread = thread;

    bootstrapper.manifests = try parseManifestFiles(gpa);
    for (bootstrapper.manifests) |manifest| {
        log.debug(@src(), "Read manifest: {f}", .{std.json.fmt(manifest.value, .{})});
    }

    return bootstrapper;
}

pub fn run(self: *DedicatedBootstrapper) !void {
    const window = try sdl3.video.Window.init("title: [:0]const u8", 800, 600, .{});
    defer window.deinit();
    const renderer = try sdl3.render.Renderer.init(window, null);
    defer renderer.deinit();

    const imgui_ctx = try imgui.Context.create(null);
    defer imgui_ctx.destroy();

    imgui.sdl3.initForSdlRenderer(window, renderer);
    imgui.sdl_renderer.init(renderer);

    sdl3.render.Renderer.setVSync(renderer, .adaptive);
    self.ready_to_boot = true;
}

fn bootstrapEngine(self: *DedicatedBootstrapper, args: []const []const u8, gpa: std.mem.Allocator) void {
    var child = renderite.Bootstrap.ChildInfo.init(args, gpa) catch @panic("Failed to start FrooxEngine");

    while (!self.ready_to_boot) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const renderer_pid: u32 = 0;

    var bootstrap = renderite.Bootstrap.initBootstrap(&child, renderer_pid, gpa, copy, paste) catch @panic("Failed to bootstrap FrooxEngine");
    bootstrap.receiverLoop(gpa);
}

fn parseManifestFiles(gpa: std.mem.Allocator) ![]ParsedManifest {
    const cwd = std.fs.cwd();
    try cwd.makePath("Renderers");

    var renderers_dir = try cwd.openDir("Renderers", .{ .iterate = true });
    defer renderers_dir.close();
    var iterator = renderers_dir.iterateAssumeFirstIteration();

    var manifest_count: usize = 0;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".renderer.json")) continue;
        manifest_count += 1;
    }

    log.debug(@src(), "Manifests: {d}", .{manifest_count});
    const manifests = try gpa.alloc(ParsedManifest, manifest_count);

    iterator = renderers_dir.iterate();

    var i: usize = 0;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".renderer.json")) continue;

        const file = try renderers_dir.openFile(entry.name, .{});
        defer file.close();

        manifests[i] = try Manifest.parseFromFile(file, gpa);
        i += 1;
    }

    return manifests;
}

fn copy(text: [:0]const u8) anyerror!void {
    try sdl3.clipboard.setText(text);
}

fn paste() anyerror![:0]u8 {
    return try sdl3.clipboard.getText();
}

pub fn deinit(self: *DedicatedBootstrapper, gpa: std.mem.Allocator) void {
    for (self.manifests) |manifest| {
        manifest.deinit();
    }
    gpa.free(self.manifests);
}

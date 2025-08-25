const std = @import("std");
const builtin = @import("builtin");

const imgui = @import("imgui");
const logger = @import("logger");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");
const bounded_array = @import("bounded_array");

const Manifest = @import("Manifest.zig");

const ParsedManifest = std.json.Parsed(Manifest);

const DedicatedBootstrapper = @This();
const log = logger.Scoped(.bootstrap);

engine_init_thread: std.Thread,
ready_to_boot: bool,
ui_shutdown: bool,
bootstrap_shutdown: bool,
manifests: []ParsedManifest,
selected_manifest_idx: i32,

pub fn init(args: []const []const u8, gpa: std.mem.Allocator) !*DedicatedBootstrapper {
    const bootstrapper = try gpa.create(DedicatedBootstrapper);
    errdefer gpa.destroy(bootstrapper);

    const thread = try std.Thread.spawn(.{}, bootstrapEngine, .{ bootstrapper, args, gpa });
    bootstrapper.engine_init_thread = thread;

    bootstrapper.manifests = try parseManifestFiles(gpa);
    for (bootstrapper.manifests) |manifest| {
        log.debug(@src(), "Read manifest: {f}", .{std.json.fmt(manifest.value, .{})});
    }

    return bootstrapper;
}

pub fn run(self: *DedicatedBootstrapper) !void {
    const window = try sdl3.video.Window.init("Select Renderer", 400, 500, .{});
    defer window.deinit();
    const renderer = try sdl3.render.Renderer.init(window, null);
    defer renderer.deinit();

    try sdl3.render.Renderer.setVSync(renderer, .{ .on_each_num_refresh = 1 });

    const imgui_ctx = try imgui.Context.create(null);
    defer imgui_ctx.destroy();

    try imgui.sdl3.initForSdlRenderer(window, renderer);
    defer imgui.sdl3.shutdown();

    try imgui.sdl_renderer.init(renderer);
    defer imgui.sdl_renderer.shutdown();

    while (!self.ui_shutdown) {
        try self.frame(imgui_ctx, renderer);
    }
}

fn frame(self: *DedicatedBootstrapper, imgui_ctx: imgui.Context, renderer: sdl3.render.Renderer) !void {
    while (sdl3.events.poll()) |event| {
        _ = imgui.sdl3.processEvent(event);
        switch (event) {
            inline .quit, .window_close_requested => {
                self.ui_shutdown = true;
            },
            // .window_close_requested => |window| if (window.id == self.window.window.getId() catch unreachable) {
            //     self.window_open = false;
            // },
            else => {},
        }
    }

    imgui.sdl_renderer.newFrame();
    imgui.sdl3.newFrame();
    imgui.newFrame();

    imgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    imgui.setNextWindowSize(imgui_ctx.getIo().DisplaySize);

    self.selectionWindow();

    imgui.render();
    try renderer.clear();
    try imgui.sdl_renderer.renderDrawData(imgui.getDrawData(), renderer);
    try renderer.present();
}

fn selectionWindow(self: *DedicatedBootstrapper) void {
    var open = true;
    const draw = imgui.begin("Select Renderer", &open, imgui.c.ImGuiWindowFlags_NoDecoration | imgui.c.ImGuiWindowFlags_NoResize);
    defer imgui.end();
    if (!draw) return;

    for (self.manifests, 0..) |manifest, i| {
        _ = imgui.radioButton(manifest.value.name, &self.selected_manifest_idx, @intCast(i));
    }

    imgui.separator();
    if (imgui.button("OK")) {
        self.ui_shutdown = true;
        self.bootstrap_shutdown = false;
        self.ready_to_boot = true;
    }
    imgui.sameLine();
    if (imgui.button("Cancel")) {
        self.ui_shutdown = true;
        self.bootstrap_shutdown = true;
        self.ready_to_boot = false;
    }
}

fn bootstrapEngine(self: *DedicatedBootstrapper, args: []const []const u8, gpa: std.mem.Allocator) void {
    log.info(@src(), "Starting FrooxEngine in the background...", .{});
    var child = renderite.Bootstrap.ChildInfo.init(args, gpa) catch @panic("Failed to start FrooxEngine");

    var bootstrap = renderite.Bootstrap.initBootstrap(&child, gpa, copy, paste) catch @panic("Failed to bootstrap FrooxEngine");

    log.info(@src(), "FrooxEngine spawned, waiting for user selection...", .{});
    while (!self.ready_to_boot) {
        if (self.bootstrap_shutdown) {
            log.warn(@src(), "Bootstrapper is shutting down, won't boot", .{});
            return;
        }

        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    log.info(@src(), "Ready to boot!", .{});

    const manifest = self.manifests[@intCast(self.selected_manifest_idx)].value;
    const executable = switch (builtin.os.tag) {
        .windows => manifest.winExecutablePath,
        else => unix_executable: {
            if (manifest.runInWine orelse false) {
                break :unix_executable manifest.winExecutablePath;
            }

            break :unix_executable manifest.unixExecutablePath;
        },
    };

    log.info(@src(), "Starting renderer '{s}' at '{s}'", .{ manifest.name, executable });

    var argv: bounded_array.BoundedArray([]const u8, 5) = .{};

    argv.appendAssumeCapacity(executable);
    argv.appendAssumeCapacity("-QueueName");
    argv.appendAssumeCapacity(bootstrap.init_settings.queue_name.constSlice());
    argv.appendAssumeCapacity("-QueueCapacity");

    // SAFETY: it's big enough
    var msg_buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{d}", .{bootstrap.init_settings.queue_length}) catch unreachable;

    argv.appendAssumeCapacity(msg);

    var renderer = std.process.Child.init(argv.constSlice(), gpa);
    renderer.spawn() catch @panic("Failed to spawn renderer");
    renderer.waitForSpawn() catch @panic("Failed to wait for renderer to spawn");

    log.info(@src(), "Renderer spawned!", .{});

    bootstrap.sendRenderitePid(renderer.id) catch @panic("Failed to send renderer PID to FrooxEngine");
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
    gpa.destroy(self);
}

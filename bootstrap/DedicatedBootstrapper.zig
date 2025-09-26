const std = @import("std");
const builtin = @import("builtin");

const imgui = @import("imgui");
const logger = @import("logger");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");
const bounded_array = @import("bounded_array");

const Manifest = @import("Manifest.zig");

const DedicatedBootstrapper = @This();
const log = logger.Scoped(.bootstrap);

engine_init_thread: std.Thread,
json_arena: std.heap.ArenaAllocator,
shared: SharedState,

const SharedState = struct {
    lock: std.Thread.Mutex,

    ready_to_boot: bool,
    ui_shutdown: bool,
    bootstrap_shutdown: bool,
    selected_manifest_idx: i32,

    manifests: []Manifest,
};

pub fn init(args: []const []const u8, gpa: std.mem.Allocator) !*DedicatedBootstrapper {
    const bootstrapper = try gpa.create(DedicatedBootstrapper);
    errdefer gpa.destroy(bootstrapper);

    var arena = std.heap.ArenaAllocator.init(gpa);

    const manifests = try parseManifestFiles(arena.allocator());
    for (manifests) |manifest| {
        log.debug(@src(), "Read manifest: {f}", .{std.json.fmt(manifest, .{})});
    }

    bootstrapper.shared = .{
        .lock = .{},
        .ready_to_boot = false,
        .ui_shutdown = false,
        .bootstrap_shutdown = false,
        .selected_manifest_idx = 0,
        .manifests = manifests,
    };

    const thread = try std.Thread.spawn(.{}, bootstrapEngine, .{ &bootstrapper.shared, args, gpa });
    
    bootstrapper.* = .{
        .engine_init_thread = thread,
        .json_arena = arena,
        .shared = bootstrapper.shared,
    };

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

    while (true) {
        {
            self.shared.lock.lock();
            defer self.shared.lock.unlock();

            if (self.shared.ui_shutdown)
                break;
        }

        try self.frame(imgui_ctx, renderer);
    }
}

fn frame(self: *DedicatedBootstrapper, imgui_ctx: imgui.Context, renderer: sdl3.render.Renderer) !void {
    while (sdl3.events.poll()) |event| {
        _ = imgui.sdl3.processEvent(event);
        switch (event) {
            inline .quit, .window_close_requested => {
                self.shared.lock.lock();
                defer self.shared.lock.unlock();

                self.shared.ui_shutdown = true;
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

    for (self.shared.manifests, 0..) |manifest, i| {
        _ = imgui.radioButton(manifest.name, &self.shared.selected_manifest_idx, @intCast(i));
    }

    imgui.separator();
    if (imgui.button("OK")) {
        self.shared.lock.lock();
        defer self.shared.lock.unlock();

        self.shared.ui_shutdown = true;
        self.shared.bootstrap_shutdown = false;
        self.shared.ready_to_boot = true;
    }
    imgui.sameLine();
    if (imgui.button("Cancel")) {
        self.shared.lock.lock();
        defer self.shared.lock.unlock();

        self.shared.ui_shutdown = true;
        self.shared.bootstrap_shutdown = true;
        self.shared.ready_to_boot = false;
    }
}

fn bootstrapEngine(shared: *SharedState, args: []const []const u8, gpa: std.mem.Allocator) void {
    log.info(@src(), "Starting FrooxEngine in the background...", .{});
    var child = renderite.Bootstrap.ChildInfo.init(args, gpa) catch @panic("Failed to start FrooxEngine");

    var bootstrap = renderite.Bootstrap.initBootstrap(&child, gpa, copy, paste) catch @panic("Failed to bootstrap FrooxEngine");

    log.info(@src(), "FrooxEngine spawned, waiting for user selection...", .{});
    while (true) {
        {
            shared.lock.lock();
            defer shared.lock.unlock();

            if (shared.bootstrap_shutdown) {
                log.warn(@src(), "Bootstrapper is shutting down, won't boot", .{});
                return;
            }

            if (shared.ready_to_boot)
                break;
        }

        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    log.info(@src(), "Ready to boot!", .{});

    const manifest = shared.manifests[@intCast(shared.selected_manifest_idx)];
    const executable = switch (builtin.os.tag) {
        .windows => manifest.winExecutablePath,
        else => if (manifest.runInWine) manifest.winExecutablePath else manifest.unixExecutablePath,
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
    renderer.waitForSpawn() catch |err| std.debug.panic("Failed to wait for renderer to spawn: {any}", .{err});

    log.info(@src(), "Renderer spawned!", .{});

    const renderer_pid = switch (builtin.os.tag) {
        .windows => @as(*anyopaque, @ptrFromInt(GetProcessId(renderer.id))),
        else => renderer.id,
    };

    bootstrap.sendRenderitePid(renderer_pid) catch @panic("Failed to send renderer PID to FrooxEngine");
    bootstrap.receiverLoop(gpa);
}

fn parseManifestFiles(gpa: std.mem.Allocator) ![]Manifest {
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
    const manifests = try gpa.alloc(Manifest, manifest_count);

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

pub extern "kernel32" fn GetProcessId(hProcess: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;

fn copy(text: [:0]const u8) anyerror!void {
    try sdl3.clipboard.setText(text);
}

fn paste() anyerror![:0]u8 {
    return try sdl3.clipboard.getText();
}

pub fn deinit(self: *DedicatedBootstrapper, gpa: std.mem.Allocator) void {
    self.json_arena.deinit();
    gpa.destroy(self);
}

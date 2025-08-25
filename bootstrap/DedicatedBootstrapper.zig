const std = @import("std");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");

const DedicatedBootstrapper = @This();

thread: std.Thread,
ready_to_boot: bool,

pub fn run(args: []const []const u8, gpa: std.mem.Allocator) !void {
    var bootstrapper: DedicatedBootstrapper = .{
        .ready_to_boot = true,
        .thread = undefined,
    };

    const thread = try std.Thread.spawn(.{}, bootstrapEngine, .{ &bootstrapper, args, gpa });
    defer thread.join();

    bootstrapper.thread = thread;
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

fn copy(text: [:0]const u8) anyerror!void {
    try sdl3.clipboard.setText(text);
}

fn paste() anyerror![:0]u8 {
    return try sdl3.clipboard.getText();
}

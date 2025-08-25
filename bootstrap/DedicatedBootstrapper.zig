const std = @import("std");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");

const DedicatedBootstrapper = @This();

thread: std.Thread,

pub fn run(args: []const []const u8, gpa: std.mem.Allocator) !void {
    const thread = try std.Thread.spawn(.{}, bootstrapEngine, .{ args, gpa });
    defer thread.join();
}

fn bootstrapEngine(args: []const []const u8, gpa: std.mem.Allocator) void {
    const child = renderite.Bootstrap.ChildInfo.init(gpa) catch @panic("Failed to start FrooxEngine");
    _ = child;
    _ = args;
}

fn copy(text: [:0]const u8) anyerror!void {
    try sdl3.clipboard.setText(text);
}

fn paste() anyerror![:0]u8 {
    return try sdl3.clipboard.getText();
}

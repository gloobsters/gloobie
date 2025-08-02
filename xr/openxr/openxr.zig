const std = @import("std");

const c = @import("c");

const Backend = struct {};

pub const InitError = error{} || std.mem.Allocator.Error;

pub fn init(gpa: std.mem.Allocator) InitError!*Backend {
    return try gpa.create(Backend);
}

pub fn deinit(gpa: std.mem.Allocator, backend: *Backend) void {
    gpa.destroy(backend);
}

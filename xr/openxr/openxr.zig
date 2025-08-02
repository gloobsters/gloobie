const std = @import("std");

const openxr = @import("openxr");

pub const name = "OpenXR";

const Backend = struct {};

pub const InitError = error{Todo} || std.mem.Allocator.Error;

pub fn init(gpa: std.mem.Allocator) InitError!*Backend {
    _ = gpa; // autofix

    return error.Todo;
    // return try gpa.create(Backend);
}

pub fn deinit(gpa: std.mem.Allocator, backend: *Backend) void {
    gpa.destroy(backend);
}

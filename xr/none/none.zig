const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");

pub const name = "None";

const Backend = void;

pub const InitError = error{Unimplemented};

pub const HandleEventsError = error{};

pub fn init(gpa: std.mem.Allocator) InitError!*Backend {
    _ = gpa;

    return InitError.Unimplemented;
}

pub fn deinit(gpa: std.mem.Allocator, backend: *Backend) void {
    _ = gpa;
    _ = backend;

    unreachable;
}

pub fn getGpuDevice(self: *Backend) gpu.Device {
    _ = self;

    unreachable;
}

pub fn handleEvents(self: *Backend) HandleEventsError!void {
    _ = self;

    unreachable;
}

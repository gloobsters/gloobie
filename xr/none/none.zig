const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");

pub const name = "None";

pub const Backend = void;

pub const InitError = error{Unimplemented};

pub const HandleEventsError = error{};

pub fn init(gpa: std.mem.Allocator) InitError!*Backend {
    _ = gpa;

    return InitError.Unimplemented;
}

pub fn deinit(gpa: std.mem.Allocator, backend: *Backend) noreturn {
    _ = gpa;
    _ = backend;

    unreachable;
}

pub fn getGpuDevice(self: *Backend) noreturn {
    _ = self;

    unreachable;
}

pub fn handleEvents(self: *Backend) noreturn {
    _ = self;

    unreachable;
}

pub fn sessionState(self: *Backend) noreturn {
    _ = self;

    unreachable;
}

pub fn openSession(backend: *Backend) noreturn {
    _ = backend;

    unreachable;
}

pub fn beginSession(backend: *Backend) noreturn {
    _ = backend;

    unreachable;
}

pub fn requestExit(backend: *Backend) noreturn {
    _ = backend;

    unreachable;
}

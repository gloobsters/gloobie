const std = @import("std");

const xr_t = @import("xr");

const log = @import("logger").Scoped(.app);

const XrData = @This();

lock: std.Thread.Mutex,

backend: *xr_t.Backend,

pub fn tryInit(gpa: std.mem.Allocator) !?XrData {
    const xr_backend: *xr_t.Backend = xr_t.init(gpa) catch |err| {
        log.err(@src(), "Got error {s} when trying to initialize XR backend.", .{@errorName(err)});

        return null;
    };
    errdefer xr_backend.deinit(gpa);

    log.info(@src(), "Initialized XR backend {s}", .{xr_t.name});
    return .{
        .lock = .{},
        .backend = xr_backend,
    };
}

pub fn deinit(self: XrData, gpa: std.mem.Allocator) void {
    self.backend.deinit(gpa);
}

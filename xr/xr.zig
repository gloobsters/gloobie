const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");

const impl = switch (build_options.xr_backend) {
    .none => @import("none/none.zig"),
    .openxr => @import("openxr/openxr.zig"),
};

pub const name = impl.name;

pub const SessionState = enum {
    /// The session is closed and can be created
    closed,
    /// The session is in a preparatory state
    preparing,
    /// The session is ready to be run
    ready,
    /// The session is actively running
    running,
};

pub const Backend = opaque {
    fn to(self: *Backend) *impl.Backend {
        return @ptrCast(@alignCast(self));
    }

    /// Gets the GPU device associated with the XR session
    pub fn getGpuDevice(backend: *Backend) gpu.Device {
        return impl.getGpuDevice(backend.to());
    }

    pub fn deinit(backend: *Backend, gpa: std.mem.Allocator) void {
        return impl.deinit(gpa, backend.to());
    }

    /// Handles all pending events from the XR runtime
    pub fn handleEvents(backend: *Backend) impl.HandleEventsError!void {
        return impl.handleEvents(backend.to());
    }

    pub fn sessionState(backend: *Backend) SessionState {
        return impl.sessionState(backend.to());
    }

    pub fn openSession(backend: *Backend) impl.OpenSessionError!void {
        return impl.openSession(backend.to());
    }

    /// Begin the XR session, only applicable when session is in `ready` state
    pub fn beginSession(backend: *Backend) impl.BeginSessionError!void {
        return impl.beginSession(backend.to());
    }

    /// Requests the session to exit the entire app, session must be in `running` sate
    pub fn requestExit(backend: *Backend) impl.RequestSessionExitError!void {
        return impl.requestExit(backend.to());
    }
};

pub fn init(gpa: std.mem.Allocator) impl.InitError!*Backend {
    return @ptrCast(try impl.init(gpa));
}

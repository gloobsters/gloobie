const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");

const impl = switch (build_options.xr_backend) {
    .none => @import("none/none.zig"),
    .openxr => @import("openxr/openxr.zig"),
};

pub const name = impl.name;

pub const State = enum {
    /// No session has been created
    no_session,
    /// Idle, awaiting some external factor
    idle,
    /// Ready to be started
    ready,
    /// VR is active
    active,
    /// VR is in the process of transitioning from stopping -> idle
    stopping,
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

    /// Gets the current state of the XR session
    pub fn sessionState(backend: *Backend) State {
        return impl.sessionState(backend.to());
    }

    /// Creates an XR session
    pub fn createSession(backend: *Backend) impl.CreateSessionError!void {
        return impl.createSession(backend.to());
    }

    /// Begins the XR session, if it's in the `ready` state
    pub fn beginSession(backend: *Backend) impl.BeginSessionError!void {
        return impl.beginSession(backend.to());
    }

    /// Requests the session to exit
    pub fn requestSessionExit(backend: *Backend) impl.RequestSessionExitError!void {
        return impl.requestSessionExit(backend.to());
    }
};

pub fn init(gpa: std.mem.Allocator) impl.InitError!*Backend {
    return @ptrCast(try impl.init(gpa));
}

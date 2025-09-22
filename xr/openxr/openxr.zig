const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const openxr = @import("openxr");
pub const BeginSessionError = openxr.BeginSessionError;
pub const EndSessionError = openxr.EndSessionError;
pub const RequestSessionExitError = openxr.RequestExitSessionError;
pub const OpenSessionError = openxr.ResultError;
const sdl3 = @import("sdl3");

const xr = @import("../xr.zig");

const log = @import("logger").Scoped(.openxr);

pub const name = "OpenXR";

const SessionData = struct {
    session: openxr.Session,

    state: openxr.SessionState,
    running: bool,

    pub fn deinit(self: SessionData, instance: openxr.Instance) void {
        // SAFETY: None of the errors are reachable since session is always valid
        instance.destroySession(self.session) catch unreachable;
    }
};

pub const Backend = struct {
    gpu_device: gpu.Device,
    instance: openxr.Instance,
    system_id: openxr.SystemId,

    session_data: ?SessionData,
};

pub const InitError = error{
    FailedToLoadOpenXR,
} || std.mem.Allocator.Error || sdl3.errors.Error || openxr.ResultError;

pub const HandleEventsError = openxr.EndSessionError || openxr.PollEventError;

pub fn init(gpa: std.mem.Allocator) InitError!*Backend {
    var instance: openxr.Instance = undefined;
    var system_id: openxr.SystemId = undefined;

    if (!gpu.openXrLoadLibrary()) {
        return InitError.FailedToLoadOpenXR;
    }
    errdefer gpu.openXrUnloadLibrary();

    const xr_get_proc_addr = gpu.openXrGetXrInstanceProcAddr();

    const gpu_device = try gpu.Device.initWithProperties(.{
        // TODO: enable based on compiled render backends
        .shaders_spirv = true,
        .debug_mode = build_options.safety,
        .xr_enable = true,
        .xr_instance_out = &instance,
        .xr_system_id_out = &system_id,
        .xr_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .xr_form_factor = .head_mounted_display,
        .xr_application_name = "gloobie",
        .xr_application_verison = 0x00000001,
        .xr_engine_name = "gloobie",
        .xr_engine_version = 0x00000001,
    });
    errdefer {
        // SAFETY: only error is handle invalid but that's not possible by here
        instance.deinit() catch unreachable;
        gpu_device.deinit();
    }

    instance.fn_ptrs = try openxr.loadFnPtrs(xr_get_proc_addr, instance.value, openxr.InstanceFnPtrs);

    const backend = try gpa.create(Backend);
    errdefer gpa.destroy(backend);

    backend.* = .{
        .gpu_device = gpu_device,
        .instance = instance,
        .system_id = system_id,

        .session_data = null,
    };

    return backend;
}

fn handleStateChange(
    self: *Backend,
    new_state: openxr.SessionState,
) openxr.EndSessionError!void {
    const session_data = &self.session_data.?;

    log.info(@src(), "Session state has changed to {s}, was {s}", .{ @tagName(new_state), @tagName(session_data.state) });
    session_data.state = new_state;

    switch (new_state) {
        .stopping => {
            try self.instance.endSession(session_data.session);
            session_data.running = false;
        },
        // If we're exiting or about to lose the session, immediately deinit the session
        .exiting, .loss_pending => {
            session_data.deinit(self.instance);
            self.session_data = null;
            return;
        },
        else => {},
    }
}
pub fn deinit(gpa: std.mem.Allocator, backend: *Backend) void {
    if (backend.session_data) |session_data| session_data.deinit(backend.instance);
    backend.instance.deinit() catch unreachable;

    gpa.destroy(backend);
    gpu.openXrUnloadLibrary();
}

pub fn getGpuDevice(self: *Backend) gpu.Device {
    return self.gpu_device;
}

pub fn handleEvents(self: *Backend) HandleEventsError!void {
    while (true) {
        var event: openxr.Event = .{ .data_buffer = .{ .varying = undefined } };
        if (!try self.instance.pollEvent(&event)) {
            break;
        }

        switch (event.data_buffer.type) {
            .event_data_session_state_changed => {
                const session_state_changed = event.session_state_changed;

                const session_data = &self.session_data.?;
                std.debug.assert(session_data.session.value == session_state_changed.session);

                try handleStateChange(self, session_state_changed.state);
            },
            else => {},
        }
    }
}

pub fn sessionState(backend: *Backend) xr.SessionState {
    if (backend.session_data) |session_data| {
        if (session_data.running) {
            return .running;
        }

        if (session_data.state == .ready) {
            return .ready;
        }

        return .preparing;
    } else {
        return .closed;
    }
}

pub fn openSession(self: *Backend) OpenSessionError!void {
    const session = try self.gpu_device.createXrSession(.{
        .system_id = self.system_id,
        .flags = .{},
    });
    errdefer self.instance.destroySession(session) catch unreachable;

    self.session_data = .{
        .session = session,

        // NOTE: spec defines session start in idle state
        .state = .idle,
        .running = false,
    };
}

pub fn beginSession(self: *Backend) BeginSessionError!void {
    const session_data = &self.session_data.?;

    std.debug.assert(session_data.state == .ready);

    // TODO: support other view configuration types
    try self.instance.beginSession(session_data.session, .{
        .primary_view_configuration_type = .primary_stereo,
    });

    session_data.running = true;
}

pub fn requestExit(self: *Backend) RequestSessionExitError!void {
    const session_data = &self.session_data.?;

    std.debug.assert(session_data.running);

    try self.instance.requestExitSession(session_data.session);
}

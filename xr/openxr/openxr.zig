const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const openxr = @import("openxr");
pub const CreateSessionError = openxr.ResultError;
pub const BeginSessionError = openxr.BeginSessionError;
pub const RequestSessionExitError = openxr.RequestExitSessionError;
const sdl3 = @import("sdl3");

const xr = @import("../xr.zig");

const log = @import("logger").Scoped(.openxr);

pub const name = "OpenXR";

const SessionData = struct {
    session: openxr.Session,
    state: openxr.SessionState,

    pub fn deinit(self: SessionData, instance: openxr.Instance) void {
        // SAFETY: None of the errors are reachable since session is always valid
        instance.destroySession(self.session) catch unreachable;
    }

    pub fn handleStateChange(self: *SessionData, new_state: openxr.SessionState) void {
        log.info(@src(), "Session state has changed to {s}, was {s}", .{ @tagName(new_state), @tagName(self.state) });
        self.state = new_state;
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

pub const HandleEventsError = error{} || openxr.PollEventError;

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

                session_data.handleStateChange(session_state_changed.state);
            },
            else => {},
        }
    }
}

pub fn sessionState(self: *Backend) xr.State {
    if (self.session_data) |session_data|
        return switch (session_data.state) {
            .idle => .idle,
            .ready => .ready,
            .synchronized, .visible, .focused => .active,
            .stopping => .stopping,
            .exiting => .idle,
        }
    else
        return .no_session;
}

pub fn createSession(self: *Backend) CreateSessionError!void {
    std.debug.assert(self.session_data == null);

    const session = try self.gpu.createXrSession(.{
        .system_id = self.system_id,
        .flags = .{},
    });
    errdefer self.instance.destroySession(session) catch unreachable;

    self.session_data = .{
        .session = session,

        // NOTE: According to the specification, all session start in idle
        .state = .idle,
    };
}

pub fn beginSession(self: *Backend) BeginSessionError!void {
    const session_data = &self.session_data.?;

    std.debug.assert(session_data.state == .ready);

    // TODO: don't have *only* primary stereo
    try self.instance.beginSession(session_data.session, .{
        .primary_view_configuration_type = .primary_stereo,
    });
}

pub fn requestSessionExit(self: *Backend) RequestSessionExitError!void {
    const session_data = &self.session_data.?;

    std.debug.assert(session_data.state == .synchronized or session_data.state == .visible or session_data.state == .focused);

    try self.instance.requestExitSession(session_data.session);
}

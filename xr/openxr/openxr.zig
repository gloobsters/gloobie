const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const openxr = @import("openxr");
const sdl3 = @import("sdl3");

const log = @import("logger").Scoped(.openxr);

pub const name = "OpenXR";

const Backend = struct {
    gpu_device: gpu.Device,
    instance: openxr.Instance,
    system_id: openxr.SystemId,
    session: openxr.Session,

    session_state: openxr.SessionState,
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

    const session = try gpu_device.createXrSession(.{
        .system_id = system_id,
        .flags = .{},
    });
    // SAFETY: only error is handle invalid but that's not possible by here
    errdefer instance.destroySession(session) catch unreachable;

    const backend = try gpa.create(Backend);
    errdefer gpa.destroy(backend);

    backend.* = .{
        .gpu_device = gpu_device,
        .instance = instance,
        .system_id = system_id,
        .session = session,

        // According to spec, sessions always start in "idle" state
        .session_state = .idle,
    };

    return backend;
}

pub fn deinit(gpa: std.mem.Allocator, backend: *Backend) void {
    // SAFETY: only error is handle invalid but that's not possible by here
    backend.instance.destroySession(backend.session) catch unreachable;
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

                log.info(@src(), "Session state has changed to {s}, was {s}", .{ @tagName(session_state_changed.state), @tagName(self.session_state) });
                self.session_state = session_state_changed.state;
            },
            else => {},
        }
    }
}

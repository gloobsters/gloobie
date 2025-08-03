const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const openxr = @import("openxr");
const sdl3 = @import("sdl3");

pub const name = "OpenXR";

const Backend = struct {
    gpu_device: gpu.Device,
    instance: openxr.Instance,
    system_id: openxr.SystemId,
};

pub const InitError = error{} || std.mem.Allocator.Error || sdl3.errors.Error;

pub fn init(gpa: std.mem.Allocator) InitError!*Backend {
    var instance: openxr.Instance = undefined;
    var system_id: openxr.SystemId = undefined;

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

    const backend = try gpa.create(Backend);
    errdefer gpa.destroy(backend);

    backend.* = .{
        .gpu_device = gpu_device,
        .instance = instance,
        .system_id = system_id,
    };

    return backend;
}

pub fn deinit(gpa: std.mem.Allocator, backend: *Backend) void {
    gpa.destroy(backend);
}

pub fn getGpuDevice(self: *Backend) gpu.Device {
    return self.gpu_device;
}

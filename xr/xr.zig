const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");

const impl = switch (build_options.xr_backend) {
    .openxr => @import("openxr/openxr.zig"),
    .openvr => @compileError("todo"),
};

pub const name = impl.name;

pub const Backend = opaque {
    pub fn getGpuDevice(backend: *Backend) gpu.Device {
        return impl.getGpuDevice(@ptrCast(@alignCast(backend)));
    }

    pub fn deinit(backend: *Backend, gpa: std.mem.Allocator) void {
        return impl.deinit(gpa, @ptrCast(@alignCast(backend)));
    }
};

pub fn init(gpa: std.mem.Allocator) impl.InitError!*Backend {
    return @ptrCast(try impl.init(gpa));
}

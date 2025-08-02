const std = @import("std");

const build_options = @import("options").build_options;

const impl = switch (build_options.xr_backend) {
    .openxr => @import("openxr/openxr.zig"),
    .openvr => @compileError("todo"),
};

pub const Backend = opaque {
    pub fn deinit(backend: *Backend, gpa: std.mem.Allocator) void {
        return impl.deinit(gpa, @ptrCast(@alignCast(backend)));
    }
};

pub fn init(gpa: std.mem.Allocator) impl.InitError!*Backend {
    return @ptrCast(try impl.init(gpa));
}

const std = @import("std");

const serialization = @import("serialization.zig");
const IpcSerializer = serialization.IpcSerializer;
const IpcDeserializer = serialization.IpcDeserializer;

const zinterprocess = @import("zinterprocess");
const MemoryView = zinterprocess.MemoryView;

pub const SharedMemoryBufferDescriptor = extern struct {
    buffer_id: i32,
    buffer_capacity: i32,
    offset: i32,
    length: i32,

    pub fn write(self: SharedMemoryBufferDescriptor, ipc: IpcSerializer) !void {
        try ipc.write(i32, self.buffer_id);
        try ipc.write(i32, self.buffer_capacity);
        try ipc.write(i32, self.offset);
        try ipc.write(i32, self.length);
    }

    pub fn read(ipc: IpcDeserializer) !SharedMemoryBufferDescriptor {
        return .{
            .buffer_id = try ipc.readInt(i32),
            .buffer_capacity = try ipc.readInt(i32),
            .offset = try ipc.readInt(i32),
            .length = try ipc.readInt(i32),
        };
    }
};

pub const SharedMemoryView = struct {
    view: MemoryView,
    descriptor: SharedMemoryBufferDescriptor,
    /// For reference counting.
    accesses: u8,

    pub fn init(prefix: []const u8, descriptor: SharedMemoryBufferDescriptor) !SharedMemoryView {
        var memory_view_buf: [std.fs.max_name_bytes]u8 = undefined;
        const memory_view_name = std.fmt.bufPrintZ(&memory_view_buf, "{s}{d}", .{ prefix, descriptor.buffer_id }) catch unreachable;

        const view = try MemoryView.init(.{
            .side = .Subscriber,
            .capacity = descriptor.buffer_capacity,
            .memory_view_name = memory_view_name,
        });

        return .{
            .view = view,
            .descriptor = descriptor,
            .accesses = 0,
        };
    }

    pub fn deinit(self: SharedMemoryView) void {
        if (self.accesses == 0) {
            self.view.deinit();
        }
    }
};

/// TODO: this needs to be thread-safe.
pub const SharedMemoryAccessor = struct {
    views: std.ArrayList(SharedMemoryView),
    prefix: []const u8,

    pub fn init(prefix: []const u8, gpa: std.mem.Allocator) !SharedMemoryAccessor {
        return .{
            .prefix = prefix,
            .views = .init(gpa),
        };
    }

    fn createView(self: SharedMemoryAccessor, descriptor: SharedMemoryBufferDescriptor) !SharedMemoryView {
        var view = try SharedMemoryView.init(self.prefix, descriptor);
        view.accesses = 1;
        try self.views.addOne(view);

        return view;
    }

    fn getView(self: SharedMemoryAccessor, descriptor: SharedMemoryBufferDescriptor) ?SharedMemoryView {
        for (self.views.items) |view| {
            if (view.descriptor.buffer_id == descriptor.buffer_id) {
                view.accesses += 1;
                return view;
            }
        }

        return null;
    }

    fn getOrCreateView(self: SharedMemoryAccessor, descriptor: SharedMemoryBufferDescriptor) !SharedMemoryView {
        const view = self.getView(descriptor);
        if (view != null) {
            return view.?;
        }

        return try self.createView(descriptor);
    }

    pub fn deinit(self: SharedMemoryAccessor) void {
        for (self.views.items) |*view| {
            view.accesses = 0;
            view.deinit();
        }

        self.views.deinit();
    }
};

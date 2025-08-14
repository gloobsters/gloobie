const std = @import("std");

const zinterprocess = @import("zinterprocess");
const MemoryView = zinterprocess.MemoryView;

const serialization = @import("serialization.zig");
const IpcSerializer = serialization.IpcSerializer;
const IpcDeserializer = serialization.IpcDeserializer;

const pooling = @import("pooling.zig");

const log = std.log.scoped(.shmem);

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

    pub fn compare(self: SharedMemoryBufferDescriptor, other: SharedMemoryBufferDescriptor) std.math.Order {
        return if (self.buffer_id == other.buffer_id) .eq else .lt;
    }
};

comptime {
    if (@sizeOf(SharedMemoryBufferDescriptor) != 16) {
        @compileError("Shared memory buffer descriptor has wrong length defined");
    }
}

pub const BufferId = enum(i32) {
    _,

    pub fn to(id: BufferId) i32 {
        return @intFromEnum(id);
    }

    pub fn from(id: i32) BufferId {
        return @enumFromInt(id);
    }
};

pub const SharedMemoryAccessor = struct {
    const BufferKey = pooling.SimpleKey(SharedMemoryBufferDescriptor);
    const Pool = pooling.FrameReferencedResourcePool([]const u8, BufferKey, MemoryView, createPoolValue, releasePoolValue, 120);

    pub fn Slice(comptime ChildType: type) type {
        return struct {
            buffer: BufferId,
            data: []align(1) ChildType,
            entry: Pool.Entry,
        };
    }

    pool: Pool,
    prefix: []const u8,

    pub fn init(gpa: std.mem.Allocator, prefix: []const u8) !SharedMemoryAccessor {
        const our_prefix = try gpa.dupe(u8, prefix);
        errdefer gpa.free(our_prefix);

        return .{
            .prefix = our_prefix,
            .pool = .init(our_prefix),
        };
    }

    pub fn getOrCreate(
        self: *SharedMemoryAccessor,
        comptime ChildType: type,
        descriptor: SharedMemoryBufferDescriptor,
    ) !?Slice(ChildType) {
        const buffer_id: BufferId = .from(descriptor.buffer_id);

        const offset: usize = @intCast(descriptor.offset);
        const length: usize = @intCast(descriptor.length);

        if (length == 0)
            return null;

        const entry = try self.pool.acquire(.{ .value = descriptor });

        return .{
            .buffer = buffer_id,
            .data = @ptrCast(entry.value.data[offset .. offset + length]),
            .entry = entry,
        };
    }

    fn createPoolValue(prefix: []const u8, key: BufferKey) !MemoryView {
        var memory_view_buf: [std.fs.max_path_bytes]u8 = undefined;
        const memory_view_name = std.fmt.bufPrintZ(&memory_view_buf, "{s}_{X}", .{ prefix, key.value.buffer_id }) catch unreachable;

        log.debug("Initializing shared memory view {s}", .{memory_view_name});

        return try MemoryView.init(.{
            .capacity = @intCast(key.value.buffer_capacity),
            .memory_view_name = memory_view_name,
        });
    }

    fn releasePoolValue(prefix: []const u8, view: MemoryView) void {
        _ = prefix;
        view.deinit();
    }

    pub fn release(self: *SharedMemoryAccessor, gpa: std.mem.Allocator, slice: anytype) void {
        self.pool.release(gpa, slice.entry) catch @panic("OOM while memory view returning to pool");
    }

    pub fn deinit(self: *SharedMemoryAccessor, gpa: std.mem.Allocator) void {
        self.pool.deinit(gpa);

        gpa.free(self.prefix);
    }
};

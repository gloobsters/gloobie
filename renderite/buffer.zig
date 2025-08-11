const std = @import("std");

const zinterprocess = @import("zinterprocess");
const MemoryView = zinterprocess.MemoryView;

const serialization = @import("serialization.zig");
const IpcSerializer = serialization.IpcSerializer;
const IpcDeserializer = serialization.IpcDeserializer;

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
    const Handle = struct {
        references: std.atomic.Value(usize),
        view: MemoryView,

        pub fn deinit(self: Handle) void {
            // SAFETY: nothing should have a reference on this by the time this is called!
            std.debug.assert(self.references.raw == 0);

            self.view.deinit();
        }
    };

    pub const Slice = struct {
        buffer: BufferId,
        data: []u8,

        pub fn release(self: Slice, accessor: *SharedMemoryAccessor) void {
            // SAFETY: buffer should always exist at this point
            const handle = accessor.handles.getPtr(self.buffer).?;

            const previous_references = handle.references.fetchSub(1, .seq_cst);

            // if the handle used to have 1 reference, and now has zero, we should de-init it.
            if (previous_references == 1) {
                accessor.freeHandle(self.buffer, handle);
            }
        }
    };

    lock: std.Thread.Mutex,
    handles: std.AutoHashMapUnmanaged(BufferId, Handle),
    prefix: []const u8,

    pub fn init(gpa: std.mem.Allocator, prefix: []const u8) !SharedMemoryAccessor {
        const our_prefix = try gpa.dupe(u8, prefix);
        errdefer gpa.free(our_prefix);

        return .{
            .handles = .empty,
            .prefix = our_prefix,
            .lock = .{},
        };
    }

    pub fn getOrCreate(self: *SharedMemoryAccessor, gpa: std.mem.Allocator, descriptor: SharedMemoryBufferDescriptor) !?Slice {
        self.lock.lock();
        defer self.lock.unlock();

        const buffer_id: BufferId = .from(descriptor.buffer_id);

        const offset: usize = @intCast(descriptor.offset);
        const length: usize = @intCast(descriptor.length);

        if (length == 0)
            return null;

        if (self.handles.getPtr(buffer_id)) |handle| {
            // Increment the references
            const previous_references = handle.references.fetchAdd(1, .seq_cst);
            std.debug.assert(previous_references > 0);

            return .{
                .buffer = buffer_id,
                .data = handle.view.data[offset .. offset + length],
            };
        }

        var memory_view_buf: [std.fs.max_path_bytes]u8 = undefined;
        const memory_view_name = std.fmt.bufPrintZ(&memory_view_buf, "{s}_{X}", .{ self.prefix, descriptor.buffer_id }) catch unreachable;

        log.debug("Initializing shared memory view {s}", .{memory_view_name});

        const view = try MemoryView.init(.{
            .capacity = @intCast(descriptor.buffer_capacity),
            .memory_view_name = memory_view_name,
        });

        const result = try self.handles.getOrPutValue(gpa, buffer_id, .{
            .view = view,
            .references = .init(1),
        });

        return .{
            .buffer = buffer_id,
            .data = result.value_ptr.view.data[offset .. offset + length],
        };
    }

    fn freeHandle(self: *SharedMemoryAccessor, buffer: BufferId, handle: *Handle) void {
        self.lock.lock();
        defer self.lock.unlock();

        handle.deinit();

        const was_present = self.handles.remove(buffer);
        std.debug.assert(was_present);

        var ctx: std.hash_map.AutoContext(BufferId) = .{};
        self.handles.rehash(&ctx);
    }

    pub fn deinit(self: *SharedMemoryAccessor, gpa: std.mem.Allocator) void {
        var iter = self.handles.valueIterator();
        while (iter.next()) |handle| {
            handle.deinit();
        }

        self.handles.deinit(gpa);

        gpa.free(self.prefix);
    }
};

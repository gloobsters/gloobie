const serialization = @import("serialization.zig");
const IpcSerializer = serialization.IpcSerializer;
const IpcDeserializer = serialization.IpcDeserializer;

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

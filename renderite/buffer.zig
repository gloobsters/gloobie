pub const SharedMemoryBufferDescriptor = packed struct {
    buffer_id: i32,
    buffer_capacity: i32,
    offset: i32,
    length: i32,
};

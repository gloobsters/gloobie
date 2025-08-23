const std = @import("std");

pub const CircularBuffer = struct {
    buffer: []u8,

    pub fn getPointer(self: CircularBuffer, offset: usize) [*]u8 {
        return self.buffer.ptr + self.adjustOffset(offset);
    }

    fn adjustOffset(self: CircularBuffer, offset: usize) usize {
        return offset % self.buffer.len;
    }

    pub fn read(self: CircularBuffer, offset: usize, out: []u8) void {
        if (out.len == 0) return;

        const read_offset = self.adjustOffset(offset);

        const source_buffer = self.buffer.ptr + read_offset;
        const right_len = @min(self.buffer.len - read_offset, out.len);
        @memcpy(out[0..right_len], source_buffer[0..right_len]);

        const left_len = out.len - right_len;
        @memcpy(out[right_len..out.len], self.buffer[0..left_len]);
    }

    pub fn write(self: CircularBuffer, data: []const u8, offset: usize) void {
        if (data.len == 0) return;

        const write_offset = self.adjustOffset(offset);
        const right_len = @min(self.buffer.len - write_offset, data.len);
        @memcpy(self.buffer[write_offset .. write_offset + right_len], data[0..right_len]);

        const left_len = data.len - right_len;
        @memcpy(self.buffer[0..left_len], data[right_len..data.len]);
    }

    // *const T is to force the compiler to not copy by value
    pub fn writeStruct(self: CircularBuffer, comptime T: type, data: *const T, offset: usize) void {
        const bytes: []const u8 = std.mem.asBytes(data);
        self.write(bytes, offset);
    }

    pub fn clear(self: CircularBuffer, offset: usize, len: usize) void {
        if (len == 0) return;

        const offset_adjusted = self.adjustOffset(offset);
        const right_len = @min(self.buffer.len - offset_adjusted, len);
        @memset(self.buffer[offset_adjusted .. offset_adjusted + right_len], 0);

        const left_len = len - right_len;
        @memset(self.buffer[0..left_len], 0);
    }
};

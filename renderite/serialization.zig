const std = @import("std");
const builtin = @import("builtin");

const Reader = std.io.Reader;
const Writer = std.io.Writer;

const endian = builtin.cpu.arch.endian();

pub const IpcDeserializer = struct {
    reader: *Reader,

    pub fn init(reader: *Reader) IpcDeserializer {
        return .{ .reader = reader };
    }

    pub fn readStruct(self: IpcDeserializer, comptime T: type, out: *T) !void {
        out.* = try self.reader.takeStruct(T, endian);
    }

    pub fn readInt(self: IpcDeserializer, comptime T: type, out: *T) !void {
        out.* = try self.reader.takeInt(T, endian);
    }

    pub fn readString(self: IpcDeserializer, allocator: std.mem.Allocator, out: *[]const u16) !void {
        const len = try self.reader.takeInt(i32, endian);
        out.* = try self.reader.readSliceEndianAlloc(allocator, u16, @intCast(len), endian);
    }
};

pub const IpcSerializer = struct {
    writer: *Writer,

    pub fn init(writer: *Writer) IpcSerializer {
        return .{ .writer = writer };
    }

    pub fn writeStruct(self: IpcSerializer, comptime T: type, value: T) !void {
        try self.writer.writeStruct(T, value, endian);
    }

    pub fn writeInt(self: IpcSerializer, comptime T: type, value: T) !void {
        try self.writer.writeInt(T, value, endian);
    }

    pub fn writeString(self: IpcSerializer, value: []const u16) !void {
        try self.writer.writeInt(i32, @intCast(value.len), endian);
        try self.writer.writeSliceEndian(u16, value, endian);
    }
};

test {
    const buf = [_]u8{ 42, 0, 0, 0 };

    var reader: Reader = std.io.Reader.fixed(&buf);
    var deserializer: IpcDeserializer = .init(&reader);

    var value: u32 = undefined;

    try deserializer.readInt(u32, &value);
    try std.testing.expectEqual(42, value);
}

test {
    const allocator = std.testing.allocator;
    const buf = [_]u8{ 5, 0, 0, 0, 't', 0, 'e', 0, 's', 0, 't', 0, '\n', 0 };

    var reader: Reader = std.io.Reader.fixed(&buf);
    var deserializer = IpcDeserializer.init(&reader);

    var value: []const u16 = undefined;

    try deserializer.readString(allocator, &value);
    defer allocator.free(value);

    const test_str = try std.unicode.utf8ToUtf16LeAlloc(allocator, "test\n");
    defer allocator.free(test_str);

    try std.testing.expectEqualSlices(u16, test_str, value);
}

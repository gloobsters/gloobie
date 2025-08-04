const std = @import("std");
const builtin = @import("builtin");

const Reader = std.io.Reader;
const Writer = std.io.Writer;

const endian = builtin.cpu.arch.endian();

pub const IpcDeserializer = struct {
    reader: *Reader,
    allocator: std.mem.Allocator,

    pub fn init(reader: *Reader, allocator: std.mem.Allocator) IpcDeserializer {
        return .{ .reader = reader, .allocator = allocator };
    }

    pub fn read(self: IpcDeserializer, comptime T: type) !T {
        switch (@typeInfo(T)) {
            // ."struct" => return try self.readStruct(T),
            .int => return try self.readInt(T),
            .pointer, .array => return try self.readString(self.allocator),
            .@"struct" => return try self.readStruct(T),
            .bool => return try self.readBool(),
            .@"enum" => return try self.readEnum(T),
            else => @compileError(std.fmt.comptimePrint("Unsupported type {s} for deserialization", .{@typeName(T)})),
        }
    }

    pub fn readStruct(self: IpcDeserializer, comptime T: type) !T {
        return try self.reader.takeStruct(T, endian);
    }

    pub fn readInt(self: IpcDeserializer, comptime T: type) !T {
        return try self.reader.takeInt(T, endian);
    }

    pub fn readEnum(self: IpcDeserializer, comptime T: type) !T {
        return @enumFromInt(try self.reader.takeInt(@typeInfo(T).@"enum".tag_type, endian));
    }

    pub fn readBool(self: IpcDeserializer) !bool {
        const value: u8 = try self.reader.takeByte();
        return value != 0;
    }

    pub fn readString(self: IpcDeserializer, allocator: std.mem.Allocator) ![]const u16 {
        const len = try self.reader.takeInt(i32, endian);
        return try self.reader.readSliceEndianAlloc(allocator, u16, @intCast(len), endian);
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

    const value: u32 = try deserializer.readInt(u32);

    try std.testing.expectEqual(42, value);
}

test {
    const allocator = std.testing.allocator;
    const buf = [_]u8{ 5, 0, 0, 0, 't', 0, 'e', 0, 's', 0, 't', 0, '\n', 0 };

    var reader: Reader = std.io.Reader.fixed(&buf);
    var deserializer = IpcDeserializer.init(&reader);

    const value: []const u16 = try deserializer.readString(allocator);
    defer allocator.free(value);

    const test_str = try std.unicode.utf8ToUtf16LeAlloc(allocator, "test\n");
    defer allocator.free(test_str);

    try std.testing.expectEqualSlices(u16, test_str, value);
}

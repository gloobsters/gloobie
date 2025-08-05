const std = @import("std");
const Reader = std.io.Reader;
const Writer = std.io.Writer;
const builtin = @import("builtin");
const buffer = @import("buffer.zig");
const SharedMemoryBufferDescriptor = buffer.SharedMemoryBufferDescriptor;

const endian = builtin.cpu.arch.endian();

pub const IpcDeserializer = struct {
    reader: *Reader,
    gpa: std.mem.Allocator,

    pub fn init(reader: *Reader, gpa: std.mem.Allocator) IpcDeserializer {
        return .{ .reader = reader, .gpa = gpa };
    }

    pub fn read(self: IpcDeserializer, comptime T: type) !T {
        if (T == []const u16) {
            return try self.readString(self.gpa);
        }

        switch (@typeInfo(T)) {
            // TODO: this needs work.
            .@"struct" => return try self.readObject(T),
            .int => return try self.readInt(T),
            .float => return try self.readFloat(T),
            // .pointer, .array => return try self.readString(self.allocator),
            // .@"struct" => return try self.readStruct(T),
            .bool => return try self.readBool(),
            .@"enum" => return try self.readEnum(T),
            .optional => return try self.readNullable(T),
            // else => @compileError(std.fmt.comptimePrint("Unsupported type {s} for deserialization", .{@typeName(T)})),
            else => return error.TypeNotSupported,
        }
    }

    pub fn readNullable(self: IpcDeserializer, comptime T: type) !T {
        if (try self.readBool()) {
            return try self.read(@typeInfo(T).optional.child);
        }
        return null;
    }

    pub fn readObject(self: IpcDeserializer, comptime T: type) !T {
        if (@hasDecl(T, "read")) {
            return try .read(self);
        }
        return try self.readStruct(T);
    }

    pub fn readList(self: IpcDeserializer, comptime T: type) !T {
        const BaseType = std.meta.Child(T);

        switch (@typeInfo(BaseType)) {
            .@"struct" => {
                if (@hasDecl(BaseType, "read")) {
                    return try self.readObjectList(BaseType, self.gpa);
                }
            },
            else => {},
        }

        return try self.readValueList(BaseType, self.gpa);
    }

    pub fn readStruct(self: IpcDeserializer, comptime T: type) !T {
        return try self.reader.takeStruct(T, endian);
    }

    pub fn readInt(self: IpcDeserializer, comptime T: type) !T {
        return try self.reader.takeInt(T, endian);
    }

    pub fn readFloat(self: IpcDeserializer, comptime T: type) !T {
        return std.mem.bytesAsValue(T, try self.reader.take(@sizeOf(T))).*;
    }

    pub fn readEnum(self: IpcDeserializer, comptime T: type) !T {
        return @enumFromInt(try self.reader.takeInt(@typeInfo(T).@"enum".tag_type, endian));
    }

    pub fn readBool(self: IpcDeserializer) !bool {
        const value: u8 = try self.reader.takeByte();
        return value != 0;
    }

    pub fn read8PackedBools(self: IpcDeserializer) !std.meta.Tuple(&.{ bool, bool, bool, bool, bool, bool, bool, bool }) {
        const value: u8 = try self.reader.takeByte();
        return .{ (value & 1) > 0, (value & 2) > 0, (value & 4) > 0, (value & 8) > 0, (value & 16) > 0, (value & 32) > 0, (value & 64) > 0, (value & 128) > 0 };
    }

    pub fn readString(self: IpcDeserializer, gpa: std.mem.Allocator) ![]const u16 {
        const len = try self.reader.takeInt(i32, endian);
        if (len == 0 or len == -1)
            return &.{};

        return try self.reader.readSliceEndianAlloc(gpa, u16, @intCast(len), endian);
    }

    pub fn readObjectList(self: IpcDeserializer, comptime T: type, gpa: std.mem.Allocator) ![]T {
        const len = try self.reader.takeInt(i32, endian);
        if (len == 0 or len == -1) // TODO: handle -1 meaning null
            return &.{};

        var list = try gpa.alloc(T, @intCast(len));

        for (0..list.len) |i| {
            list[i] = try .read(self);
        }

        return list;
    }

    pub fn readValueList(self: IpcDeserializer, comptime T: type, gpa: std.mem.Allocator) ![]T {
        const len = try self.reader.takeInt(i32, endian);
        if (len == 0 or len == -1) // TODO: handle -1 meaning null
            return &.{};

        return try self.reader.readSliceEndianAlloc(gpa, T, @intCast(len), endian);
    }
};

pub const IpcSerializer = struct {
    writer: *Writer,

    pub fn init(writer: *Writer) IpcSerializer {
        return .{ .writer = writer };
    }

    pub fn write(self: IpcSerializer, comptime T: type, value: T) !void {
        if (T == []const u16) {
            return try self.writeString(value);
        }

        switch (@typeInfo(T)) {
            // TODO: this needs work.
            // ."struct" => return try self.writeStruct(T),
            .int => return try self.writeInt(T, value),
            .float => return try self.writeFloat(T, value),
            // .pointer, .array => return try self.writeString(self.allocator),
            .@"struct" => return try self.writeObject(T, value),
            .bool => return try self.writeBool(value),
            .@"enum" => return try self.writeEnum(T, value),
            .vector => return try self.writeVector(T, value),
            // else => @compileError(std.fmt.comptimePrint("Unsupported type {s} for serialization", .{@typeName(T)})),
            else => return error.TypeNotSupported,
        }
    }

    pub fn writeList(self: IpcSerializer, comptime T: type, value: T) !void {
        const BaseType = std.meta.Child(T);

        switch (@typeInfo(BaseType)) {
            .@"struct" => {
                if (@hasDecl(BaseType, "write")) {
                    try self.writeObjectList(BaseType, value);
                    return;
                }
            },
            else => {},
        }

        try self.writeValueList(BaseType, value);
    }

    pub fn writeObject(self: IpcSerializer, comptime T: type, value: T) !void {
        if (@hasDecl(T, "write")) {
            return try value.write(self);
        }
        return try self.writeStruct(T, value);
    }

    pub fn writeStruct(self: IpcSerializer, comptime T: type, value: T) !void {
        try self.writer.writeStruct(value, endian);
    }

    pub fn writeInt(self: IpcSerializer, comptime T: type, value: T) !void {
        try self.writer.writeInt(T, value, endian);
    }

    pub fn writeFloat(self: IpcSerializer, comptime T: type, value: T) !void {
        try self.writer.writeAll(std.mem.asBytes(&value));
    }

    pub fn writeEnum(self: IpcSerializer, comptime T: type, value: T) !void {
        try self.writeInt(@typeInfo(T).@"enum".tag_type, @intFromEnum(value));
    }

    pub fn writeBool(self: IpcSerializer, value: bool) !void {
        try self.writeInt(u8, @intFromBool(value));
    }

    pub fn write8PackedBools(self: IpcSerializer, b0: bool, b1: bool, b2: bool, b3: bool, b4: bool, b5: bool, b6: bool, b7: bool) !void {
        try self.writer.writeByte(@as(u8, @intFromBool(b0)) | @as(u8, @intFromBool(b1)) << 1 | @as(u8, @intFromBool(b2)) << 2 | @as(u8, @intFromBool(b3)) << 3 |
            @as(u8, @intFromBool(b4)) << 4 | @as(u8, @intFromBool(b5)) << 5 | @as(u8, @intFromBool(b6)) << 6 | @as(u8, @intFromBool(b7)) << 7);
    }

    pub fn writeVector(self: IpcSerializer, comptime T: type, value: T) !void {
        const info = @typeInfo(T).vector;
        inline for (0..info.len) |i| {
            try self.writeFloat(info.child, value[i]);
        }
    }

    pub fn writeString(self: IpcSerializer, value: []const u16) !void {
        try self.writer.writeInt(i32, @intCast(value.len), endian);
        try self.writer.writeSliceEndian(u16, value, endian);
    }

    pub fn writeObjectList(self: IpcSerializer, comptime T: type, list: []const T) !void {
        try self.writer.writeInt(i32, @intCast(list.len), endian);
        for (list) |value| {
            try value.write(self);
        }
    }

    pub fn writeValueList(self: IpcSerializer, comptime T: type, list: []const T) !void {
        try self.writer.writeInt(i32, @intCast(list.len), endian);
        try self.writer.writeSliceEndian(T, list, endian);
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
    const gpa = std.testing.allocator;
    const buf = [_]u8{ 5, 0, 0, 0, 't', 0, 'e', 0, 's', 0, 't', 0, '\n', 0 };

    var reader: Reader = std.io.Reader.fixed(&buf);
    var deserializer = IpcDeserializer.init(&reader);

    const value: []const u16 = try deserializer.readString(gpa);
    defer gpa.free(value);

    const test_str = try std.unicode.utf8ToUtf16LeAlloc(gpa, "test\n");
    defer gpa.free(test_str);

    try std.testing.expectEqualSlices(u16, test_str, value);
}

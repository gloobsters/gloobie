const std = @import("std");
const Manifest = @This();

version: u8,
name: []const u8,
winExecutablePath: []const u8,
unixExecutablePath: []const u8,
runInWine: ?bool,

pub fn parseFromFile(file: std.fs.File, gpa: std.mem.Allocator) !std.json.Parsed(Manifest) {
    var buffer: [128]u8 = undefined;
    var file_reader = file.readerStreaming(&buffer);
    var reader = std.json.Reader.init(gpa, &file_reader.interface);
    defer reader.deinit();

    return try std.json.parseFromTokenSource(Manifest, gpa, &reader, .{
        .duplicate_field_behavior = .use_first,
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .parse_numbers = true,
        .max_value_len = std.fs.max_path_bytes,
    });
}

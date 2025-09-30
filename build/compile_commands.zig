// MIT License
//
// Copyright (c) 2025 Pablo Alessandro Santos Hugen
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const fs = std.fs;
const json = std.json;
const mem = std.mem;
const Build = std.Build;
const Step = Build.Step;
const Compile = Step.Compile;

const CompileCommands = []const Entry;

const Entry = struct {
    directory: []const u8,
    file: []const u8,
    arguments: ?[][]const u8 = null,
    command: ?[]const []const u8 = null,
    output: []const u8,
};

var result_path: []const u8 = undefined;
var cdb_path: []const u8 = undefined;

pub fn fromDir(allocator: mem.Allocator, path: []const u8) !CompileCommands {
    var dir = try fs.cwd().openDir(path, .{ .iterate = true, .access_sub_paths = true });
    defer dir.close();

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var it = try dir.walk(allocator);
    while (try it.next()) |f| if (f.kind == .file) {
        const file = try dir.openFile(f.path, .{});
        defer file.close();

        var contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        const entry = try json.parseFromSlice(
            @This().Entry,
            allocator,
            contents[0 .. contents.len - 2], // trailing comma
            .{ .ignore_unknown_fields = true },
        );
        entry.value.arguments.?[0] = "clang++";

        try entries.append(allocator, entry.value);
    };

    return try entries.toOwnedSlice(allocator);
}

fn makeFn(s: *Step, _: Step.MakeOptions) !void {
    const b = s.owner;

    var dir = try fs.cwd().openDir(cdb_path, .{});
    defer dir.close();

    const cc = try fromDir(b.allocator, cdb_path);
    const contents = try json.Stringify.valueAlloc(
        b.allocator,
        cc,
        .{
            .emit_null_optional_fields = false,
        },
    );

    const file = try fs.cwd().createFile(result_path, .{});
    defer file.close();
    try file.writeAll(contents);
}

pub fn createStep(b: *Build, cdb_dir_path: []const u8, result_file_path: []const u8) !*Step {
    result_path = result_file_path;
    cdb_path = cdb_dir_path;

    const step = try b.allocator.create(std.Build.Step);
    step.* = Step.init(.{
        .id = .custom,
        .name = "compile_commands",
        .makeFn = makeFn,
        .owner = b,
    });

    return step;
}

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32");
const zinterprocess = @import("zinterprocess");

const runtime_safety = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub fn main() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_alloc_impl.deinit() == .leak) @panic("memory leak");
    const gpa = if (runtime_safety) debug_alloc_impl.allocator() else std.heap.smp_allocator;
    _ = gpa;

    var tempPath: ?[]const u8 = null;

    if (builtin.os.tag == .windows) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;

        const len = win32.storage.file_system.GetTempPathA(@intCast(buffer.len), @ptrCast(&buffer));

        if (len == 0 or len > buffer.len) {
            std.debug.panic("GetTempPathA failed", .{});
        }

        tempPath = buffer[0..len];
    }

    const queue = try zinterprocess.Queue.init(.{
        .side = zinterprocess.Queue.Side.Publisher,
        .path = tempPath,
        .runtime_safety = runtime_safety,
        .capacity = 1024 * 1024,
        .memory_view_name = "sample-queue",
    });
    while (true) {
        queue.enqueue("test\n") catch |err| {
            if (err == zinterprocess.Queue.Error.QueueFull) {
                std.debug.print("Queue is full, waiting...\n", .{});
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            } else {
                return err;
            }
        };
        // const data = try queue.dequeue();
        // defer gpa.free(data);

        // std.debug.print("Received data: {s} ({d} bytes)\n", .{ data, data.len });

        // for (data) |byte| {
        //     std.debug.print("{X:0>2}", .{byte});
        // }

        // if (data.len > 0) {
        //     std.debug.print("\n", .{});
        // }
    }

    defer queue.deinit();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

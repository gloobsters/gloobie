const std = @import("std");

const win32 = @import("win32");

pub const MemoryFileError = error{
    MapFailed,
    ViewFailed,
};

pub const MemoryFile = if (@import("builtin").os.tag == .windows) MemoryFileWindows else MemoryFileUnix;
pub const MemoryFileOptions = struct {
    /// The unique name of the memory view.
    memory_view_name: []const u8 = "zinterprocess",
    /// The path to the directory in which the memory mapped file/other files will be stored.
    path: ?[]const u8 = null,
    /// The size of the memory view.
    capacity: u32 = 1024,
    /// Whether the memory view should be destroyed on deinit.
    /// This only deletes the backing file if a file path is specified.
    destroy_on_deinit: bool = false,
};

const MemoryFileWindows = struct {
    mapHandle: win32.foundation.HANDLE,
    data: []u8,
    data_ptr: [*]u8,

    pub fn init(options: MemoryFileOptions) !MemoryFileWindows {
        const capacity = options.capacity;

        var lp_name_buf: [std.fs.max_name_bytes]u8 = undefined;
        // SAFETY: valid names should _never_ exceed the name length limit
        const lp_name = std.fmt.bufPrintZ(&lp_name_buf, "CT_IP_{s}", .{options.memory_view_name}) catch unreachable;

        const mapHandle = try createOrOpenFileMapping(lp_name, options.capacity);

        const viewHandle = win32.system.memory.MapViewOfFile(
            mapHandle,
            win32.system.memory.FILE_MAP_ALL_ACCESS, // access
            0, // offset high
            0, // offset low
            options.capacity, // view size
        ) orelse return MemoryFileError.ViewFailed;

        const data_ptr: [*]u8 = @ptrCast(viewHandle);

        const file = MemoryFileWindows{
            .mapHandle = mapHandle,
            .data = data_ptr[0..capacity],
            .data_ptr = data_ptr,
        };

        return file;
    }

    fn createOrOpenFileMapping(name: [:0]const u8, capacity: u32) !*anyopaque {
        var wait_retries: usize = 14;
        var wait_sleep_ms: usize = 0;

        var handle: ?*anyopaque = null;

        while (wait_retries > 0) {
            handle = win32.system.memory.CreateFileMappingA(
                win32.foundation.INVALID_HANDLE_VALUE,
                null,
                win32.system.memory.PAGE_READWRITE,
                0,
                capacity,
                name.ptr,
            );

            if (handle != null) {
                break;
            }

            handle = win32.system.memory.OpenFileMappingA(
                @bitCast(win32.system.memory.FILE_MAP_ALL_ACCESS), // dumb windows api randomly uses dword here
                0,
                name,
            );

            if (handle != null) {
                break;
            } else {
                wait_retries -= 1;
                if (wait_sleep_ms == 0) {
                    wait_sleep_ms = 10;
                } else {
                    std.Thread.sleep(wait_sleep_ms * std.time.ns_per_ms);
                    wait_sleep_ms *= 2;
                }
            }
        }

        if (handle == null) {
            return error.MapFailed;
        }

        return handle.?;
    }

    pub fn deinit(self: MemoryFileWindows) void {
        _ = win32.foundation.CloseHandle(self.mapHandle);
    }
};

const MemoryFileUnix = struct {
    data: []align(std.heap.page_size_min) u8,

    pub fn init(options: MemoryFileOptions) !MemoryFileUnix {
        const path: []const u8 = if (options.path) |p| p else "/dev/shm/.cloudtoid/interprocess/mmf/";

        const file_ext = ".qu";
        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "{s}/{s}{s}", .{ path, options.memory_view_name, file_ext });

        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        try root.makePath(path);

        const file = try root.createFile(filename, .{
            .read = true,
            .truncate = false,
            .exclusive = false,
        });
        defer file.close();

        try file.setEndPos(options.capacity);

        const ptr = try std.posix.mmap(
            null,
            options.capacity,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        const mapped_file: MemoryFileUnix = .{
            .data = ptr,
        };
        return mapped_file;
    }

    pub fn deinit(self: MemoryFileUnix) void {
        std.posix.munmap(self.data);
    }
};

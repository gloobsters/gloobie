const std = @import("std");

const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;
const common = @import("common.zig");
const MemoryFile = @import("memory_view.zig").MemoryFile;
const MessageHeader = @import("message.zig").MessageHeader;
const MessageState = @import("message.zig").MessageState;

const log = std.log.scoped(.Queue);

pub const Options = struct {
    /// The side of the queue, either Publisher (write) or Subscriber (read).
    side: Side,
    /// The unique name of the memory view.
    memory_view_name: []const u8 = "zinterprocess",
    /// The path to the directory in which the memory mapped file/other files will be stored.
    path: ?[]const u8 = null,
    /// The size of the memory view.
    capacity: u32 = 1024,
    /// Whether the memory view should be destroyed on deinit.
    /// This only deletes the backing file if a file path is specified.
    destroy_on_deinit: bool = false,
    runtime_safety: bool = true,
};

pub const Side = enum { Publisher, Subscriber };

pub const Header = extern struct {
    read_offset: i64,
    write_offset: i64,
    read_lock_timestamp: i64,
    reserved: i64,

    pub fn isEmpty(self: Header) bool {
        return self.read_offset == self.write_offset;
    }
};

comptime {
    if (@sizeOf(Header) != 32)
        @compileError("Queue header size must be 32 bytes");
}

pub const Error = error{
    InvalidQueueSide,
    QueueEmpty,
    QueueFull,
    QueueReadLocked,
    PublisherCrashed,
    ReadLockFailed,
};

const Queue = @This();

side: Side,
memory_view: MemoryFile,
options: Options,
buffer: CircularBuffer,

pub fn init(options: Options) !Queue {
    const capacity = @sizeOf(Queue.Header) + options.capacity;
    const memory_view = try MemoryFile.init(.{
        .capacity = capacity,
        .destroy_on_deinit = options.destroy_on_deinit,
        .memory_view_name = options.memory_view_name,
        .path = options.path,
    });

    var header: *Header = @ptrCast(@alignCast(memory_view.data));
    if (options.side == .Publisher) {
        header.write_offset = 0;
    } else if (options.side == .Subscriber) {
        header.read_offset = 0;
        header.read_lock_timestamp = 0;
    }

    return .{
        .side = options.side,
        .memory_view = memory_view,
        .options = options,
        .buffer = .{
            .buffer = memory_view.data[@sizeOf(Header)..capacity],
        },
    };
}

pub fn deinit(self: Queue) void {
    self.memory_view.deinit();
}

fn getHeader(self: Queue) *Header {
    return @ptrCast(@alignCast(self.memory_view.data));
}

fn safeIncrementMessageOffset(self: Queue, offset: i64, increment: i64) i64 {
    const capacity: i64 = @intCast(self.buffer.buffer.len);
    return @mod(offset + increment, capacity * 2);
}

fn checkCapacity(self: Queue, header: *Header, message_length: usize) bool {
    const len: usize = self.buffer.buffer.len;
    const len_i: i64 = @intCast(len);

    if (message_length > len)
        return false;

    if (header.isEmpty())
        return true;

    const read_offset = @mod(header.read_offset, len_i);
    const write_offset = @mod(header.write_offset, len_i);

    if (read_offset == write_offset) {
        return false;
    }

    if (read_offset < write_offset) {
        if (@as(i64, @intCast(message_length)) > len_i + read_offset - write_offset) {
            return false;
        }
    } else if (@as(i64, @intCast(message_length)) > read_offset - write_offset) {
        return false;
    }

    return true;
}

pub fn dequeueOnce(self: Queue, gpa: std.mem.Allocator) ![]u8 {
    if (self.options.runtime_safety and self.side != Side.Subscriber) {
        return Error.InvalidQueueSide;
    }

    const header = self.getHeader();
    if (header.isEmpty())
        return Error.QueueEmpty;

    const read_lock_timestamp = header.read_lock_timestamp;
    const start = common.getTicks();

    const ticks_for_ten_seconds = (10 * std.time.ns_per_s) / 100;
    if (start - read_lock_timestamp < ticks_for_ten_seconds)
        return Error.QueueReadLocked;

    // take a read-lock so other threads can't read.
    if (@cmpxchgWeak(i64, &header.read_lock_timestamp, read_lock_timestamp, start, .seq_cst, .seq_cst) != null)
        return Error.ReadLockFailed;
    // release our read lock
    defer @atomicStore(i64, &header.read_lock_timestamp, 0, .seq_cst);

    if (header.isEmpty())
        return Error.QueueEmpty;

    const read_offset = header.read_offset;
    const write_offset = header.write_offset;
    const message_header: *MessageHeader = @ptrCast(@alignCast(self.buffer.getPointer(@intCast(read_offset))));

    while (true) {
        const state = @cmpxchgWeak(MessageState, &message_header.state, .ReadyToBeConsumed, .LockedToBeConsumed, .seq_cst, .seq_cst);

        if (state == null)
            break;

        if (common.getTicks() - start > ticks_for_ten_seconds) {
            log.warn("Publisher crashed. Queue header data was {any} (capacity: {d}), current header data was {any}", .{ header, self.buffer.buffer.len, message_header });
            @atomicStore(i64, &header.write_offset, write_offset, .seq_cst);
            return Error.PublisherCrashed;
        }

        // SAFETY: we don't particularly care if we can't yield here.
        std.Thread.yield() catch {};
    }

    const body_length: usize = @intCast(message_header.body_length);

    const buffer = try gpa.alloc(u8, body_length);
    self.buffer.read(common.messageBodyOffset(@intCast(read_offset)), buffer);

    const message_length = common.paddedMessageLength(body_length);
    self.buffer.clear(@intCast(read_offset), message_length);

    const newReadOffset = self.safeIncrementMessageOffset(read_offset, @intCast(message_length));
    @atomicStore(i64, &header.read_offset, newReadOffset, .seq_cst);

    return buffer;
}

pub fn dequeue(self: Queue, gpa: std.mem.Allocator) ![]u8 {
    while (true) {
        const result = self.dequeueOnce(gpa) catch |err| {
            if (err == Error.QueueEmpty) {
                // std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            } else {
                return err;
            }
        };

        return result;
    }
}

pub fn enqueue(self: Queue, message: []const u8) !void {
    if (self.options.runtime_safety and self.side != Side.Publisher) {
        return Error.InvalidQueueSide;
    }

    const body_length = message.len;
    const message_length = common.paddedMessageLength(body_length);

    while (true) {
        const header = self.getHeader();

        if (!self.checkCapacity(header, message_length)) {
            return Error.QueueFull;
        }

        const write_offset = header.write_offset;
        const new_write_offset = self.safeIncrementMessageOffset(write_offset, @intCast(message_length));

        if (@cmpxchgWeak(i64, &header.write_offset, write_offset, new_write_offset, .seq_cst, .seq_cst) == null) {
            // std.debug.print("Writing message with size {d}\n", .{message_length});

            self.buffer.writeStruct(MessageHeader, &.{ .body_length = @intCast(body_length), .state = .Writing }, @intCast(write_offset));
            self.buffer.write(message, common.messageBodyOffset(@intCast(write_offset)));
            self.buffer.writeStruct(MessageState, &.ReadyToBeConsumed, @intCast(write_offset));
            return;
        }
    }
}

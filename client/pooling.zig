const std = @import("std");

const log = std.log.scoped(.pooling);

pub fn FrameReferencedResourcePool(comptime Context: type, comptime Key: type, comptime Value: type, comptime frames_to_keep_entry: comptime_int) type {
    return struct {
        pub const Entry = struct {
            frames_since_usage: u32,
            value: Value,
            key: Key,
            size: u32,
        };

        const Self = @This();
        pub const CreateCallback = *const fn (ctx: Context, key: Key) Value;
        pub const ReleaseCallback = *const fn (ctx: Context, value: Value) void;

        lock: std.Thread.Mutex,
        // FIXME: this should be a doubly linked list for performance sake
        buffers: std.ArrayListUnmanaged(Entry),
        context: Context,
        create_callback: CreateCallback,
        release_callback: ReleaseCallback,

        pub fn init(context: Context, create_callback: CreateCallback, release_callback: ReleaseCallback) Self {
            return .{
                .lock = .{},
                .buffers = .empty,
                .context = context,
                .create_callback = create_callback,
                .release_callback = release_callback,
            };
        }

        pub fn acquire(self: *Self, size: u32, key: Key) !Entry {
            self.lock.lock();
            defer self.lock.unlock();

            const none_found = std.math.maxInt(usize);

            var smallest_index: usize = none_found;
            var smallest_size: usize = none_found;

            for (self.buffers.items, 0..) |entry, i| {
                if (entry.size >= size and entry.size < smallest_size and entry.key == key) {
                    smallest_index = i;
                    smallest_size = entry.size;

                    // we found one that is the smallest possible size, perfect fit!
                    if (entry.size == size) {
                        break;
                    }
                }
            }

            return if (smallest_index == none_found) create_entry: {
                break :create_entry .{
                    .size = size,
                    .key = key,
                    .frames_since_usage = 0,
                    .value = self.create_callback(self.context, key),
                };
            } else self.buffers.swapRemove(smallest_index);
        }

        pub fn release(self: *Self, gpa: std.mem.Allocator, entry: Entry) std.mem.Allocator.Error!void {
            self.lock.lock();
            defer self.lock.unlock();

            var entry_to_append = entry;

            entry_to_append.frames_since_usage = 0;
            try self.buffers.append(gpa, entry_to_append);
            log.debug("Released buffer {*} back into pool", .{entry.transfer_buffer.value});
        }

        pub fn frameTick(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();

            var i: usize = 0;
            while (i < self.buffers.items.len) {
                const entry = &self.buffers.items[i];

                entry.frames_since_usage += 1;

                if (entry.frames_since_usage >= frames_to_keep_entry) {
                    log.debug("Releasing {s} because it's been unused for {d} frames", .{ @typeName(Value), frames_to_keep_entry });
                    self.release_callback(self.context, entry.value);
                    _ = self.buffers.swapRemove(i);
                } else {
                    // if we *didnt* remove, add 1
                    i += 1;
                }
            }
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.lock.lock();
            defer self.lock.unlock();

            for (self.buffers.items) |entry| {
                log.debug("Releasing {s}", .{@typeName(Value)});
                self.release_callback(self.context, entry.value);
            }

            self.buffers.deinit(gpa);
        }
    };
}

test {
    _ = FrameReferencedResourcePool(u8, u8, u8, 120);
    std.testing.refAllDecls(@This());
}

const std = @import("std");

const log = std.log.scoped(.pooling);

pub fn SimpleKey(comptime Child: type) type {
    return struct {
        value: Child,

        const Self = @This();

        pub fn compare(self: Self, other: Self) std.math.Order {
            return if (self.value == other.value) .eq else .lt;
        }
    };
}

pub fn SizedKey(comptime Child: type) type {
    return struct {
        value: Child,
        size: usize,

        const Self = @This();

        pub fn compare(self: Self, other: Self) std.math.Order {
            if (self.size > other.size) {
                return .lt; // less than means it won't fit
            }

            if (self.size == other.size) {
                return .eq; // equals means it's an exact match
            }

            if (self.size < other.size) {
                return .gt; // greater than means it's a match, but not a perfect match
            }

            unreachable;
        }
    };
}

pub const StringKey = struct {
    value: []const u8,

    pub fn compare(self: StringKey, other: StringKey) std.math.Order {
        return if (std.mem.eql(u8, self.value, other.value)) .eq else .lt;
    }
};

pub fn FrameReferencedResourcePool(comptime Context: type, comptime Key: type, comptime Value: type, comptime create_val: anytype, comptime release_val: anytype, comptime frames_to_keep_entry: comptime_int) type {
    // errors to make this very clear on what to do
    comptime {
        if (!@hasDecl(Key, "compare"))
            @compileError("Key type is missing a 'compare' function. There are examples of key types in this source file.");
    }

    return struct {
        pub const Entry = struct {
            frames_since_usage: u32,
            value: Value,
            key: Key,
        };

        const Self = @This();

        lock: std.Thread.Mutex,
        // FIXME: this should be a doubly linked list for performance sake
        entries: std.ArrayListUnmanaged(Entry),
        context: Context,

        pub fn init(context: Context) Self {
            return .{
                .lock = .{},
                .entries = .empty,
                .context = context,
            };
        }

        pub fn acquire(self: *Self, key: Key) !Entry {
            self.lock.lock();
            defer self.lock.unlock();

            const none_found = std.math.maxInt(usize);

            var best_index: usize = none_found;
            var best_size: usize = none_found;

            for (self.entries.items, 0..) |entry, i| {
                switch (entry.key.compare(key)) {
                    .lt => continue,
                    .gt => {
                        if (@hasField(Key, "size")) {
                            // If this is sized, only update the best index if the new entry's size is less than the current best size
                            if (entry.key.size < best_size) {
                                best_index = i;
                                best_size = entry.key.size;
                            }
                        } else {
                            best_index = i;
                        }
                    },
                    .eq => {
                        best_index = i;
                        break;
                    },
                }
            }

            return if (best_index == none_found) .{
                .key = key,
                .frames_since_usage = 0,
                .value = try create_val(self.context, key),
            } else self.entries.swapRemove(best_index);
        }

        pub fn release(self: *Self, gpa: std.mem.Allocator, entry: Entry) std.mem.Allocator.Error!void {
            self.lock.lock();
            defer self.lock.unlock();

            var entry_to_append = entry;

            entry_to_append.frames_since_usage = 0;
            try self.entries.append(gpa, entry_to_append);
            log.debug("Released entry {s} back into pool", .{@typeName(Value)});
        }

        pub fn frameTick(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();

            var i: usize = 0;
            while (i < self.entries.items.len) {
                const entry = &self.entries.items[i];

                entry.frames_since_usage += 1;

                if (entry.frames_since_usage >= frames_to_keep_entry) {
                    log.debug("Releasing {s} because it's been unused for {d} frames", .{ @typeName(Value), frames_to_keep_entry });
                    release_val(self.context, entry.value);
                    _ = self.entries.swapRemove(i);
                } else {
                    // if we *didnt* remove, add 1
                    i += 1;
                }
            }
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.lock.lock();
            defer self.lock.unlock();

            for (self.entries.items) |entry| {
                log.debug("Releasing {s}", .{@typeName(Value)});
                release_val(self.context, entry.value);
            }

            self.entries.deinit(gpa);
        }
    };
}

fn dummyCreateCallback(ctx: u8, key: anytype) !u8 {
    _ = ctx;
    _ = key;
    return 69;
}

fn dummyReleaseCallback(ctx: u8, val: u8) void {
    _ = ctx;
    _ = val;
}

test {
    _ = FrameReferencedResourcePool(u8, SimpleKey(u8), u8, dummyCreateCallback, dummyReleaseCallback, 120);
    _ = FrameReferencedResourcePool(u8, StringKey, u8, dummyCreateCallback, dummyReleaseCallback, 120);
    _ = FrameReferencedResourcePool(u8, SizedKey(u8), u8, dummyCreateCallback, dummyReleaseCallback, 120);
    std.testing.refAllDecls(@This());
}

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

pub fn FrameReferencedResourcePool(comptime Context: type, comptime Key: type, comptime Value: type, comptime create_callback: anytype, comptime release_callback: anytype, comptime frames_to_keep_entry: comptime_int) type {
    // errors to make this very clear on what to do
    comptime {
        if (std.meta.activeTag(@typeInfo(Key)) != .@"struct")
            @compileError("Key type must be a struct. There are examples of key types in this source file.");

        if (!@hasDecl(Key, "compare"))
            @compileError("Key type is missing an 'eql' function. There are examples of key types in this source file.");

        if (!@hasField(Key, "value"))
            @compileError("Key type is missing the 'value' field. There are examples of key types in this source file.");
    }

    return struct {
        pub const Entry = struct {
            frames_since_usage: u32,
            value: Value,
            key: Key,
        };

        const Self = @This();
        pub const CreateCallback = *const fn (ctx: Context, key: Key) Value;
        pub const ReleaseCallback = *const fn (ctx: Context, value: Value) void;

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

            var smallest_index: usize = none_found;
            var smallest_size: usize = none_found;

            for (self.entries.items, 0..) |entry, i| {
                const comparison = entry.key.compare(key);

                if (comparison == .lt)
                    continue;

                if (comparison != .gt) {
                    smallest_index = i;
                    if (@hasField(Key, "size"))
                        smallest_size = entry.key.size;
                }

                if (comparison == .eq)
                    break;
            }

            return if (smallest_index == none_found) .{
                .key = key,
                .frames_since_usage = 0,
                .value = create_callback(self.context, key),
            } else self.entries.swapRemove(smallest_index);
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
                    release_callback(self.context, entry.value);
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
                release_callback(self.context, entry.value);
            }

            self.entries.deinit(gpa);
        }
    };
}

test {
    _ = FrameReferencedResourcePool(u8, SimpleKey(u8), u8, 120);
    _ = FrameReferencedResourcePool(u8, StringKey, u8, 120);
    _ = FrameReferencedResourcePool(u8, SizedKey(u8), u8, 120);
    std.testing.refAllDecls(@This());
}

const std = @import("std");

const gpu = @import("gpu");

const App = @import("App.zig");
const Assets = @import("Assets.zig");
const Texture = @import("Texture.zig");

const log = std.log.scoped(.graphics);

pub const TransferBufferPool = struct {
    // The amount of frames to keep an entry before releasing it
    const frames_to_keep_entry = 120;

    pub const Entry = struct {
        frames_since_usage: u32,
        transfer_buffer: gpu.TransferBuffer,
        usage: gpu.TransferBufferUsage,
        size: u32,
    };

    lock: std.Thread.Mutex,
    // FIXME: this should be a doubly linked list for performance sake
    buffers: std.ArrayListUnmanaged(Entry),
    device: gpu.Device,

    pub fn init(device: gpu.Device) TransferBufferPool {
        return .{
            .lock = .{},
            .buffers = .empty,
            .device = device,
        };
    }

    /// Acquires the smallest possible transfer buffer that fits into.
    ///
    /// You must cycle the returned transfer buffer!!!
    pub fn acquire(self: *TransferBufferPool, size: u32, usage: gpu.TransferBufferUsage) !Entry {
        self.lock.lock();
        defer self.lock.unlock();

        const none_found = std.math.maxInt(usize);

        var smallest_index: usize = none_found;
        var smallest_size: usize = none_found;
        // find the first buffer which is small enough
        for (self.buffers.items, 0..) |entry, i| {
            if (entry.size >= size and entry.size < smallest_size and entry.usage == usage) {
                smallest_index = i;
                smallest_size = entry.size;

                // we found one that is the smallest possible size, perfect fit!
                if (entry.size == size) {
                    break;
                }
            }
        }

        return if (smallest_index == none_found) create_entry: {
            var buffer_name_buf: [64]u8 = undefined;
            // SAFETY: it's big enough
            const buffer_name = std.fmt.bufPrintZ(&buffer_name_buf, "Pooled Transfer Buffer (size {d})", .{size}) catch unreachable;

            const transfer_buffer = try self.device.createTransferBuffer(.{
                .usage = usage,
                .size = size,
                .props = .{ .name = buffer_name },
            });
            errdefer self.device.releaseTransferBuffer(transfer_buffer);

            break :create_entry .{
                .size = size,
                .usage = usage,
                .frames_since_usage = 0,
                .transfer_buffer = transfer_buffer,
            };
        } else self.buffers.swapRemove(smallest_index);
    }

    pub fn release(self: *TransferBufferPool, gpa: std.mem.Allocator, entry: Entry) std.mem.Allocator.Error!void {
        self.lock.lock();
        defer self.lock.unlock();

        var entry_to_append = entry;

        entry_to_append.frames_since_usage = 0;
        try self.buffers.append(gpa, entry_to_append);
        log.debug("Released buffer {*} back into pool", .{entry.transfer_buffer.value});
    }

    pub fn frameTick(self: *TransferBufferPool) void {
        self.lock.lock();
        defer self.lock.unlock();

        var i: usize = 0;
        while (i < self.buffers.items.len) {
            const entry = &self.buffers.items[i];

            entry.frames_since_usage += 1;

            if (entry.frames_since_usage >= frames_to_keep_entry) {
                log.debug("Releasing transfer buffer {*} because it's been unused for {d} frames", .{ entry.transfer_buffer.value, frames_to_keep_entry });
                self.device.releaseTransferBuffer(entry.transfer_buffer);
                _ = self.buffers.swapRemove(i);
            } else {
                // if we *didnt* remove, add 1
                i += 1;
            }
        }
    }

    pub fn deinit(self: *TransferBufferPool, gpa: std.mem.Allocator) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.buffers.items) |entry| {
            log.debug("Releasing transfer buffer {*}", .{entry.transfer_buffer.value});
            self.device.releaseTransferBuffer(entry.transfer_buffer);
        }

        self.buffers.deinit(gpa);
    }
};

pub fn FenceHandler(comptime ContextType: type, comptime func: anytype, comptime deinit_func: anytype, comptime type_name: [:0]const u8) type {
    return struct {
        pub const name = type_name;
        pub const function = func;
        pub const deinit_function = deinit_func;

        pub const Context = ContextType;

        context: Context,
    };
}

pub fn FenceManager(comptime FenceHandlers: []const type) type {
    var union_fields: [FenceHandlers.len]std.builtin.Type.UnionField = undefined;
    var enum_fields: [FenceHandlers.len]std.builtin.Type.EnumField = undefined;
    for (FenceHandlers, &union_fields, &enum_fields, 0..) |Field, *union_field, *enum_member, i| {
        union_field.* = .{
            .name = Field.name,
            .type = Field,
            .alignment = @alignOf(Field),
        };

        enum_member.* = .{
            .name = Field.name,
            .value = i,
        };
    }

    const UnionTag = @Type(.{ .@"enum" = .{
        .tag_type = u32,
        .fields = &enum_fields,
        .is_exhaustive = true,
        .decls = &.{},
    } });

    const Union = @Type(.{ .@"union" = .{
        .fields = &union_fields,
        .layout = .auto,
        .tag_type = UnionTag,
        .decls = &.{},
    } });

    return struct {
        const Entry = struct {
            fence: gpu.Fence,
            handler: Union,
        };

        const Self = @This();

        lock: std.Thread.Mutex,
        device: gpu.Device,
        entries: std.ArrayListUnmanaged(Entry),

        pub fn init(device: gpu.Device) Self {
            return .{
                .entries = .empty,
                .device = device,
                .lock = .{},
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.lock.lock();
            defer self.lock.unlock();

            for (self.entries.items) |entry| {
                defer self.device.releaseFence(entry.fence);

                // deinit the handler
                switch (entry.handler) {
                    inline else => |handler| {
                        const Handler = @TypeOf(handler);

                        Handler.deinit_function(handler.context);
                    },
                }
            }

            self.entries.deinit(gpa);
        }

        pub fn enqueue(self: *Self, gpa: std.mem.Allocator, fence: gpu.Fence, comptime Handler: type, context: Handler.Context) !void {
            self.lock.lock();
            defer self.lock.unlock();

            try self.entries.append(gpa, .{
                .fence = fence,
                .handler = @unionInit(Union, Handler.name, .{ .context = context }),
            });
        }

        pub fn tick(self: *Self) !void {
            self.lock.lock();
            defer self.lock.unlock();

            var i: usize = 0;
            while (i < self.entries.items.len) {
                const entry = self.entries.items[i];

                if (self.device.queryFence(entry.fence)) {
                    defer self.device.releaseFence(entry.fence);

                    switch (entry.handler) {
                        inline else => |handler| {
                            const Handler = @TypeOf(handler);

                            defer Handler.deinit_function(handler.context);

                            try Handler.function(handler.context);
                        },
                    }

                    _ = self.entries.orderedRemove(i);
                } else {
                    // only increment if we didnt remove
                    i += 1;
                }
            }
        }
    };
}

pub const FrameContext = struct {
    device: gpu.Device,
    command_buffer: ?gpu.CommandBuffer,
    copy_pass: ?gpu.CopyPass,
    transfer_buffer_pool: *TransferBufferPool,
    assets: *Assets,
    texture_readiness_queue: std.ArrayListUnmanaged(Assets.TextureHandle),
    main_thread: bool,
    fence_manager: *App.FenceManager,
    messaging_host: *App.MessagingHost,

    pub fn initMain(
        device: gpu.Device,
        transfer_buffer_pool: *TransferBufferPool,
        assets: *Assets,
        command_buffer: gpu.CommandBuffer,
        fence_manager: *App.FenceManager,
        messaging_host: *App.MessagingHost,
    ) FrameContext {
        return .{
            .device = device,
            .command_buffer = command_buffer,
            .copy_pass = null,
            .transfer_buffer_pool = transfer_buffer_pool,
            .assets = assets,
            .texture_readiness_queue = .empty,
            .main_thread = true,
            .fence_manager = fence_manager,
            .messaging_host = messaging_host,
        };
    }

    pub fn init(
        device: gpu.Device,
        transfer_buffer_pool: *TransferBufferPool,
        assets: *Assets,
        fence_manager: *App.FenceManager,
        messaging_host: *App.MessagingHost,
    ) FrameContext {
        return .{
            .device = device,
            .command_buffer = null,
            .copy_pass = null,
            .transfer_buffer_pool = transfer_buffer_pool,
            .assets = assets,
            .texture_readiness_queue = .empty,
            .main_thread = false,
            .fence_manager = fence_manager,
            .messaging_host = messaging_host,
        };
    }

    pub fn getCommandBuffer(self: *FrameContext) !gpu.CommandBuffer {
        if (self.command_buffer) |command_buffer| {
            return command_buffer;
        }

        const command_buffer = try self.device.acquireCommandBuffer();

        self.command_buffer = command_buffer;

        return command_buffer;
    }

    /// Gets a copy pass shared for the whole frame, all copy commands should happen with this copy pass, so don't end it!
    ///
    /// On the main thread, this is guarenteed to execute *before* the render passes. On other threads, you need to synchronize somehow!
    pub fn getSharedCopyPass(self: *FrameContext) !gpu.CopyPass {
        if (self.copy_pass) |copy_pass| {
            return copy_pass;
        }

        const command_buffer = try self.getCommandBuffer();

        const copy_pass = command_buffer.beginCopyPass();

        self.copy_pass = copy_pass;

        return copy_pass;
    }

    fn commandBufferUsed(self: FrameContext) bool {
        return self.copy_pass != null;
    }

    pub fn end(self: *FrameContext, gpa: std.mem.Allocator) !void {
        defer self.texture_readiness_queue.clearAndFree(gpa);

        if (self.copy_pass) |copy_pass| {
            copy_pass.end();
        }

        // we don't submit the main thread's command buffer!
        if (self.main_thread) {
            if (self.texture_readiness_queue.items.len > 0) {
                // on the main thread, this copy pass is guarenteed to end before any render pass takes place, so let's do it immediately
                try Assets.TextureReadyFenceHandler.function(.{
                    .gpa = gpa,
                    .assets = self.assets,
                    .textures = self.texture_readiness_queue.items,
                });
            }
        } else if (self.command_buffer) |command_buffer| {
            if (self.commandBufferUsed()) {
                // if we have textures that will be ready after this data is submit,
                // then we need to acquire the fence and ship it off to the asset manager so it gets polled by the main thread
                if (self.texture_readiness_queue.items.len > 0) {
                    const fence = try command_buffer.submitAndAcquireFence();
                    errdefer self.device.releaseFence(fence);

                    const textures = try self.texture_readiness_queue.toOwnedSlice(gpa);
                    errdefer gpa.free(textures);

                    try self.fence_manager.enqueue(gpa, fence, Assets.TextureReadyFenceHandler, .{
                        .gpa = gpa,
                        .assets = self.assets,
                        .textures = textures,
                    });
                } else {
                    try command_buffer.submit();
                }
            } else {
                try command_buffer.cancel();
            }
        }

        self.copy_pass = null;
        self.command_buffer = null;
    }
};

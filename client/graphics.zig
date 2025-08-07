const std = @import("std");

const gpu = @import("gpu");

const Assets = @import("Assets.zig");
const Texture = @import("Texture.zig");

const log = std.log.scoped(.graphics);

pub const TransferBufferPool = struct {
    // The amount of frames to keep an entry before releasing it
    const frames_to_keep_entry = 10;

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
            if (entry.size >= size and entry.size < smallest_size) {
                smallest_index = i;
                smallest_size = entry.size;

                // we found one that is the smallest possible size, perfect fit!
                if (entry.size == size) {
                    break;
                }
            }
        }

        return if (smallest_index == none_found) create_entry: {
            const transfer_buffer = try self.device.createTransferBuffer(.{
                .usage = usage,
                .size = size,
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
    }

    pub fn frameTick(self: *TransferBufferPool) void {
        self.lock.lock();
        defer self.lock.unlock();

        var i: usize = 0;
        while (i < self.buffers.items.len) : (i += 1) {
            const entry = &self.buffers.items[i];

            entry.frames_since_usage += 1;

            if (entry.frames_since_usage >= frames_to_keep_entry) {
                log.debug("Releasing transfer buffer {*} because it's been unused for {d} frames", .{ entry.transfer_buffer.value, frames_to_keep_entry });
                self.device.releaseTransferBuffer(entry.transfer_buffer);
                _ = self.buffers.swapRemove(i);
                i -= 1;
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

pub const FrameContext = struct {
    device: gpu.Device,
    command_buffer: ?gpu.CommandBuffer,
    copy_pass: ?gpu.CopyPass,
    transfer_buffer_pool: *TransferBufferPool,
    assets: *Assets,
    texture_readiness_queue: std.ArrayListUnmanaged(Assets.TextureReadynessState),
    main_thread: bool,

    pub fn init(
        device: gpu.Device,
        transfer_buffer_pool: *TransferBufferPool,
        assets: *Assets,
        main_thread: bool,
    ) FrameContext {
        return .{
            .device = device,
            .command_buffer = null,
            .copy_pass = null,
            .transfer_buffer_pool = transfer_buffer_pool,
            .assets = assets,
            .texture_readiness_queue = .empty,
            .main_thread = main_thread,
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

    pub fn getCopyPass(self: *FrameContext) !gpu.CopyPass {
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

        if (self.command_buffer) |command_buffer| {
            if (self.commandBufferUsed()) {
                // if we have textures that will be ready after this data is submit,
                // then we need to acquire the fence and ship it off to the assets manager,
                // but only do this when not on the main thread
                if (self.texture_readiness_queue.items.len > 0) {
                    // on the main thread we have guarentees that the copy pass will finish before rendering
                    if (self.main_thread) {
                        try command_buffer.submit();

                        for (self.texture_readiness_queue.items) |textures| {
                            textures.texture.graphics_data.?.ready = textures.ready;
                        }
                    } else {
                        const fence = try command_buffer.submitAndAcquireFence();
                        errdefer self.device.releaseFence(fence);

                        self.assets.lock.lock();
                        defer self.assets.lock.unlock();

                        try self.assets.texture_2ds_readyness.append(gpa, .{
                            .fence = fence,
                            .items = self.texture_readiness_queue,
                        });
                        self.texture_readiness_queue = .empty;
                    }
                } else {
                    try command_buffer.submit();
                }
            } else {
                try command_buffer.cancel();
            }
        }

        self.copy_pass = null;
        self.command_buffer = null;

        self.transfer_buffer_pool.frameTick();
    }
};

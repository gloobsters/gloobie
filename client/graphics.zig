const std = @import("std");

const gpu = @import("gpu");

const App = @import("App.zig");
const Assets = @import("Assets.zig");
const Texture = @import("Texture.zig");
const pooling = @import("pooling.zig");

const log = std.log.scoped(.graphics);

pub const TransferBufferPool = pooling.FrameReferencedResourcePool(gpu.Device, pooling.SizedKey(gpu.TransferBufferUsage), gpu.TransferBuffer, 120);

fn createTransferBuffer(device: gpu.Device, key: TransferBufferPool.Key) gpu.TransferBuffer {
    var buffer_name_buf: [64]u8 = undefined;
    // SAFETY: it's big enough
    const buffer_name = std.fmt.bufPrintZ(&buffer_name_buf, "Pooled Transfer Buffer (size {d})", .{key.size}) catch unreachable;

    const transfer_buffer = device.createTransferBuffer(.{
        .usage = key.value,
        .size = @intCast(key.size),
        .props = .{ .name = buffer_name },
    }) catch @panic("Couldn't create transfer buffer"); // TODO: do we want to panic here?
    errdefer device.releaseTransferBuffer(transfer_buffer);

    return transfer_buffer;
}

fn releaseTransferBuffer(device: gpu.Device, buffer: gpu.TransferBuffer) void {
    device.releaseTransferBuffer(buffer);
}

pub fn initTransferBufferPool(device: gpu.Device) TransferBufferPool {
    return .init(device, createTransferBuffer, releaseTransferBuffer);
}

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

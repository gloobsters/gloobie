const std = @import("std");

const gpu = @import("gpu");
const math = @import("math");

const App = @import("App.zig");
const Assets = @import("assets/Assets.zig");
const Texture = @import("assets/Texture.zig");
const pooling = @import("pooling.zig");

const log = @import("logger").Scoped(.graphics);

pub const TransferBufferPool = pooling.FrameReferencedResourcePool(
    gpu.Device,
    pooling.SizedKey(gpu.TransferBufferUsage),
    gpu.TransferBuffer,
    createTransferBuffer,
    releaseTransferBuffer,
    120,
);

pub const BlendshapeOffset = extern struct {
    position_offset: math.Vector3f,
    normal_offset: math.Vector3f,
    tangent_offset: math.Vector3f,
};

fn createTransferBuffer(device: gpu.Device, key: pooling.SizedKey(gpu.TransferBufferUsage)) !gpu.TransferBuffer {
    var buffer_name_buf: [64]u8 = undefined;
    // SAFETY: it's big enough
    const buffer_name = std.fmt.bufPrintZ(&buffer_name_buf, "Pooled Transfer Buffer (size {d})", .{key.size}) catch unreachable;

    const transfer_buffer = try device.createTransferBuffer(.{
        .usage = key.value,
        .size = @intCast(key.size),
        .props = .{ .name = buffer_name },
    });
    errdefer device.releaseTransferBuffer(transfer_buffer);

    return transfer_buffer;
}

fn releaseTransferBuffer(device: gpu.Device, buffer: gpu.TransferBuffer) void {
    device.releaseTransferBuffer(buffer);
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

                if (FenceHandlers.len > 0) {
                    // deinit the handler
                    switch (entry.handler) {
                        inline else => |handler| {
                            const Handler = @TypeOf(handler);

                            Handler.deinit_function(handler.context);
                        },
                    }
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

                    if (FenceHandlers.len > 0) {
                        switch (entry.handler) {
                            inline else => |handler| {
                                const Handler = @TypeOf(handler);

                                defer Handler.deinit_function(handler.context);

                                try Handler.function(handler.context);
                            },
                        }
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
    texture_readiness_queue: std.ArrayListUnmanaged(struct { handle: Assets.TextureHandle, nonce: u64 }),
    mesh_readiness_queue: std.ArrayListUnmanaged(struct { handle: Assets.Id, nonce: u64 }),
    main_thread: bool,
    fence_manager: *App.FenceManager,
    messaging_host: *App.MessagingHost,
    arena: std.mem.Allocator,
    upload_nonce: *std.atomic.Value(u64),

    pub fn initMain(
        app: *App,
        command_buffer: gpu.CommandBuffer,
        arena: std.mem.Allocator,
    ) FrameContext {
        return .{
            .device = app.graphics_data.device,
            .command_buffer = command_buffer,
            .copy_pass = null,
            .transfer_buffer_pool = &app.graphics_data.transfer_buffer_pool,
            .assets = &app.assets,
            .texture_readiness_queue = .empty,
            .mesh_readiness_queue = .empty,
            .main_thread = true,
            .fence_manager = &app.graphics_data.fence_manager,
            .messaging_host = &app.messaging.host,
            .arena = arena,
            .upload_nonce = &app.graphics_data.upload_nonce,
        };
    }

    pub fn deinit(self: *FrameContext, gpa: std.mem.Allocator) void {
        self.texture_readiness_queue.deinit(gpa);
        self.mesh_readiness_queue.deinit(gpa);
    }

    pub fn init(
        app: *App,
        arena: std.mem.Allocator,
    ) FrameContext {
        return .{
            .device = app.graphics_data.device,
            .command_buffer = null,
            .copy_pass = null,
            .transfer_buffer_pool = &app.graphics_data.transfer_buffer_pool,
            .assets = &app.assets,
            .texture_readiness_queue = .empty,
            .mesh_readiness_queue = .empty,
            .main_thread = false,
            .fence_manager = &app.graphics_data.fence_manager,
            .messaging_host = &app.messaging.host,
            .arena = arena,
            .upload_nonce = &app.graphics_data.upload_nonce,
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

    pub fn pushReadyAssets(self: *FrameContext, gpa: std.mem.Allocator) !void {
        // if we have textures that will be ready after this data is submit, mark them as ready now, all future passes will have access
        for (self.texture_readiness_queue.items) |ready_texture| {
            // Ignore textures that have been deleted
            const texture = self.assets.textures.getPtr(ready_texture.handle) orelse continue;

            if (texture.graphics_data) |*graphics_data| {
                // Ignore textures that have been changed since!
                if (graphics_data.upload_nonce != ready_texture.nonce) {
                    continue;
                }

                graphics_data.ready = true;
            }
        }

        for (self.mesh_readiness_queue.items) |ready_mesh| {
            // Ignore textures that have been deleted
            const mesh = self.assets.meshes.getPtr(ready_mesh.handle) orelse continue;

            if (mesh.upload_nonce == ready_mesh.nonce) {
                mesh.ready = true;
            }
        }

        self.texture_readiness_queue.clearAndFree(gpa);
        self.mesh_readiness_queue.clearAndFree(gpa);
    }

    pub fn end(self: *FrameContext, gpa: std.mem.Allocator) !void {
        defer self.texture_readiness_queue.clearAndFree(gpa);

        if (self.copy_pass) |copy_pass| {
            copy_pass.end();
        }

        if (self.main_thread) {
            // we don't submit the main thread's command buffer!
        } else if (self.command_buffer) |command_buffer| {
            if (self.commandBufferUsed()) {
                self.assets.lock.lock();
                defer self.assets.lock.unlock();

                try command_buffer.submit();

                try self.pushReadyAssets(gpa);
            } else {
                try command_buffer.cancel();
            }
        }

        self.copy_pass = null;
        self.command_buffer = null;
    }
};

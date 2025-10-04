const std = @import("std");

const build_options = @import("options").build_options;
const gpu = @import("gpu");
const math = @import("math");
const sdl3 = @import("sdl3");
const shared = @import("renderite").shared;

const Texture = @import("assets/Texture.zig");
const graphics = @import("graphics.zig");
const GpuShader = @import("shaders/GpuShader.zig");
const GraphicsPipeline = @import("shaders/GraphicsPipeline.zig");
const WindowData = @import("WindowData.zig");
const XrData = @import("XrData.zig");

const log = @import("logger").Scoped(.graphics);

const GraphicsData = @This();

pub const FenceManager = graphics.FenceManager(&.{});

device: gpu.Device,
sampler_supported_formats: std.enums.EnumSet(shared.TextureFormat),
cubemap_supported_formats: std.enums.EnumSet(shared.TextureFormat),

swapchain_format: gpu.TextureFormat,
composition_mode: gpu.SwapchainComposition,
default_present_mode: gpu.PresentMode,
present_mode: gpu.PresentMode,

depth_format: gpu.TextureFormat,
depth_texture: ?gpu.Texture,
depth_texture_size: math.Vector2i,

transfer_buffer_pool: graphics.TransferBufferPool,

fence_manager: FenceManager,

window_test_pipeline: GraphicsPipeline,

upload_nonce: std.atomic.Value(u64),

pub fn init(
    arena: std.mem.Allocator,
    xr_data: ?XrData,
    window: sdl3.video.Window,
) !GraphicsData {
    _ = arena; // autofix
    const gpu_device = if (xr_data) |xr| xr.backend.getGpuDevice() else try gpu.Device.initWithProperties(.{
        .debug_mode = build_options.safety,
        // TODO: Once we get the ability to transpile to other shader types, specify them here!
        .shaders_spirv = true,
    });
    errdefer if (xr_data == null) gpu_device.deinit();

    var sampler_supported_formats: std.EnumSet(shared.TextureFormat) = .initEmpty();
    var cubemap_supported_formats: std.EnumSet(shared.TextureFormat) = .initEmpty();
    for (std.enums.values(shared.TextureFormat)) |renderite_format| {
        const srgb_gpu_format = Texture.renderiteFormatToGpuFormat(renderite_format, .s_rgb) orelse continue;
        const linear_gpu_format = Texture.renderiteFormatToGpuFormat(renderite_format, .linear) orelse continue;

        if (gpu_device.textureSupportsFormat(
            srgb_gpu_format,
            .two_dimensional,
            .{ .sampler = true },
        ) and gpu_device.textureSupportsFormat(
            linear_gpu_format,
            .two_dimensional,
            .{ .sampler = true },
        )) {
            sampler_supported_formats.insert(renderite_format);
            log.debug(@src(), "GPU supports {s}/{s} for samplers", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
        } else {
            log.debug(@src(), "GPU does not support {s}/{s} for samplers", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
        }

        if (gpu_device.textureSupportsFormat(
            srgb_gpu_format,
            .cube,
            .{ .sampler = true },
        ) and gpu_device.textureSupportsFormat(
            linear_gpu_format,
            .cube,
            .{ .sampler = true },
        )) {
            cubemap_supported_formats.insert(renderite_format);
            log.debug(@src(), "GPU supports {s}/{s} for cubemaps", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
        } else {
            log.debug(@src(), "GPU does not support {s}/{s} for cubemaps", .{ @tagName(srgb_gpu_format), @tagName(linear_gpu_format) });
        }
    }

    // SAFETY: this call never fails if we pass a valid GPU device handle, which we should always have
    log.info(@src(), "Acquired OpenXR GPU device with driver {s}", .{gpu_device.getDriver() catch unreachable});

    try gpu_device.claimWindow(window);

    const composition_mode: gpu.SwapchainComposition = .sdr_linear;
    const present_mode_preferences: []const gpu.PresentMode = &.{
        .mailbox,
        .immediate,
        .vsync,
    };

    var present_mode: gpu.PresentMode = undefined;

    if (!gpu_device.windowSupportsSwapchainComposition(window, composition_mode)) {
        log.err(@src(), "Window does not support the composition mode ({s}) we want. Cannot continue.", .{@tagName(composition_mode)});
        return error.UnsupportCompositionMode;
    }

    for (present_mode_preferences) |present_mode_preference| {
        if (gpu_device.windowSupportsPresentMode(window, present_mode_preference)) {
            try gpu_device.setSwapchainParameters(window, composition_mode, present_mode_preference);

            present_mode = present_mode_preference;
            log.debug(@src(), "Using swapchain parameters: composition={any},present={any}", .{ composition_mode, present_mode_preference });
            break;
        }
    } else {
        log.err(@src(), "Window supports none of our wanted present modes. VR performance may be impacted strongly.", .{});
    }

    const swapchain_format = gpu_device.getSwapchainTextureFormat(window);

    log.debug(@src(), "Using window swapchain format {s}", .{@tagName(swapchain_format)});

    const basic_shader = @import("shaders.basic.").basic;

    const test_vertex_shader: GpuShader = try .create(
        gpu_device,
        basic_shader,
        .{ .spirv = true },
        "vertexMain",
        .vertex,
    );
    errdefer test_vertex_shader.deinit(gpu_device);

    const test_fragment_shader: GpuShader = try .create(
        gpu_device,
        basic_shader,
        .{ .spirv = true },
        "fragmentMain",
        .fragment,
    );
    errdefer test_fragment_shader.deinit(gpu_device);

    const window_test_pipeline: GraphicsPipeline = try .create(
        gpu_device,
        swapchain_format,
        test_vertex_shader,
        test_fragment_shader,
    );

    const wanted_depth_formats: []const gpu.TextureFormat = &.{
        .depth32_float,
        .depth24_unorm,
        .depth16_unorm,
    };

    var chosen_depth_format: gpu.TextureFormat = .depth16_unorm; // universally supported
    for (wanted_depth_formats) |wanted_depth_format| {
        if (gpu_device.textureSupportsFormat(wanted_depth_format, .two_dimensional, .{ .depth_stencil_target = true })) {
            chosen_depth_format = wanted_depth_format;
            break;
        }
    }

    log.debug(@src(), "Picked depth format {s}", .{@tagName(chosen_depth_format)});

    return .{
        .device = gpu_device,
        .sampler_supported_formats = sampler_supported_formats,
        .cubemap_supported_formats = cubemap_supported_formats,
        .transfer_buffer_pool = .init(gpu_device),
        .fence_manager = .init(gpu_device),
        .window_test_pipeline = window_test_pipeline,
        .depth_format = chosen_depth_format,
        .depth_texture = null,
        .depth_texture_size = .{ .x = 0, .y = 0 },
        .upload_nonce = .init(0),
        .swapchain_format = swapchain_format,
        .composition_mode = composition_mode,
        .default_present_mode = present_mode,
        .present_mode = present_mode,
    };
}

pub fn ensureDepthTexture(
    self: *GraphicsData,
    swapchain_width: u32,
    swapchain_height: u32,
) !void {
    if (swapchain_width != self.depth_texture_size.x or swapchain_height != self.depth_texture_size.y) {
        if (self.depth_texture) |depth_texture| {
            self.device.releaseTexture(depth_texture);
        }

        self.depth_texture = try self.device.createTexture(.{
            .format = self.depth_format,
            .width = swapchain_width,
            .height = swapchain_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = .{ .depth_stencil_target = true },
        });
        self.depth_texture_size = .{
            .x = @intCast(swapchain_width),
            .y = @intCast(swapchain_height),
        };
    }
}

pub fn deinit(
    self: *GraphicsData,
    gpa: std.mem.Allocator,
) void {
    if (self.depth_texture) |depth_texture| {
        self.device.releaseTexture(depth_texture);
    }
    self.fence_manager.deinit(gpa);

    self.transfer_buffer_pool.deinit(gpa);

    self.device.deinit();
}

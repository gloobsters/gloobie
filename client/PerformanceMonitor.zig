const std = @import("std");
const time_base: comptime_float = std.time.ns_per_s;

const renderite = @import("renderite");

const log = @import("logger").Scoped(.perf);

const PerformanceMonitor = @This();

state: renderite.shared.PerformanceState,
last_update: i128,
last_frame: i128,
counter: u32,

pub fn init() PerformanceMonitor {
    return .{
        .state = .{
            .fps = 0,
            .immediate_fps = 0,
            .render_time = 0,
            .external_update_time = 0,
            .rendered_frames_since_last = 0,
            .frame_begin_to_submit_time = 0,
            .frame_processed_to_next_begin_time = 0,
            .integration_processing_time = 0,
            .extra_particle_processing_time = 0,
            .processed_asset_integrator_tasks = 0,
            .integration_high_priority_tasks = 0,
            .integration_tasks = 0,
            .integration_render_tasks = 0,
            .integration_particle_tasks = 0,
            .processing_handle_waits = 0,
            .frame_update_handle_time = 0,
            .rendered_cameras = 0,
            .rendered_camera_portals = 0,
            .updated_textures = 0,
            .texture_slice_uploads = 0,
        },
        .counter = 0,
        .last_update = timestamp(),
        .last_frame = timestamp(),
    };
}

const time_base_inverse = 1.0 / time_base;

fn timestamp() i128 {
    return std.time.nanoTimestamp();
}

pub fn beginRenderFrame(self: *PerformanceMonitor) void {
    const now = timestamp();

    self.counter += 1;
    self.last_frame = now;

    const total = now - self.last_update;
    if (total >= (time_base / 2.0)) {
        self.state.fps = @as(f32, @floatFromInt(self.counter)) / (@as(f32, @floatFromInt(total)) * (time_base_inverse));
        self.counter = 0;
        self.last_update = now;
    }
}

pub fn endRenderFrame(self: *PerformanceMonitor) void {
    const now = timestamp();
    const draw: f32 = @floatFromInt(now - self.last_frame);
    self.state.render_time = draw / time_base;
    self.state.immediate_fps = time_base / draw;
}

const std = @import("std");
const time_base: comptime_float = std.time.ns_per_s;

const renderite = @import("renderite");

const log = @import("logger").Scoped(.perf);

const PerformanceMonitor = @This();

state: renderite.Shared.PerformanceState,
last_update: i128,
last_frame: i128,
counter: u32,

pub fn init() PerformanceMonitor {
    return .{
        .state = .{
            .fps = 0,
            .immediateFPS = 0,
            .renderTime = 0,
            .externalUpdateTime = 0,
            .frameBeginToSubmitTime = 0,
            .frameProcessedToNextBeginTime = 0,
            .integrationProcessingTime = 0,
            .extraParticleProcessingTime = 0,
            .processedAssetIntegratorTasks = 0,
            .integrationHighPriorityTasks = 0,
            .integrationTasks = 0,
            .integrationRenderTasks = 0,
            .integrationParticleTasks = 0,
            .processingHandleWaits = 0,
            .frameUpdateHandleTime = 0,
            .renderedCameras = 0,
            .renderedCameraPortals = 0,
            .updatedTextures = 0,
            .textureSliceUploads = 0,
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
    self.state.renderTime = draw / time_base;
    self.state.immediateFPS = time_base / draw;
}

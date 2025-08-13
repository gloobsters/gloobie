const std = @import("std");
const renderite = @import("renderite");

const log = std.log.scoped(.perf);

const PerformanceMonitor = @This();

// const F = f32; // too little to fit timestamp
const F = f64;
// const F = f128; // no effect

state: renderite.Shared.PerformanceState,
last_update: F,
last_frame: F,
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

const TimeBase = 1000.0;
const TimeBaseInverse = 1.0 / TimeBase;

fn timestamp() F {
    return @floatFromInt(std.time.milliTimestamp());
}

pub fn frame(self: *PerformanceMonitor) void {
    const now = timestamp();

    self.counter += 1;
    self.last_frame = now;

    const total_milliseconds = now - self.last_update;
    if (total_milliseconds >= (TimeBase / 2.0)) {
        self.state.fps = @floatCast(@as(F, @floatFromInt(self.counter)) / (total_milliseconds * (TimeBaseInverse)));
        self.counter = 0;
        self.last_update = now;

        log.debug("FPS state: {any}", .{self});
    }
}

pub fn endFrame(self: *PerformanceMonitor) void {
    const now = timestamp();
    const draw = now - self.last_frame;
    self.state.renderTime = @floatCast(draw / TimeBase);
    self.state.immediateFPS = @floatCast(TimeBase / draw);
}

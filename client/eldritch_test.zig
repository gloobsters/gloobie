const std = @import("std");
const Texture = @import("Texture.zig");

/// Simple test to demonstrate eldritch texture functionality
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Eldritch Texture Communication Test ===\n");

    // Test format diagnostics
    const formats_to_test = [_]struct {
        format: @import("renderite").Shared.TextureFormat,
        profile: @import("renderite").Shared.ColorProfile,
        expected_state: Texture.EldritchState,
    }{
        .{ .format = .RGBA32, .profile = .Linear, .expected_state = .mortal },
        .{ .format = .Unknown, .profile = .Linear, .expected_state = .incomprehensible_format },
        .{ .format = .RGB24, .profile = .Linear, .expected_state = .incomprehensible_format },
        .{ .format = .ETC2_RGB, .profile = .Linear, .expected_state = .incomprehensible_format },
    };

    for (formats_to_test) |test_case| {
        const result = Texture.renderiteFormatToGpuFormatWithDiagnostics(test_case.format, test_case.profile);
        
        std.debug.print("Format {s}/{s}:\n", .{ @tagName(test_case.format), @tagName(test_case.profile) });
        std.debug.print("  State: {s}\n", .{@tagName(result.eldritch_state)});
        std.debug.print("  Whisper: {s}\n", .{result.whisper});
        std.debug.print("  GPU Format: {s}\n", .{if (result.format) |fmt| @tagName(fmt) else "null"});
        
        if (result.eldritch_state == test_case.expected_state) {
            std.debug.print("  ✓ Expected eldritch state achieved\n");
        } else {
            std.debug.print("  ✗ Unexpected eldritch state - expected {s}\n", .{@tagName(test_case.expected_state)});
        }
        
        std.debug.print("\n");
    }

    // Test texture diagnostics
    var test_texture = Texture{
        .properties = .{
            .filter_mode = .Anisotropic,
            .aniso_level = 16,
            .wrap_u = .Repeat,
            .wrap_v = .Mirror,
            .wrap_w = .Clamp,
            .mipmap_bias = 0.5,
            .type = .Texture2D,
        },
        .graphics_data = null,
    };

    const diagnostics = try test_texture.diagnosticWhispers(allocator);
    defer allocator.free(diagnostics);

    std.debug.print("Texture Diagnostics:\n{s}\n", .{diagnostics});

    std.debug.print("=== Eldritch Communication Established ===\n");
    std.debug.print("The textures can now whisper their secrets to us.\n");
    std.debug.print("We may yet contain their eldritch power...\n");
    std.debug.print("God help us all.\n");
}
const std = @import("std");

const math = @import("math");
const renderite = @import("renderite");
const sdl3 = @import("sdl3");

const log = @import("logger").Scoped(.input);

const Input = @This();

held_keys: std.AutoArrayHashMapUnmanaged(renderite.shared.Key, void),
type_delta: std.ArrayListUnmanaged(u16),

mouse_delta: math.Vector2f,
scroll_delta: math.Vector2f,
mouse_window_pos: math.Vector2f,
mouse_desktop_pos: math.Vector2f,
left_click_held: bool,
middle_click_held: bool,
right_click_held: bool,
x1_click_held: bool,
x2_click_held: bool,

dropped_files: std.ArrayListUnmanaged([]const u16),

pub fn init(gpa: std.mem.Allocator) !Input {
    var held_keys: std.AutoArrayHashMapUnmanaged(renderite.shared.Key, void) = .empty;
    try held_keys.ensureTotalCapacity(gpa, std.enums.values(renderite.shared.Key).len);
    errdefer held_keys.deinit(gpa);

    return .{
        .held_keys = held_keys,
        .type_delta = .empty,
        .mouse_delta = .zero,
        .scroll_delta = .zero,
        .mouse_window_pos = .zero,
        .mouse_desktop_pos = .zero,
        .left_click_held = false,
        .middle_click_held = false,
        .right_click_held = false,
        .x1_click_held = false,
        .x2_click_held = false,
        .dropped_files = .empty,
    };
}

pub fn deinit(self: *Input, gpa: std.mem.Allocator) void {
    self.held_keys.deinit(gpa);
    self.type_delta.deinit(gpa);
    self.dropped_files.deinit(gpa);
}

// Appends the UTF-8 text input into the type delta.
pub fn handleTextInputUtf8(self: *Input, gpa: std.mem.Allocator, text: []const u8) !void {
    var iter: std.unicode.Utf8Iterator = .{
        .i = 0,
        .bytes = text,
    };

    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint < 0x10000) {
            try self.type_delta.append(gpa, @intCast(codepoint));
        } else {
            const high = @as(u16, @intCast((codepoint - 0x10000) >> 10)) + 0xD800;
            const low = @as(u16, @intCast(codepoint & 0x3FF)) + 0xDC00;

            try self.type_delta.appendSlice(gpa, &.{ @intCast(high), @intCast(low) });
        }
    }
}

/// Handles a key up or down event.
pub fn handleKeyEvent(self: *Input, event: sdl3.events.Keyboard) void {
    // Ignore repeat events
    if (event.repeat) {
        return;
    }

    const keycode = event.key orelse return;

    const key = sdlKeycodeToRenderiteKey(keycode) orelse {
        log.warn(@src(), "Unhandled keycode {s}!", .{@tagName(keycode)});
        return;
    };

    if (event.down) {
        self.held_keys.putAssumeCapacity(key, {});
    } else {
        _ = self.held_keys.swapRemove(key);
    }
}

pub fn handleMouseButtonEvent(self: *Input, event: sdl3.events.MouseButton) void {
    const button_state = switch (event.button) {
        .left => &self.left_click_held,
        .middle => &self.middle_click_held,
        .right => &self.right_click_held,
        .x1 => &self.x1_click_held,
        .x2 => &self.x2_click_held,
        _ => null, // Resonite doesn't handle further buttons.
    };

    if (button_state == null)
        return;

    button_state.?.* = event.down;
}

pub fn handleMouseMotionEvent(self: *Input, event: sdl3.events.MouseMotion) void {
    // Y is inverted for some reason???
    const delta: math.Vector2f = .{ .x = event.x_rel, .y = -event.y_rel };
    self.mouse_delta = self.mouse_delta.add(delta);

    self.mouse_window_pos = .{ .x = event.x, .y = event.y };
    self.mouse_desktop_pos = self.mouse_window_pos; // TODO: handle global mouse position properly
}

pub fn handleMouseScrollEvent(self: *Input, event: sdl3.events.MouseWheel) void {
    const scale: comptime_int = 120; // Gathered by using MouseScrollDelta flux node in Unity
    const delta: math.Vector2f = .{ .x = event.scroll_x * scale, .y = event.scroll_y * scale };
    self.scroll_delta = self.scroll_delta.add(delta);
}

pub fn handleDroppedFile(self: *Input, gpa: std.mem.Allocator, event: sdl3.events.DropFile) !void {
    const file = try std.unicode.utf8ToUtf16LeAlloc(gpa, event.file_name);
    errdefer gpa.free(file);

    try self.dropped_files.append(gpa, file);
}

/// Takes the typed delta, and clears the list
///
/// NOTE: Calling `handleTextInput` invalidates the returned array!!!
pub fn takeTypedDelta(self: *Input) []u16 {
    defer self.type_delta.clearRetainingCapacity();

    return self.type_delta.items;
}

pub fn takeMouseDelta(self: *Input) math.Vector2f {
    defer self.mouse_delta = .zero;
    return self.mouse_delta;
}

pub fn takeScrollDelta(self: *Input) math.Vector2f {
    defer self.scroll_delta = .zero;
    return self.scroll_delta;
}

pub fn takeDroppedFiles(self: *Input, gpa: std.mem.Allocator) !?renderite.shared.DragAndDropEvent {
    if (self.dropped_files.items.len == 0)
        return null;

    const arr = try gpa.dupe([]const u16, self.dropped_files.items);
    self.dropped_files.clearRetainingCapacity();

    return .{
        .paths = arr,
        .drop_point = .zero,
    };
}

fn renderiteKeyToSdlKeycode(key: renderite.shared.Key) ?sdl3.keycode.Keycode {
    return switch (key) {
        .none => null,
        .backspace => .backspace,
        .tab => .tab,
        .clear => .clear,
        .@"return" => .return_key,
        .pause => .pause,
        .escape => .escape,
        .space => .space,
        .exclaim => .exclaim,
        .double_quote => .double_quote,
        .hash => .hash,
        .dollar => .dollar,
        .ampersand => .ampersand,
        .quote => .quote,
        .left_parenthesis => .left_parentheses,
        .right_parenthesis => .right_parentheses,
        .asterisk => .asterisk,
        .plus => .plus,
        .comma => .comma,
        .minus => .minus,
        .period => .period,
        .slash => .slash,
        .alpha0 => .zero,
        .alpha1 => .one,
        .alpha2 => .two,
        .alpha3 => .three,
        .alpha4 => .four,
        .alpha5 => .five,
        .alpha6 => .six,
        .alpha7 => .seven,
        .alpha8 => .eight,
        .alpha9 => .nine,
        .colon => .colon,
        .semicolon => .semicolon,
        .less => .less,
        .equals => .equals,
        .greater => .greater,
        .question => .question,
        .at => .at,
        .vertical_bar => .vertical_bar,
        .left_bracket => .left_bracket,
        .backslash => .backslash,
        .right_bracket => .right_bracket,
        .caret => .caret,
        .underscore => .underscore,
        .back_quote => .back_quote,
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .f => .f,
        .g => .g,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .q => .q,
        .r => .r,
        .s => .s,
        .t => .t,
        .u => .u,
        .v => .v,
        .w => .w,
        .x => .x,
        .y => .y,
        .z => .z,
        .percent => .percent,
        .tilde => .tilde,
        .left_brace => .left_brace,
        .right_brace => .right_brace,
        .delete => .delete,
        .keypad0 => .keypad0,
        .keypad1 => .keypad1,
        .keypad2 => .keypad2,
        .keypad3 => .keypad3,
        .keypad4 => .keypad4,
        .keypad5 => .keypad5,
        .keypad6 => .keypad6,
        .keypad7 => .keypad7,
        .keypad8 => .keypad8,
        .keypad9 => .keypad9,
        .keypad_period => .keypad_period,
        .keypad_divide => .keypad_divide,
        .keypad_multiply => .keypad_multiply,
        .keypad_minus => .keypad_minus,
        .keypad_plus => .keypad_plus,
        .keypad_enter => .keypad_enter,
        .keypad_equals => .keypad_equals,
        .up_arrow => .up_arrow,
        .down_arrow => .down_arrow,
        .right_arrow => .right_arrow,
        .left_arrow => .left_arrow,
        .insert => .insert,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        .f13 => .f13,
        .f14 => .f14,
        .f15 => .f15,
        .numlock => .numlock,
        .caps_lock => .caps_lock,
        .scroll_lock => .scroll_lock,
        .right_shift => .right_shift,
        .left_shift => .left_shift,
        .right_control => .right_control,
        .left_control => .left_control,
        .right_alt => .right_alt,
        .left_alt => .left_alt,
        .right_apple => .right_apple,
        .left_apple => .left_apple,
        .left_windows => .left_windows,
        .right_windows => .right_windows,
        .alt_gr => .alt_gr,
        .help => .help,
        .print => .print,
        .sys_req => .sys_req,
        .@"break" => .pause,
        .menu => .menu,
        .shift => .shift,
        .control => .control,
        .alt => .alt,
        .windows => .windows,
    };
}

pub fn sdlKeycodeToRenderiteKey(key: sdl3.keycode.Keycode) ?renderite.shared.Key {
    return switch (key) {
        .backspace => .backspace,
        .tab => .tab,
        .clear => .clear,
        .return_key => .@"return",
        .pause => .pause,
        .escape => .escape,
        .space => .space,
        .exclaim => .exclaim,
        .dblapostrophe => .double_quote,
        .hash => .hash,
        .dollar => .dollar,
        .ampersand => .ampersand,
        .apostrophe => .quote,
        .left_paren => .left_parenthesis,
        .right_paren => .right_parenthesis,
        .asterisk => .asterisk,
        .plus => .plus,
        .comma => .comma,
        .minus => .minus,
        .period => .period,
        .slash => .slash,
        .zero => .alpha0,
        .one => .alpha1,
        .two => .alpha2,
        .three => .alpha3,
        .four => .alpha4,
        .five => .alpha5,
        .six => .alpha6,
        .seven => .alpha7,
        .eight => .alpha8,
        .nine => .alpha9,
        .colon => .colon,
        .semicolon => .semicolon,
        .less => .less,
        .equals => .equals,
        .greater => .greater,
        .question => .question,
        .at => .at,
        // .backslash => .vertical_bar,
        .left_bracket => .left_bracket,
        .backslash => .backslash,
        .right_bracket => .right_bracket,
        .caret => .caret,
        .underscore => .underscore,
        .grave => .back_quote,
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .f => .f,
        .g => .g,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .q => .q,
        .r => .r,
        .s => .s,
        .t => .t,
        .u => .u,
        .v => .v,
        .w => .w,
        .x => .x,
        .y => .y,
        .z => .z,
        .percent => .percent,
        .tilde => .tilde,
        .left_brace => .left_brace,
        .right_brace => .right_brace,
        .delete => .delete,
        .kp_0 => .keypad0,
        .kp_1 => .keypad1,
        .kp_2 => .keypad2,
        .kp_3 => .keypad3,
        .kp_4 => .keypad4,
        .kp_5 => .keypad5,
        .kp_6 => .keypad6,
        .kp_7 => .keypad7,
        .kp_8 => .keypad8,
        .kp_9 => .keypad9,
        .kp_period => .keypad_period,
        .kp_divide => .keypad_divide,
        .kp_multiply => .keypad_multiply,
        .kp_minus => .keypad_minus,
        .kp_plus => .keypad_plus,
        .kp_enter => .keypad_enter,
        .kp_equals => .keypad_equals,
        .up => .up_arrow,
        .down => .down_arrow,
        .right => .right_arrow,
        .left => .left_arrow,
        .insert => .insert,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .func1 => .f1,
        .func2 => .f2,
        .func3 => .f3,
        .func4 => .f4,
        .func5 => .f5,
        .func6 => .f6,
        .func7 => .f7,
        .func8 => .f8,
        .func9 => .f9,
        .func10 => .f10,
        .func11 => .f11,
        .func12 => .f12,
        .func13 => .f13,
        .func14 => .f14,
        .func15 => .f15,
        // .numlock => .numlock,
        .caps_lock => .caps_lock,
        .scroll_lock => .scroll_lock,
        .right_shift => .right_shift,
        .left_shift => .left_shift,
        .right_ctrl => .right_control,
        .left_ctrl => .left_control,
        .right_alt => .right_alt,
        .left_alt => .left_alt,
        // .right_apple => .right_apple,
        // .left_apple => .left_apple,
        .left_meta => .left_windows,
        .left_gui => .left_windows,
        .right_meta => .right_windows,
        .right_gui => .right_windows,
        .multi_key_compose => .alt_gr,
        .help => .help,
        .print_screen => .print,
        .sysreq => .sys_req,
        // .break => .break,
        .menu => .menu,
        // TODO: ???
        // .shift => .shift,
        // .control => .control,
        // .alt => .alt,
        // .windows => .windows,
        else => null,
    };
}

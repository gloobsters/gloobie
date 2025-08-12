const std = @import("std");

const renderite = @import("renderite");
const sdl3 = @import("sdl3");

const log = std.log.scoped(.input);

const Input = @This();

held_keys: std.AutoArrayHashMapUnmanaged(renderite.Shared.Key, void),
type_delta: std.ArrayListUnmanaged(u16),

pub fn init(gpa: std.mem.Allocator) !Input {
    var held_keys: std.AutoArrayHashMapUnmanaged(renderite.Shared.Key, void) = .empty;
    try held_keys.ensureTotalCapacity(gpa, std.enums.values(renderite.Shared.Key).len);
    errdefer held_keys.deinit(gpa);

    return .{
        .held_keys = held_keys,
        .type_delta = .empty,
    };
}

pub fn deinit(self: *Input, gpa: std.mem.Allocator) void {
    self.held_keys.deinit(gpa);
    self.type_delta.deinit(gpa);
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
        log.warn("Unhandled keycode {s}!", .{@tagName(keycode)});
        return;
    };

    if (event.down) {
        self.held_keys.putAssumeCapacity(key, {});
    } else {
        _ = self.held_keys.swapRemove(key);
    }
}

/// Takes the typed delta, and clears the list
///
/// NOTE: Calling `handleTextInput` invalidates the returned array!!!
pub fn takeTypedDelta(self: *Input) []u16 {
    defer self.type_delta.clearRetainingCapacity();

    return self.type_delta.items;
}

fn renderiteKeyToSdlKeycode(key: renderite.Shared.Key) ?sdl3.keycode.Keycode {
    return switch (key) {
        .None => null,
        .Backspace => .backspace,
        .Tab => .tab,
        .Clear => .clear,
        .Return => .return_key,
        .Pause => .pause,
        .Escape => .escape,
        .Space => .space,
        .Exclaim => .exclaim,
        .DoubleQuote => .double_quote,
        .Hash => .hash,
        .Dollar => .dollar,
        .Ampersand => .ampersand,
        .Quote => .quote,
        .LeftParenthesis => .left_parentheses,
        .RightParenthesis => .right_parentheses,
        .Asterisk => .asterisk,
        .Plus => .plus,
        .Comma => .comma,
        .Minus => .minus,
        .Period => .period,
        .Slash => .slash,
        .Alpha0 => .zero,
        .Alpha1 => .one,
        .Alpha2 => .two,
        .Alpha3 => .three,
        .Alpha4 => .four,
        .Alpha5 => .five,
        .Alpha6 => .six,
        .Alpha7 => .seven,
        .Alpha8 => .eight,
        .Alpha9 => .nine,
        .Colon => .colon,
        .Semicolon => .semicolon,
        .Less => .less,
        .Equals => .equals,
        .Greater => .greater,
        .Question => .question,
        .At => .at,
        .VerticalBar => .vertical_bar,
        .LeftBracket => .left_bracket,
        .Backslash => .backslash,
        .RightBracket => .right_bracket,
        .Caret => .caret,
        .Underscore => .underscore,
        .BackQuote => .back_quote,
        .A => .a,
        .B => .b,
        .C => .c,
        .D => .d,
        .E => .e,
        .F => .f,
        .G => .g,
        .H => .h,
        .I => .i,
        .J => .j,
        .K => .k,
        .L => .l,
        .M => .m,
        .N => .n,
        .O => .o,
        .P => .p,
        .Q => .q,
        .R => .r,
        .S => .s,
        .T => .t,
        .U => .u,
        .V => .v,
        .W => .w,
        .X => .x,
        .Y => .y,
        .Z => .z,
        .Percent => .percent,
        .Tilde => .tilde,
        .LeftBrace => .left_brace,
        .RightBrace => .right_brace,
        .Delete => .delete,
        .Keypad0 => .keypad0,
        .Keypad1 => .keypad1,
        .Keypad2 => .keypad2,
        .Keypad3 => .keypad3,
        .Keypad4 => .keypad4,
        .Keypad5 => .keypad5,
        .Keypad6 => .keypad6,
        .Keypad7 => .keypad7,
        .Keypad8 => .keypad8,
        .Keypad9 => .keypad9,
        .KeypadPeriod => .keypad_period,
        .KeypadDivide => .keypad_divide,
        .KeypadMultiply => .keypad_multiply,
        .KeypadMinus => .keypad_minus,
        .KeypadPlus => .keypad_plus,
        .KeypadEnter => .keypad_enter,
        .KeypadEquals => .keypad_equals,
        .UpArrow => .up_arrow,
        .DownArrow => .down_arrow,
        .RightArrow => .right_arrow,
        .LeftArrow => .left_arrow,
        .Insert => .insert,
        .Home => .home,
        .End => .end,
        .PageUp => .page_up,
        .PageDown => .page_down,
        .F1 => .f1,
        .F2 => .f2,
        .F3 => .f3,
        .F4 => .f4,
        .F5 => .f5,
        .F6 => .f6,
        .F7 => .f7,
        .F8 => .f8,
        .F9 => .f9,
        .F10 => .f10,
        .F11 => .f11,
        .F12 => .f12,
        .F13 => .f13,
        .F14 => .f14,
        .F15 => .f15,
        .Numlock => .numlock,
        .CapsLock => .caps_lock,
        .ScrollLock => .scroll_lock,
        .RightShift => .right_shift,
        .LeftShift => .left_shift,
        .RightControl => .right_control,
        .LeftControl => .left_control,
        .RightAlt => .right_alt,
        .LeftAlt => .left_alt,
        .RightApple => .right_apple,
        .LeftApple => .left_apple,
        .LeftWindows => .left_windows,
        .RightWindows => .right_windows,
        .AltGr => .alt_gr,
        .Help => .help,
        .Print => .print,
        .SysReq => .sys_req,
        .Break => .pause,
        .Menu => .menu,
        .Shift => .shift,
        .Control => .control,
        .Alt => .alt,
        .Windows => .windows,
    };
}

pub fn sdlKeycodeToRenderiteKey(key: sdl3.keycode.Keycode) ?renderite.Shared.Key {
    return switch (key) {
        .backspace => .Backspace,
        .tab => .Tab,
        .clear => .Clear,
        .return_key => .Return,
        .pause => .Pause,
        .escape => .Escape,
        .space => .Space,
        .exclaim => .Exclaim,
        .dblapostrophe => .DoubleQuote,
        .hash => .Hash,
        .dollar => .Dollar,
        .ampersand => .Ampersand,
        .apostrophe => .Quote,
        .left_paren => .LeftParenthesis,
        .right_paren => .RightParenthesis,
        .asterisk => .Asterisk,
        .plus => .Plus,
        .comma => .Comma,
        .minus => .Minus,
        .period => .Period,
        .slash => .Slash,
        .zero => .Alpha0,
        .one => .Alpha1,
        .two => .Alpha2,
        .three => .Alpha3,
        .four => .Alpha4,
        .five => .Alpha5,
        .six => .Alpha6,
        .seven => .Alpha7,
        .eight => .Alpha8,
        .nine => .Alpha9,
        .colon => .Colon,
        .semicolon => .Semicolon,
        .less => .Less,
        .equals => .Equals,
        .greater => .Greater,
        .question => .Question,
        .at => .At,
        // .backslash => .VerticalBar,
        .left_bracket => .LeftBracket,
        .backslash => .Backslash,
        .right_bracket => .RightBracket,
        .caret => .Caret,
        .underscore => .Underscore,
        .grave => .BackQuote,
        .a => .A,
        .b => .B,
        .c => .C,
        .d => .D,
        .e => .E,
        .f => .F,
        .g => .G,
        .h => .H,
        .i => .I,
        .j => .J,
        .k => .K,
        .l => .L,
        .m => .M,
        .n => .N,
        .o => .O,
        .p => .P,
        .q => .Q,
        .r => .R,
        .s => .S,
        .t => .T,
        .u => .U,
        .v => .V,
        .w => .W,
        .x => .X,
        .y => .Y,
        .z => .Z,
        .percent => .Percent,
        .tilde => .Tilde,
        .left_brace => .LeftBrace,
        .right_brace => .RightBrace,
        .delete => .Delete,
        .kp_0 => .Keypad0,
        .kp_1 => .Keypad1,
        .kp_2 => .Keypad2,
        .kp_3 => .Keypad3,
        .kp_4 => .Keypad4,
        .kp_5 => .Keypad5,
        .kp_6 => .Keypad6,
        .kp_7 => .Keypad7,
        .kp_8 => .Keypad8,
        .kp_9 => .Keypad9,
        .kp_period => .KeypadPeriod,
        .kp_divide => .KeypadDivide,
        .kp_multiply => .KeypadMultiply,
        .kp_minus => .KeypadMinus,
        .kp_plus => .KeypadPlus,
        .kp_enter => .KeypadEnter,
        .kp_equals => .KeypadEquals,
        .up => .UpArrow,
        .down => .DownArrow,
        .right => .RightArrow,
        .left => .LeftArrow,
        .insert => .Insert,
        .home => .Home,
        .end => .End,
        .page_up => .PageUp,
        .page_down => .PageDown,
        .func1 => .F1,
        .func2 => .F2,
        .func3 => .F3,
        .func4 => .F4,
        .func5 => .F5,
        .func6 => .F6,
        .func7 => .F7,
        .func8 => .F8,
        .func9 => .F9,
        .func10 => .F10,
        .func11 => .F11,
        .func12 => .F12,
        .func13 => .F13,
        .func14 => .F14,
        .func15 => .F15,
        // .numlock => .Numlock,
        .caps_lock => .CapsLock,
        .scroll_lock => .ScrollLock,
        .right_shift => .RightShift,
        .left_shift => .LeftShift,
        .right_ctrl => .RightControl,
        .left_ctrl => .LeftControl,
        .right_alt => .RightAlt,
        .left_alt => .LeftAlt,
        // .right_apple => .RightApple,
        // .left_apple => .LeftApple,
        .left_meta => .LeftWindows,
        .right_meta => .RightWindows,
        .multi_key_compose => .AltGr,
        .help => .Help,
        .print_screen => .Print,
        .sysreq => .SysReq,
        // .break => .Break,
        .menu => .Menu,
        // TODO: ???
        // .shift => .Shift,
        // .control => .Control,
        // .alt => .Alt,
        // .windows => .Windows,
        else => null,
    };
}

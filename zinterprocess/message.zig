pub const MessageState = enum(i32) {
    Writing = 0,
    LockedToBeConsumed = 1,
    ReadyToBeConsumed = 2,
};

pub const MessageHeader = extern struct {
    state: MessageState,
    body_length: i32,
};

comptime {
    if (@sizeOf(MessageHeader) != 8)
        @compileError("Message header size must be 8 bytes");
}

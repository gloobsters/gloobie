pub const Shared = @import("shared.zig");

const messaging = @import("messaging.zig");
const serialization = @import("serialization.zig");

pub const QueueManager = messaging.QueueManager;
pub const MessagingHost = messaging.MessagingHost;
pub const ReceiveCallback = messaging.ReceiveCallback;

pub const IpcDeserializer = serialization.IpcDeserializer;
pub const IpcSerializer = serialization.IpcSerializer;

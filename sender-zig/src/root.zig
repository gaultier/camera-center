pub const NetMessageKind = enum(u8) { MotionDetected, MotionStopped };

pub const NetMessage = packed struct {
    kind: NetMessageKind,
    duration: i56,
    timestamp_ms: i64,
};

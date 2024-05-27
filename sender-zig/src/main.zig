const std = @import("std");

const State = enum { None, SeenMotionToken, SeenMotionDetected, SeenMotionStopped };
const ParseResult = struct {
    advanced: usize,
    new_state: ?State,
};

fn parse_tokens(
    input: []const u8,
    old_state: State,
    advanced: *usize,
) State {
    var it = std.mem.splitAny(u8, input, "\n ");

    while (it.next()) |word| {
        advanced.* = it.index;

        if (word.len == 0) continue;

        if (std.mem.eql(u8, word, "Motion")) {
            return State.SeenMotionToken;
        } else if (old_state.* == State.SeenMotionToken and std.mem.eql(u8, word, "detected")) {
            return State.SeenMotionDetected;
        } else if (old_state.* == State.SeenMotionToken and std.mem.eql(u8, word, "stopped")) {
            return State.SeenMotionStopped;
        } else {}
    }
}

fn notify_forever(in: std.fs.File, out: std.fs.File) !void {
    const state = State.None;
    const time_motion_detected: i64 = 0;
    const time_motion_stopped: i64 = 0;
    _ = out;

    var read_buf = [_]u8{0} ** 1024;
    while (true) {
        var current: []u8 = undefined;

        if (std.posix.read(in.handle, &read_buf)) |n| {
            std.debug.print("len={} read={s}\n", .{ n, read_buf[0..n] });
            if (n == 0) {
                std.debug.print("0 read, input likely stopped", .{});
                return;
            }

            current = read_buf[0..n];
        } else |err| {
            std.debug.print("stderr read error {}\n", .{err});
            continue;
        }

        while (parse_tokens(current)) |token| {
            _ = token;
        }
        // TODO: carry left-over to beginning of read_buf

        switch (state) {
            .SeenMotionDetected => {
                std.debug.assert(time_motion_detected != 0);
                std.debug.print("motion detected {}", .{time_motion_detected});
            },
            .SeenMotionStopped => {
                std.debug.assert(time_motion_detected != 0);
                std.debug.assert(time_motion_stopped != 0);

                std.debug.print("motion stopped {} {}", .{ time_motion_detected, time_motion_stopped });
            },
            else => {},
        }
    }
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    var destination_address: []const u8 = undefined;
    var destination_port: []const u8 = undefined;
    if (args.next()) |arg| {
        destination_address = arg;
    }
    if (args.next()) |arg| {
        destination_port = arg;
    }

    const port: u16 = try std.fmt.parseUnsigned(u16, destination_port, 10);
    const address = try std.net.Address.parseIp4(destination_address, port);
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    try std.posix.connect(socket, &address.any, address.getOsSockLen());

    try notify_forever(std.io.getStdIn(), .{ .handle = socket });
}

test "parse_tokens" {
    {
        var time_motion_detected: i64 = 0;
        var time_motion_stopped: i64 = 0;
        var state = State.None;
        const input = "Motion";
        parse_tokens(input, &state, &time_motion_detected, &time_motion_stopped);
        try std.testing.expect(state == .SeenMotionToken);
        try std.testing.expect(time_motion_detected == 0);
        try std.testing.expect(time_motion_stopped == 0);
    }
    {
        var time_motion_detected: i64 = 0;
        var time_motion_stopped: i64 = 0;
        var state = State.None;
        const input = "Motion detected\n";
        parse_tokens(input, &state, &time_motion_detected, &time_motion_stopped);
        try std.testing.expect(state == .SeenMotionDetected);
        try std.testing.expect(time_motion_detected != 0);
        try std.testing.expect(time_motion_stopped == 0);
    }
    {
        var time_motion_detected: i64 = 0;
        var time_motion_stopped: i64 = 0;
        var state = State.None;
        const input = "Motion detected\n Motion ";
        parse_tokens(input, &state, &time_motion_detected, &time_motion_stopped);
        try std.testing.expect(state == .SeenMotionDetected);
        try std.testing.expect(time_motion_detected != 0);
        try std.testing.expect(time_motion_stopped == 0);
    }
    {
        var time_motion_detected: i64 = 0;
        var time_motion_stopped: i64 = 0;
        var state = State.None;
        const input = "Motion detected\n Motion stopped ";
        parse_tokens(input, &state, &time_motion_detected, &time_motion_stopped);
        try std.testing.expect(state == .SeenMotionStopped);
        try std.testing.expect(time_motion_detected != 0);
        try std.testing.expect(time_motion_stopped != 0);
    }
}

const std = @import("std");

const State = enum { None, SeenMotion, MotionDetected, MotionStopped };

fn parse_tokens(input: []const u8, state: *State, time_motion_detected: *i64, time_motion_stopped: *i64) void {
    var it = std.mem.splitAny(u8, input, "\n ");

    while (it.next()) |word| {
        if (word.len == 0) continue;

        if (std.mem.eql(u8, word, "Motion")) {
            state.* = State.SeenMotion;
        } else if (state.* == State.SeenMotion and std.mem.eql(u8, word, "detected")) {
            state.* = State.MotionDetected;
            time_motion_detected.* = std.time.milliTimestamp();
        } else if (state.* == State.SeenMotion and std.mem.eql(u8, word, "stopped")) {
            state.* = State.MotionStopped;
            time_motion_stopped.* = std.time.milliTimestamp();
        } else {
            state.* = State.None;
        }
    }
}

fn notify_forever(in: std.fs.File, out: std.fs.File) !void {
    var state = State.None;
    var time_motion_detected: i64 = 0;
    var time_motion_stopped: i64 = 0;
    _ = out;

    while (true) {
        var read: []u8 = undefined;
        var read_buf = [_]u8{0} ** 1024;
        if (std.posix.read(in.handle, &read_buf)) |n| {
            std.debug.print("len={} read={s}\n", .{ n, read_buf[0..n] });
            if (n == 0) {
                std.debug.print("0 read, input likely stopped", .{});
                return;
            }

            read = read_buf[0..n];
        } else |err| {
            std.debug.print("stderr read error {}\n", .{err});
            continue;
        }

        parse_tokens(read, &state, &time_motion_detected, &time_motion_stopped);

        switch (state) {
            .MotionDetected => {
                std.debug.assert(time_motion_detected != 0);
                std.debug.print("motion detected {}", .{time_motion_detected});
            },
            .MotionStopped => {
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
        try std.testing.expect(state == .SeenMotion);
        try std.testing.expect(time_motion_detected == 0);
        try std.testing.expect(time_motion_stopped == 0);
    }
}

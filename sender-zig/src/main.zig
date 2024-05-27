const std = @import("std");

const State = enum { SeenMotionDetected, SeenMotionStopped };

fn parse(
    input: []const u8,
    advanced: *usize,
) ?State {
    const needle_motion_stopped = "Motion stopped\n";
    const needle_motion_detected = "Motion detected\n";

    if (std.mem.indexOf(u8, input, needle_motion_detected)) |idx| {
        advanced.* = idx + needle_motion_detected.len;
        return .SeenMotionDetected;
    }

    if (std.mem.indexOf(u8, input, needle_motion_stopped)) |idx| {
        advanced.* = idx + needle_motion_stopped.len;
        return .SeenMotionStopped;
    }

    return null;
}

fn notify_forever(in: std.fs.File, out: std.fs.File) !void {
    // const time_motion_detected: i64 = 0;
    // const time_motion_stopped: i64 = 0;
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

        var advanced: usize = 0;
        while (parse(current, &advanced)) |token| {
            // const now = std.time.milliTimestamp();
            std.debug.print("{}", .{token});
            current = current[advanced..];

            switch (token) {
                .SeenMotionDetected => {},
                .SeenMotionStopped => {},
            }
        }

        // TODO: carry left-over to beginning of read_buf
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
        var advanced: usize = 0;
        const res = parse("Motion", &advanced);
        try std.testing.expectEqual(null, res);
        try std.testing.expectEqual(0, advanced);
    }
    {
        var advanced: usize = 0;
        const res = parse("Motion stoppe", &advanced);
        try std.testing.expectEqual(null, res);
        try std.testing.expectEqual(0, advanced);
    }
    {
        var advanced: usize = 0;
        const res = parse("Motion detected\n", &advanced);
        try std.testing.expectEqual(.SeenMotionDetected, res.?);
        try std.testing.expectEqual(16, advanced);
    }
    {
        var advanced: usize = 0;
        const res = parse("Motion stopped\n", &advanced);
        try std.testing.expectEqual(.SeenMotionStopped, res.?);
        try std.testing.expectEqual(15, advanced);
    }
    {
        var advanced: usize = 0;
        const res = parse("Motion stopped\nMotion detected\n", &advanced);
        try std.testing.expectEqual(.SeenMotionStopped, res.?);
        try std.testing.expectEqual(15, advanced);
    }
}

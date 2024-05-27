const std = @import("std");

const State = enum { SeenMotionDetected, SeenMotionStopped };

fn parse(
    input: []const u8,
    advanced: *usize,
) ?State {
    const needle_motion_stopped = "Motion stopped\n";
    const needle_motion_detected = "Motion detected\n";

    if (std.mem.indexOf(u8, input, "\n")) |idx1| {
        if (std.mem.indexOf(u8, input[0 .. idx1 + 1], needle_motion_detected)) |_| {
            advanced.* = idx1 + 1;
            return .SeenMotionDetected;
        }

        if (std.mem.indexOf(u8, input[0 .. idx1 + 1], needle_motion_stopped)) |_| {
            advanced.* = idx1 + 1;
            return .SeenMotionStopped;
        }

        advanced.* = input.len; // Nothing interesting seen.
    }

    return null;
}

fn notify_forever(in: std.fs.File, out: std.fs.File) !void {
    var time_motion_detected: i64 = 0;

    var read_buf = [_]u8{0} ** 1024;
    var current: []u8 = read_buf[0..0];
    while (true) {
        // There might be carry over data, do not overwrite it.
        if (std.posix.read(in.handle, read_buf[current.len..])) |n| {
            const data = read_buf[current.len .. current.len + n];
            std.debug.print("len={} read={s} {x}\n", .{ n, data, data });
            if (n == 0) {
                std.debug.print("0 read, input likely stopped", .{});
                return;
            }

            current = data;
        } else |err| {
            std.debug.print("stderr read error {}\n", .{err});
            continue;
        }

        var advanced: usize = 0;
        while (parse(current, &advanced)) |token| {
            const now = std.time.milliTimestamp();

            current = current[advanced..];

            switch (token) {
                .SeenMotionDetected => {
                    time_motion_detected = now;
                    std.debug.print("{} {}\n", .{ token, time_motion_detected });
                    _ = out.write("motion detected\n") catch {}; // FIXME
                },
                .SeenMotionStopped => {
                    std.debug.print("{} {} {}\n", .{ token, time_motion_detected, now });
                    _ = out.write("motion stopped\n") catch {}; // FIXME
                },
            }
        }

        // Carry over left-over data.
        std.mem.copyBackwards(u8, &read_buf, current);
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
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
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
        const res = parse("foobar\n", &advanced);
        try std.testing.expectEqual(null, res);
        try std.testing.expectEqual(7, advanced);
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
    {
        var advanced: usize = 0;
        const res = parse("Motion detected\nMotion stopped\n", &advanced);
        try std.testing.expectEqual(.SeenMotionDetected, res.?);
        try std.testing.expectEqual(16, advanced);
    }
}

const std = @import("std");

const State = enum { None, SeenMotion, SeenMotionDetected, SeeMotionStopped };

fn parse_tokens(tokens: [][]u8, state: *State) !void {
    var it = std.mem.splitAny(u8, tokens, "\n ");

    while (it.next()) |word| {
        if (std.mem.eql(u8, word, "Motion")) {
            state.* = State.SeenMotion;
        } else if (state.* == State.SeenMotion and std.mem.eql(u8, word, "detected")) {
            state.* = State.SeenMotionDetected;
        } else if (state.* == State.SeenMotion and std.mem.eql(u8, word, "stopped")) {
            state.* = State.MotionStopped;
        }
    }
}

fn notify_forever(in: std.fs.File, out: std.fs.File) !void {
    var state = State.None;
    // var time_start: i64 = undefined;
    _ = out;

    while (true) {
        var read: []u8 = undefined;
        var read_buf = [_]u8{0} ** 1024;
        if (std.posix.read(in.handle, &read_buf)) |n| {
            std.debug.print("stderr len={} read={s}\n", .{ n, read_buf[0..n] });
            if (n == 0) {
                std.debug.print("0 read, input likely stopped", .{});
                return;
            }

            read = read_buf[0..n];
        } else |err| {
            std.debug.print("stderr read error {}\n", .{err});
            continue;
        }

        parse_tokens(&read, &state);

        switch (state) {
            .SeenMotionDetected => {},
            .SeeMotionStopped => {},
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

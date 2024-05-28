const std = @import("std");
const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    // @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("time.h");
});

pub const NetMessageKind = enum(u8) { MotionDetected, MotionStopped };

pub const NetMessage = packed struct {
    kind: NetMessageKind,
    duration_ms: i56,
    timestamp_ms: i64,
};

const FILE_TIMER_DURATION_SECONDS = 60;

fn handle_tcp_connection(connection: *std.net.Server.Connection) !void {
    var event_file = try std.fs.cwd().createFile("events.txt", .{});
    try event_file.seekFromEnd(0);

    while (true) {
        var read_buffer = [_]u8{0} ** 4096;
        const read_n = try connection.stream.read(&read_buffer);
        std.log.debug("tcp read={} {x}", .{ read_n, read_buffer[0..read_n] });
        if (read_n == 0) {
            std.log.debug("tcp read={} client likely closed the connection", .{read_n});
            std.process.exit(0);
        }

        const read = read_buffer[0..read_n];
        // TODO: length checks etc. Ringbuffer?
        const message: NetMessage = std.mem.bytesToValue(NetMessage, read);

        var date: [256:0]u8 = undefined;
        const date_len = fill_string_from_timestamp_ms(message.timestamp_ms, &date);

        const writer = event_file.writer();
        try std.fmt.format(writer, "{s} {}\n", .{ date[0..date_len], message.duration_ms });
    }
}

// TODO: For multiple cameras we need to identify which stream it is.
// Perhaps from the mpegts metadata?
fn listen_udp() !void {
    const udp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    try std.posix.bind(udp_socket, &address.any, address.getOsSockLen());

    var video_file = try std.fs.cwd().createFile("out.ts", .{});
    try video_file.seekFromEnd(0);

    const timer = try std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, .{});
    try std.posix.timerfd_settime(timer, .{}, &.{
        .it_value = .{ .tv_sec = FILE_TIMER_DURATION_SECONDS, .tv_nsec = 0 },
        .it_interval = .{ .tv_sec = FILE_TIMER_DURATION_SECONDS, .tv_nsec = 0 },
    }, null);

    var poll_fds = [2]std.posix.pollfd{ .{
        .fd = udp_socket,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }, .{
        .fd = timer,
        .events = std.posix.POLL.IN,
        .revents = 0,
    } };

    while (true) {
        _ = std.posix.poll(&poll_fds, -1) catch |err| {
            std.log.err("poll error {}", .{err});
            continue;
        };

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            var read_buffer = [_]u8{0} ** 4096;
            if (std.posix.read(poll_fds[0].fd, &read_buffer)) |n_read| {
                std.log.debug("udp read={}", .{n_read});

                video_file.writeAll(read_buffer[0..n_read]) catch |err| {
                    std.log.err("failed to write all to file {}", .{err});
                };
            } else |err| {
                std.log.err("failed to read udp {}", .{err});
            }
        }
        if ((poll_fds[1].revents & std.posix.POLL.IN) != 0) {
            std.log.debug("timer triggered", .{});
            var read_buffer = [_]u8{0} ** 8;
            _ = std.posix.read(poll_fds[1].fd, &read_buffer) catch {};
        }
    }
}

fn listen_tcp() !void {
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    var server = try std.net.Address.listen(address, .{ .reuse_address = true });

    while (true) {
        var connection = try server.accept();
        const pid = try std.posix.fork();
        if (pid > 0) { // Parent.
            continue;
        }
        // Child
        try handle_tcp_connection(&connection);
    }
}

fn fill_string_from_timestamp_ms(timestamp_ms: i64, out: *[256]u8) usize {
    const timestamp_seconds: i64 = @divFloor(timestamp_ms, 1000);
    var time: c.struct_tm = undefined;
    _ = c.localtime_r(&@as(c.time_t, timestamp_seconds), &time);

    const date_c: [*c]u8 = @as([*c]u8, @ptrCast(@alignCast(out)));
    const res = c.strftime(date_c, 256, "%Y-%m-%d %H:%M:%S", @as([*c]const c.struct_tm, &time));
    std.debug.assert(res > 0);
    return res;
}

pub fn main() !void {
    _ = try std.Thread.spawn(.{}, listen_udp, .{});

    try listen_tcp();
}

test "strftime" {
    const timestamp: i64 = 1_716_902_774_000;
    var res: [256:0]u8 = undefined;
    const len = fill_string_from_timestamp_ms(timestamp, &res);

    std.debug.print("{s}", .{res[0..len]});
    try std.testing.expect(std.mem.eql(u8, "2024-05-28 15:26:14", res[0..len]));
}

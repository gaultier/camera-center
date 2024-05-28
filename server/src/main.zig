const std = @import("std");

pub const NetMessageKind = enum(u8) { MotionDetected, MotionStopped };

pub const NetMessage = packed struct {
    kind: NetMessageKind,
    duration: i56,
    timestamp_ms: i64,
};

const FILE_TIMER_DURATION_SECONDS = 60;

fn handle_tcp_connection(connection: *std.net.Server.Connection) !void {
    while (true) {
        var read_buffer = [_]u8{0} ** 4096;
        const read = try connection.stream.read(&read_buffer);
        std.log.debug("tcp read={} {x}", .{ read, read_buffer[0..read] });
        if (read == 0) {
            std.log.debug("tcp read={} client likely closed the connection", .{read});
            std.process.exit(0);
        }

        // TODO: length checks etc. Ringbuffer?
        const message: NetMessage = std.mem.bytesToValue(NetMessage, read_buffer[0..read]);
        std.log.debug("message={}", .{message});
    }
}

// TODO: For multiple cameras we need to identify which stream it is.
// Perhaps from the mpegts metadata?
fn listen_udp() !void {
    const udp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    try std.posix.bind(udp_socket, &address.any, address.getOsSockLen());

    var file = try std.fs.cwd().createFile("out.ts", .{ .read = true });

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

                file.writeAll(read_buffer[0..n_read]) catch |err| {
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

pub fn main() !void {
    _ = try std.Thread.spawn(.{}, listen_udp, .{});

    try listen_tcp();
}

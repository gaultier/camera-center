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
        std.debug.print("tcp read={} {x}\n", .{ read, read_buffer[0..read] });
        if (read == 0) {
            std.debug.print("tcp read={} client likely closed the connection\n", .{read});
            std.process.exit(0);
        }

        // TODO: length checks etc. Ringbuffer?
        const message: NetMessage = std.mem.bytesToValue(NetMessage, read_buffer[0..read]);
        std.debug.print("message={}\n", .{message});
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
            std.debug.print("poll error {}\n", .{err});
            continue;
        };

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            var read_buffer = [_]u8{0} ** 4096;
            if (std.posix.read(poll_fds[0].fd, &read_buffer)) |n_read| {
                std.debug.print("udp read={}\n", .{n_read});

                file.writeAll(read_buffer[0..n_read]) catch |err| {
                    std.debug.print("failed to write all to file {}\n", .{err});
                };
            } else |err| {
                std.debug.print("failed to read udp {}\n", .{err});
            }
        }
        if ((poll_fds[1].revents & std.posix.POLL.IN) != 0) {
            std.debug.print("timer triggered\n", .{});
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

const std = @import("std");

pub fn main() !void {
    const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0) catch unreachable;
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    std.posix.bind(socket, &address.any, address.getOsSockLen()) catch |err| {
        std.debug.print("failed to bind {}", .{err});
        return;
    };

    std.posix.listen(socket, 4) catch |err| {
        std.debug.print("failed to listen {}", .{err});
        return;
    };

    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = socket,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    var read_buf = [_]u8{0} ** (1 << 16);

    while (true) {
        _ = std.posix.poll(&poll_fds, -1) catch |err| {
            std.debug.print("failed to poll {}", .{err});
            continue;
        };

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            if (std.posix.read(poll_fds[0].fd, &read_buf)) |n| {
                std.debug.print("read {}", .{n});
            } else |err| {
                std.debug.print("failed to read {}", .{err});
            }
        }
    }
}

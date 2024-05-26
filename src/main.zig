const std = @import("std");

const MessageKind = enum(u2) {
    VideoStream,
    MotionStarted,
    MotionStopped,
};

pub fn main() !void {
    const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch unreachable;
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;

    std.posix.bind(socket, &address.any, address.getOsSockLen()) catch |err| {
        std.debug.print("failed to bind {}\n", .{err});
        return;
    };

    std.posix.listen(socket, 16) catch |err| {
        std.debug.print("failed to listen {}\n", .{err});
        return;
    };

    var peer_address: std.net.Address = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    var client_fd: i32 = 0;
    if (std.posix.accept(socket, &peer_address.any, &addr_len, 0)) |fd| {
        client_fd = fd;
    } else |err| {
        std.debug.print("failed to accept {}\n", .{err});
        return;
    }

    var poll_fds = std.ArrayList.ArrayList(std.posix.pollfd);
    var read_buf = [_]u8{0} ** (1 << 16);

    var file: std.posix.fd_t = 0;
    if (std.posix.open("out.ts", std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600)) |fd| {
        file = fd;
    } else |err| {
        std.debug.print("failed to open file {}\n", .{err});
        return;
    }

    while (true) {
        _ = std.posix.poll(&poll_fds, -1) catch |err| {
            std.debug.print("failed to poll {}\n", .{err});
            continue;
        };

        var i = 0;
        while (i < poll_fds.len) {
            defer i += 1;
            const poll_fd = poll_fds[i];

            if ((poll_fd.revents & std.posix.POLL.ERR) != 0) {
                std.debug.print("client closed connection\n", .{});
                std.posix.close(client_fd);
                // std.array_list.ArrayList
                continue;
            }

            if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
                if (std.posix.read(poll_fds[0].fd, &read_buf)) |read| {
                    std.debug.print("read {}\n", .{read});

                    if (std.posix.write(file, read_buf[0..read])) |written| {
                        std.debug.print("written {}\n", .{written});
                    } else |err| {
                        std.debug.print("failed to write {}\n", .{err});
                        continue;
                    }
                } else |err| {
                    std.debug.print("failed to read {}\n", .{err});
                    continue;
                }
            }
        }
    }
}

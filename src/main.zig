const std = @import("std");

// const MessageKind = enum {
//     VideoStream,
//     MotionStarted,
//     MotionStopped,
// };

// const NetMessage = struct {
//     kind: MessageKind,
//     len: u32,
// };

pub fn main() !void {
    const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch unreachable;
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    std.posix.bind(socket, &address.any, address.getOsSockLen()) catch |err| {
        std.debug.print("failed to bind {}\n", .{err});
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

    var file: std.posix.fd_t = 0;
    if (std.posix.open("out.ts", std.posix.O{ .CREAT = true, .APPEND = true }, 0o600)) |fd| {
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

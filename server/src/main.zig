const std = @import("std");
const root = @import("./root");

fn handle_connection(connection: *std.net.Server.Connection) !void {
    while (true) {
        var read_buffer = [_]u8{0} ** 4096;
        const read = try connection.stream.read(&read_buffer);
        std.debug.print("tcp read={} {x}\n", .{ read, read_buffer[0..read] });
        if (read == 0) {
            std.debug.print("tcp read={} client likely closed the connection\n", .{read});
            std.process.exit(0);
        }
    }
}

fn listen_udp() !void {
    const udp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    try std.posix.bind(udp_socket, &address.any, address.getOsSockLen());

    while (true) {
        var read_buffer = [_]u8{0} ** 4096;
        if (std.posix.read(udp_socket, &read_buffer)) |n| {
            std.debug.print("udp read={}\n", .{n});
        } else |err| {
            std.debug.print("failed to read udp {}\n", .{err});
        }
    }
}

pub fn main() !void {
    _ = try std.Thread.spawn(.{}, listen_udp, .{});

    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    var server = try std.net.Address.listen(address, .{ .reuse_address = true });
    while (true) {
        var connection = try server.accept();
        const pid = try std.posix.fork();
        if (pid > 0) { // Parent.
            continue;
        }
        // Child
        try handle_connection(&connection);
    }
}

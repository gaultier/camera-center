const std = @import("std");
const root = @import("./root");

fn handle_connection(connection: *std.net.Server.Connection) !void {
    while (true) {
        var read_buffer = [_]u8{0} ** 4096;
        const read = try connection.stream.read(&read_buffer);
        std.debug.print("read={} {x}\n", .{ read, read_buffer[0..read] });
    }
}

pub fn main() !void {
    // const udp_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch unreachable;
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

const std = @import("std");

pub fn main() !void {
    const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0) catch unreachable;
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    std.posix.bind(socket, &address.any, address.getOsSockLen()) catch |err| {
        std.debug.print("failed to bind {}", .{err});
        return;
    };
}

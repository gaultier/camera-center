const std = @import("std");

const needle_motion_stopped = "Motion stopped";
const needle_motion_detected = "Motion detected";

fn notify_forever(in: std.fs.File, out: std.fs.File) !void {
    var time_motion_detected: i64 = 0;

    var buffered_reader = std.io.bufferedReader(in.reader());
    const reader = buffered_reader.reader();

    // FIXME
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var line = std.ArrayList(u8).init(allocator);
    const writer = line.writer();

    while (reader.streamUntilDelimiter(writer, '\n', null)) {
        std.debug.print("read={s} {x}\n", .{ line.items, line.items });
        defer line.clearRetainingCapacity();

        if (std.mem.eql(u8, line.items, needle_motion_detected)) {
            time_motion_detected = std.time.milliTimestamp();
            std.debug.print("detected {}\n", .{time_motion_detected});
            _ = out.write(&[_]u8{0}) catch |err| {
                std.debug.print("failed to send {}\n", .{err});
            };
        } else if (std.mem.eql(u8, line.items, needle_motion_stopped)) {
            const now = std.time.milliTimestamp();
            std.debug.print("stopped {} {}\n", .{ time_motion_detected, now });
            _ = out.write(&[_]u8{1}) catch |err| {
                std.debug.print("failed to send {}\n", .{err});
            };
        }
    } else |err| {
        std.debug.print("stderr read error {}\n", .{err});
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
    std.posix.setsockopt(socket, 6, // SOL_TCP
        std.posix.TCP.NODELAY, std.mem.sliceAsBytes(&[_]u32{1})) catch |err| {
        std.debug.print("failed to set TCP_NODELAY {}\n", .{err});
    };
    try std.posix.connect(socket, &address.any, address.getOsSockLen());

    try notify_forever(std.io.getStdIn(), .{ .handle = socket });
}

const std = @import("std");

pub const NetMessageKind = enum(u8) { MotionDetected, MotionStopped };

pub const NetMessage = packed struct {
    kind: NetMessageKind,
    duration: i56,
    timestamp_ms: i64,
};

const needle_motion_stopped = "Motion stopped";
const needle_motion_detected = "Motion detected";

fn notify_forever(in: std.fs.File, address: *const std.net.Address) !void {
    var out = try create_tcp_socket(address);
    var time_motion_detected: i64 = 0;

    var buffered_reader = std.io.bufferedReader(in.reader());
    const reader = buffered_reader.reader();

    var mem = [_]u8{0} ** 4096;
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fixed_buffer_allocator.allocator();
    var line = std.ArrayList(u8).init(allocator);
    const writer = line.writer();

    while (reader.streamUntilDelimiter(writer, '\n', null)) {
        std.log.debug("read={s} {x}", .{ line.items, line.items });
        defer line.clearRetainingCapacity();

        var message: NetMessage = undefined;
        if (std.mem.eql(u8, line.items, needle_motion_detected)) {
            time_motion_detected = std.time.milliTimestamp();
            message = .{ .kind = .MotionDetected, .timestamp_ms = time_motion_detected, .duration = 0 };
            std.log.debug("detected {}", .{time_motion_detected});

            try send_message(&out, address, &message);
        } else if (std.mem.eql(u8, line.items, needle_motion_stopped)) {
            const now = std.time.milliTimestamp();
            message = .{ .kind = .MotionStopped, .timestamp_ms = now, .duration = @intCast(now - time_motion_detected) };
            std.log.debug("stopped {}", .{message});

            try send_message(&out, address, &message);
        }
    } else |err| {
        std.log.err("stderr read error {}", .{err});
    }
}

fn tcp_connect_retry_forever(socket: *std.posix.socket_t, address: *const std.net.Address) void {
    while (true) {
        std.posix.connect(socket.*, &address.any, address.getOsSockLen()) catch |err| {
            std.log.err("failed to connect over tcp, retrying {}", .{err});
            std.time.sleep(2_000_000_000);
            continue;
        };
        break;
    }
}

fn send_message(socket: *std.posix.socket_t, address: *const std.net.Address, message: *const NetMessage) !void {
    const message_bytes = std.mem.asBytes(message);

    if (std.posix.write(socket.*, message_bytes)) |sent| {
        std.log.debug("sent {} {}", .{ sent, message });
    } else |err| switch (err) {
        error.BrokenPipe => {
            std.posix.close(socket.*);
            socket.* = try create_tcp_socket(address);
            tcp_connect_retry_forever(socket, address);
        },
        else => std.log.err("failed to send {}", .{err}),
    }
}

fn create_tcp_socket(address: *const std.net.Address) !std.posix.socket_t {
    var socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    std.posix.setsockopt(socket, 6, // SOL_TCP
        std.posix.TCP.NODELAY, std.mem.sliceAsBytes(&[_]u32{1})) catch |err| {
        std.log.err("failed to set TCP_NODELAY {}", .{err});
    };
    tcp_connect_retry_forever(&socket, address);

    return socket;
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    var destination_address: []const u8 = undefined;
    var destination_port: []const u8 = undefined;
    if (args.next()) |arg| {
        destination_address = arg;
    } else {
        std.log.err("Missing address", .{});
        std.posix.exit(1);
    }
    if (args.next()) |arg| {
        destination_port = arg;
    } else {
        std.log.err("Missing port", .{});
        std.posix.exit(1);
    }

    const port: u16 = try std.fmt.parseUnsigned(u16, destination_port, 10);
    const address = try std.net.Address.parseIp4(destination_address, port);

    try notify_forever(std.io.getStdIn(), &address);
}

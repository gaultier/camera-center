const std = @import("std");
const c = @cImport({
    @cInclude("time.h"); // For `strftime`, `localtime_r`.
});

pub const std_options = .{
    .log_level = .info,
};

pub const NetMessageKind = enum(u8) { MotionDetected, MotionStopped };

pub const NetMessage = packed struct {
    kind: NetMessageKind,
    duration_ms: i56,
    timestamp_ms: i64,
};

const VIDEO_FILE_DURATION_SECONDS = 1 * std.time.s_per_min;
const CLEANER_FREQUENCY_SECONDS = 1 * std.time.s_per_min;
const VIDEO_FILE_MAX_RETAIN_DURATION_SECONDS = 7 * std.time.s_per_day;
const VLC_UDP_PACKET_SIZE = 1316;

const Viewer = struct {
    ring: std.RingBuffer,
    socket: std.posix.socket_t,
};

const Viewers = [1]Viewer;

fn handle_tcp_connection_for_incoming_events(connection: *std.net.Server.Connection) !void {
    var event_file = try std.fs.cwd().openFile("events.txt", .{ .mode = .write_only });
    try event_file.seekFromEnd(0);

    var mem = [_]u8{0} ** 4096;
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fixed_buffer_allocator.allocator();
    var ring = try std.RingBuffer.init(allocator, 2048);

    while (true) {
        var read_buffer_net = [_]u8{0} ** 512;
        const n_read = connection.stream.read(&read_buffer_net) catch |err| {
            std.log.err("failed to read message {}", .{err});
            continue;
        };
        std.log.debug("tcp read={} {x}", .{ n_read, read_buffer_net[0..n_read] });
        if (n_read == 0) {
            std.log.debug("tcp read={} client likely closed the connection", .{n_read});
            std.process.exit(0);
        }
        ring.writeSliceAssumeCapacity(read_buffer_net[0..n_read]);

        while (true) {
            var read_buffer_ring = [_]u8{0} ** @sizeOf(NetMessage);
            ring.readFirst(&read_buffer_ring, @sizeOf(NetMessage)) catch break;
            const message: NetMessage = std.mem.bytesToValue(NetMessage, &read_buffer_ring);
            std.log.info("event {}", .{message});

            var date: [256:0]u8 = undefined;
            const date_str = fill_string_from_timestamp_ms(message.timestamp_ms, &date);

            const writer = event_file.writer();
            try std.fmt.format(writer, "{s} {}\n", .{ date_str, message.duration_ms });
        }
    }
}

fn handle_udp_packet(in: std.posix.socket_t, out: std.fs.File, viewers: Viewers) void {
    _ = viewers;

    var read_buffer = [_]u8{0} ** 4096;
    if (std.posix.read(in, &read_buffer)) |n_read| {
        // std.log.warn("udp read={}", .{n_read});

        out.writeAll(read_buffer[0..n_read]) catch |err| {
            std.log.err("failed to write all to file {}", .{err});
        };
        // viewer_ring.writeSliceAssumeCapacity(read_buffer[0..n_read]);

        // while (!viewer_ring.isEmpty()) {
        //     var read_buffer_ring = [_]u8{0} ** VLC_UDP_PACKET_SIZE;
        //     viewer_ring.readFirst(&read_buffer_ring, VLC_UDP_PACKET_SIZE) catch break;
        //     _ = std.posix.send(viewer_socket, read_buffer_ring[0..VLC_UDP_PACKET_SIZE], 0) catch |err| {
        //         std.log.err("failed to write to viewer {}", .{err});
        //     };
        // }
    } else |err| {
        std.log.err("failed to read udp {}", .{err});
    }
}

fn create_video_file() !std.fs.File {
    const now = std.time.milliTimestamp();
    var date: [256:0]u8 = undefined;
    const date_str = fill_string_from_timestamp_ms(now, &date);

    const file = try std.fs.cwd().createFileZ(date_str, .{ .read = true });
    try file.seekFromEnd(0);

    std.log.info("new video file {s}", .{date});
    return file;
}

fn handle_timer_trigger(fd: i32, video_file: *std.fs.File) !void {
    std.log.debug("timer triggered", .{});
    var read_buffer = [_]u8{0} ** 8;
    std.debug.assert(std.posix.read(fd, &read_buffer) catch 0 == 8);

    video_file.*.close();
    video_file.* = try create_video_file();
}

// TODO: For multiple cameras we need to identify which stream it is.
// Perhaps from the mpegts metadata?
fn listen_udp_for_incoming_video_data(viewer_addresses: [1]std.net.Address) !void {
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    var mem = [_]u8{0} ** (1 << 16);
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fixed_buffer_allocator.allocator();

    var viewers = Viewers{undefined};
    comptime std.debug.assert(viewer_addresses.len == viewers.len);

    for (&viewers, 0..) |*viewer, i| {
        viewer.socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        try std.posix.connect(viewer.socket, &viewer_addresses[i].any, viewer_addresses[i].getOsSockLen());
        viewer.ring = try std.RingBuffer.init(allocator, 4096);
    }

    var video_file = try create_video_file();

    const timer_new_file = try std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, .{});
    try std.posix.timerfd_settime(timer_new_file, .{}, &.{
        .it_value = .{ .tv_sec = VIDEO_FILE_DURATION_SECONDS, .tv_nsec = 0 },
        .it_interval = .{ .tv_sec = VIDEO_FILE_DURATION_SECONDS, .tv_nsec = 0 },
    }, null);

    var poll_fds = [2]std.posix.pollfd{ .{
        .fd = socket,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }, .{
        .fd = timer_new_file,
        .events = std.posix.POLL.IN,
        .revents = 0,
    } };

    while (true) {
        _ = std.posix.poll(&poll_fds, -1) catch |err| {
            std.log.err("poll error {}", .{err});
            continue;
        };

        // TODO: Handle `POLL.ERR`.

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            handle_udp_packet(poll_fds[0].fd, video_file, viewers);
        } else if ((poll_fds[1].revents & std.posix.POLL.IN) != 0) {
            try handle_timer_trigger(poll_fds[1].fd, &video_file);
        } else {
            std.time.sleep(5 * std.time.ns_per_ms);
        }
    }
}

fn listen_tcp_for_incoming_events() !void {
    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    var server = try std.net.Address.listen(address, .{ .reuse_address = true });

    while (true) {
        var connection = try server.accept();
        const pid = try std.posix.fork();
        if (pid > 0) { // Parent.
            continue;
        }
        // Child
        try handle_tcp_connection_for_incoming_events(&connection);
    }
}

fn run_delete_old_video_files_forever() !void {
    const dir = try std.fs.cwd().openDir(".", .{ .iterate = true });

    while (true) {
        delete_old_video_files(dir);
        std.time.sleep(CLEANER_FREQUENCY_SECONDS * std.time.ns_per_s);
    }
}

fn delete_old_video_file(name: []const u8, now: i128) !void {
    const stat = std.fs.cwd().statFile(name) catch |err| {
        std.log.err("failed to stat file: {s} {}", .{ name, err });
        return err;
    };

    const elapsed_seconds = @divFloor((now - stat.mtime), std.time.ns_per_s);

    if (elapsed_seconds < VIDEO_FILE_MAX_RETAIN_DURATION_SECONDS) return;

    std.fs.cwd().deleteFile(name) catch |err| {
        std.log.err("failed to delete file: {s} {}", .{ name, err });
    };
    std.log.info("deleted {s} {}", .{ name, elapsed_seconds });
}

fn delete_old_video_files(dir: std.fs.Dir) void {
    var it = dir.iterate();

    const now_ns = std.time.nanoTimestamp();

    while (it.next()) |entry_opt| {
        if (entry_opt) |entry| {
            // Skip non-video files.
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "2")) continue;

            delete_old_video_file(entry.name, now_ns) catch continue;
        } else break; // End of directory.
    } else |err| {
        std.log.err("failed to iterate over directory entries: {}", .{err});
    }
}

fn fill_string_from_timestamp_ms(timestamp_ms: i64, out: *[256:0]u8) [:0]u8 {
    const timestamp_seconds: i64 = @divFloor(timestamp_ms, 1000);
    var time: c.struct_tm = undefined;
    _ = c.localtime_r(&@as(c.time_t, timestamp_seconds), &time);

    const date_c: [*c]u8 = @as([*c]u8, @ptrCast(@alignCast(out)));
    const res = c.strftime(date_c, 256, "%Y-%m-%d %H:%M:%S", @as([*c]const c.struct_tm, &time));
    std.debug.assert(res > 0);
    return out.*[0..res :0];
}

pub fn main() !void {
    const viewer_addresses = [_]std.net.Address{
        std.net.Address.parseIp4("100.64.152.16", 12346) catch unreachable,
    };

    var listen_udp_for_incoming_video_data_thread = try std.Thread.spawn(.{}, listen_udp_for_incoming_video_data, .{viewer_addresses});
    try listen_udp_for_incoming_video_data_thread.setName("incoming_video");

    var run_delete_old_video_files_forever_thread = try std.Thread.spawn(.{}, run_delete_old_video_files_forever, .{});
    try run_delete_old_video_files_forever_thread.setName("delete_old");

    try listen_tcp_for_incoming_events();
}

test "fill_string_from_timestamp_ms" {
    const timestamp: i64 = 1_716_902_774_000;
    var res: [256:0]u8 = undefined;
    const str = fill_string_from_timestamp_ms(timestamp, &res);

    std.debug.print("{s}", .{str});
    try std.testing.expect(std.mem.eql(u8, "2024-05-28 15:26:14", str));
}

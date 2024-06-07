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
    socket: std.posix.socket_t,
    need_chunking: bool,
    address: std.net.Address,
};

const VIEWERS_COUNT = 3;
const Viewers = [VIEWERS_COUNT]Viewer;
var VIEWERS = [VIEWERS_COUNT]Viewer{
    Viewer{
        .address = std.net.Address.parseIp4("100.64.152.16", 12346) catch unreachable,
        .need_chunking = true,
        .socket = undefined,
    }, // iphone
    Viewer{
        .address = std.net.Address.parseIp4("100.117.112.54", 12346) catch unreachable,
        .need_chunking = true,
        .socket = undefined,
    }, // ipad
    Viewer{
        .address = std.net.Address.parseIp4("100.86.75.91", 12346) catch unreachable,
        .need_chunking = false,
        .socket = undefined,
    }, // laptop
};
fn handle_tcp_connection_for_incoming_events(connection: *std.net.Server.Connection) !void {
    var event_file = try std.fs.cwd().openFile("events.txt", .{ .mode = .write_only });
    try event_file.seekFromEnd(0);

    var reader = std.io.bufferedReader(connection.stream.reader());

    while (true) {
        var read_buffer_event = [_]u8{0} ** @sizeOf(NetMessage);
        const n_read = try reader.read(&read_buffer_event);
        if (n_read < @sizeOf(NetMessage)) {
            std.log.debug("tcp read={} client likely closed the connection", .{n_read});
            std.process.exit(0);
        }
        std.debug.assert(n_read == @sizeOf(NetMessage));

        const message: NetMessage = std.mem.bytesToValue(NetMessage, &read_buffer_event);
        std.log.info("event {}", .{message});

        var date: [256:0]u8 = undefined;
        const date_str = fill_string_from_timestamp_ms(message.timestamp_ms, &date);

        const writer = event_file.writer();
        try std.fmt.format(writer, "{s} {}\n", .{ date_str, message.duration_ms });
    }
}

// TODO: Should it be in another thread/process?
fn broadcast_video_data_to_viewers(data: []u8) void {
    for (&VIEWERS) |*viewer| viewer_send: {
        // Why we cannot simply recv & send the same data in one go:
        // VLC is a viewer and only wants UDP packets smaller or equal in size to `VLC_UDP_PACKET_SIZE`.
        // So we have to potentially chunk one UDP packet into multiple smaller ones.
        const chunk_size = if (viewer.need_chunking) VLC_UDP_PACKET_SIZE else data.len;

        var i: usize = 0;
        while (i < data.len) {
            // Do not go past the end.
            const chunk_end = std.math.clamp(i + chunk_size, 0, data.len);

            if (std.posix.send(viewer.socket, data[i..chunk_end], 0)) |n_sent| {
                i += n_sent;
            } else |err| {
                std.log.debug("failed to write to viewer {}", .{err});
                break :viewer_send; // Skip this problematic viewer.
            }
        }
        std.debug.assert(i >= data.len);
    }
}

fn handle_video_data_udp_packet(in: std.posix.socket_t, video_file: std.fs.File) void {
    var read_buffer = [_]u8{0} ** (1 << 16); // Max UDP packet size. Read as much as possible.
    if (std.posix.read(in, &read_buffer)) |n_read| {
        std.log.debug("udp read={}", .{n_read});

        video_file.writeAll(read_buffer[0..n_read]) catch |err| {
            std.log.err("failed to write all to file {}", .{err});
        };

        broadcast_video_data_to_viewers(read_buffer[0..n_read]);
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

fn switch_to_new_video_file(fd: i32, video_file: *std.fs.File) !void {
    // Read & ignore the timer value.
    var read_buffer = [_]u8{0} ** 8;
    std.debug.assert(std.posix.read(fd, &read_buffer) catch 0 == 8);

    video_file.*.close();
    video_file.* = try create_video_file();
}

// TODO: For multiple cameras we need to identify which stream it is.
// Perhaps from the mpegts metadata?
fn listen_udp_for_incoming_video_data() !void {
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.sliceAsBytes(&[1]u32{1}));
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.sliceAsBytes(&[1]u32{1}));

    const address = std.net.Address.parseIp4("0.0.0.0", 12345) catch unreachable;
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    for (&VIEWERS) |*viewer| {
        viewer.socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        try std.posix.connect(viewer.socket, &viewer.address.any, viewer.address.getOsSockLen());
    }

    var video_file = try create_video_file();

    const timer_new_video_file = try std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, .{});
    try std.posix.timerfd_settime(timer_new_video_file, .{}, &.{
        .it_value = .{ .tv_sec = VIDEO_FILE_DURATION_SECONDS, .tv_nsec = 0 },
        .it_interval = .{ .tv_sec = VIDEO_FILE_DURATION_SECONDS, .tv_nsec = 0 },
    }, null);

    var poll_fds = [2]std.posix.pollfd{ .{
        .fd = socket,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }, .{
        .fd = timer_new_video_file,
        .events = std.posix.POLL.IN,
        .revents = 0,
    } };

    while (true) {
        _ = std.posix.poll(&poll_fds, -1) catch |err| {
            std.log.err("poll error {}", .{err});
            // All errors here are unrecoverable so it's better to simply exit.
            std.process.exit(1);
        };

        // TODO: Handle `POLL.ERR` ?

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            handle_video_data_udp_packet(poll_fds[0].fd, video_file);
        } else if ((poll_fds[1].revents & std.posix.POLL.IN) != 0) {
            try switch_to_new_video_file(poll_fds[1].fd, &video_file);
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
    std.log.info("viewers {any}", .{VIEWERS});

    var listen_udp_for_incoming_video_data_thread = try std.Thread.spawn(.{}, listen_udp_for_incoming_video_data, .{});
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

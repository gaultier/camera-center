const std = @import("std");

// const State = enum {
//     Idle,
//     MotionStarted,
//     MotionStopped,
// };

// const ParseState = enum { None, SeenMotion };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch unreachable;

    var destination_address: []const u8 = undefined;
    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |arg| {
        destination_address = arg;
    }
    const parsed_address = std.net.Address.parseIp4(destination_address, 12345) catch unreachable;
    std.posix.connect(socket, &parsed_address.any, parsed_address.getOsSockLen()) catch |err| {
        std.debug.print("failed to connect socket {}", .{err});
        std.posix.exit(1);
    };

    const allocator = arena.allocator();
    const child_args = [_][]const u8{
        "libcamera-vid",
        "-t",
        "0",
        "--inline",
        "--width",
        "1920",
        "--height",
        "1080",
        "--hdr",
        "-n",
        "--bitrate",
        "1000000",
        "--post-process-file=motion_detect.json",
        "--lores-width",
        "128",
        "--lores-height",
        "128",
        "--codec",
        "libav",
        "--libav-format=mpegts",
        "-o",
        "-",
    };
    var child = std.ChildProcess.init(&child_args, allocator);
    // child.stderr_behavior = std.ChildProcess.StdIo.Pipe;
    child.stdout = std.fs.File{ .handle = socket };
    child.stdout_behavior = std.ChildProcess.StdIo.Pipe;

    // var stderr_buf = [_]u8{0} ** 1024;

    try child.spawn();
    const term = try child.wait();
    std.debug.print("child wait {}", .{term});

    // var poll_fds = [2]std.posix.pollfd{ .{
    //     .fd = child.stderr.?.handle,
    //     .events = std.posix.POLL.IN,
    //     .revents = 0,
    // }, .{
    //     .fd = child.stdout.?.handle,
    //     .events = std.posix.POLL.IN,
    //     .revents = 0,
    // } };

    // var state = State.Idle;
    // var parse_state = ParseState.None;

    // while (true) {
    //     const res = std.posix.poll(&poll_fds, -1) catch |err| {
    //         std.debug.print("poll error {}\n", .{err});
    //         continue;
    //     };
    //     std.debug.assert(res != 0);

    //     if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
    //         if (std.posix.read(poll_fds[0].fd, &stderr_buf)) |read| {
    //             std.debug.print("stderr len={} read={s}\n", .{ read, stderr_buf[0..read] });

    //             const stderr = stderr_buf[0..read];
    //             var it = std.mem.splitAny(u8, stderr, "\n ");

    //             while (it.next()) |word| {
    //                 if (std.mem.eql(u8, word, "Motion")) {
    //                     parse_state = ParseState.SeenMotion;
    //                 } else if (parse_state == ParseState.SeenMotion and std.mem.eql(u8, word, "detected")) {
    //                     state = State.MotionStarted;
    //                     std.debug.print("state=read frame data\n", .{});
    //                     parse_state = ParseState.None;
    //                 } else if (parse_state == ParseState.SeenMotion and std.mem.eql(u8, word, "stopped")) {
    //                     state = State.MotionStopped;
    //                     std.debug.print("state=idle\n", .{});
    //                     parse_state = ParseState.None;
    //                 }
    //             }
    //         } else |err| {
    //             std.debug.print("stderr read error {}\n", .{err});
    //         }
    //     }

    //     if ((poll_fds[1].revents & std.posix.POLL.IN) != 0) {
    //         if (std.posix.read(poll_fds[1].fd, &stdout_buf)) |read| {
    //             const message = stdout_buf[0..read];
    //             _ = message;

    //             if (state == State.MotionStarted) {
    //                 // TODO
    //             } else if (state == State.MotionStopped) {
    //                 // TODO
    //             }
    //         } else |err| {
    //             std.debug.print("stdout read error {}\n", .{err});
    //         }
    //     }
    // }
}

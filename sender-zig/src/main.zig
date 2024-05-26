const std = @import("std");

const State = enum {
    None,
    MotionStarted,
    MotionStopped,
};

const ParseState = enum { None, SeenMotion };

fn parse_child_output(in: std.fs.File, address_dest: std.net.Address) !void {
    var read_buf = [_]u8{0} ** 1024;

    var state = State.None;
    var parse_state = ParseState.None;
    var time_start: i64 = undefined;

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    try std.posix.connect(socket, &address_dest.any, address_dest.getOsSockLen());

    while (true) {
        if (std.posix.read(in.handle, &read_buf)) |read| {
            std.debug.print("stderr len={} read={s}\n", .{ read, read_buf[0..read] });
            if (read == 0) {
                std.debug.print("0 read, child likely stopped", .{});
                return;
            }

            const stderr = read_buf[0..read];
            var it = std.mem.splitAny(u8, stderr, "\n ");

            while (it.next()) |word| {
                if (std.mem.eql(u8, word, "Motion")) {
                    parse_state = ParseState.SeenMotion;
                } else if (parse_state == ParseState.SeenMotion and std.mem.eql(u8, word, "detected")) {
                    state = State.MotionStarted;
                    std.debug.print("state=read frame data\n", .{});
                    parse_state = ParseState.None;
                    time_start = std.time.milliTimestamp();
                } else if (parse_state == ParseState.SeenMotion and std.mem.eql(u8, word, "stopped")) {
                    state = State.MotionStopped;
                    std.debug.print("state=idle\n", .{});
                    parse_state = ParseState.None;

                    const time_end = std.time.milliTimestamp();
                    _ = time_end;
                }
            }
        } else |err| {
            std.debug.print("stderr read error {}\n", .{err});
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

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

    const allocator = arena.allocator();
    const udp_address: []const u8 = try std.mem.concat(allocator, u8, &[_][]const u8{ "udp://", destination_address, ":", destination_port });
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
        udp_address,
    };
    var child = std.ChildProcess.init(&child_args, allocator);
    child.stderr_behavior = std.ChildProcess.StdIo.Pipe;

    try child.spawn();
    try parse_child_output(child.stderr.?, address);

    const term = try child.wait();
    std.debug.print("child wait {}", .{term});
}

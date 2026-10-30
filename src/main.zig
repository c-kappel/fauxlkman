const std = @import("std");
const Io = std.Io;
const mp3 = @import("mp3");

const usage =
    \\usage:
    \\  fauxlkman decode <in.mp3> <out.wav>
    \\  fauxlkman encode <in.wav> <out.mp3> [--bitrate <kbps>] [--stereo]
    \\  fauxlkman info <in.mp3>
    \\
;

const max_file_size = 1 << 30;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const cwd = Io.Dir.cwd();

    if (args.len < 3) return fail(usage, .{});
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "decode")) {
        if (args.len != 4) return fail(usage, .{});
        const data = try cwd.readFileAlloc(io, args[2], arena, .limited(max_file_size));
        const pcm = mp3.decode(arena, data) catch |err| return fail("decode failed: {t}\n", .{err});
        const bytes = try mp3.wav.write(arena, pcm);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = bytes });
        std.debug.print("decoded {d} samples/channel, {d} ch, {d} Hz\n", .{ pcm.framesPerChannel(), pcm.channels, pcm.sample_rate });
    } else if (std.mem.eql(u8, cmd, "encode")) {
        if (args.len < 4) return fail(usage, .{});
        var opts: mp3.EncodeOptions = .{};
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--bitrate") and i + 1 < args.len) {
                i += 1;
                opts.bitrate_kbps = std.fmt.parseInt(u32, args[i], 10) catch return fail("bad bitrate\n", .{});
            } else if (std.mem.eql(u8, args[i], "--stereo")) {
                opts.stereo_mode = .stereo;
            } else return fail(usage, .{});
        }
        const data = try cwd.readFileAlloc(io, args[2], arena, .limited(max_file_size));
        const pcm = mp3.wav.read(arena, data) catch |err| return fail("reading wav failed: {t}\n", .{err});
        const encoded = mp3.encode(arena, pcm.samples, pcm.channels, pcm.sample_rate, opts) catch |err|
            return fail("encode failed: {t}\n", .{err});
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = encoded });
        std.debug.print("encoded {d} bytes at {d} kbit/s\n", .{ encoded.len, opts.bitrate_kbps });
    } else if (std.mem.eql(u8, cmd, "info")) {
        const data = try cwd.readFileAlloc(io, args[2], arena, .limited(max_file_size));
        var it: mp3.stream.FrameIterator = .init(data);
        var frames: usize = 0;
        var samples: usize = 0;
        var first: ?mp3.frame.Header = null;
        while (it.next()) |f| {
            if (frames == 0 and mp3.stream.parseInfoTag(f) != null) continue;
            if (first == null) first = f.header;
            frames += 1;
            samples += f.header.samplesPerFrame();
        }
        const h = first orelse return fail("no MPEG audio frames found\n", .{});
        const secs = @as(f64, @floatFromInt(samples)) / @as(f64, @floatFromInt(h.sampleRate()));
        std.debug.print("{t} layer III, {d} Hz, {t}, {d} kbit/s (first frame), {d} frames, {d:.2}s\n", .{
            h.version, h.sampleRate(), h.mode, h.bitrateKbps(), frames, secs,
        });
    } else return fail(usage, .{});
}

fn fail(comptime fmt: []const u8, args: anytype) error{Failed} {
    std.debug.print(fmt, args);
    return error.Failed;
}

const std = @import("std");
const Io = std.Io;
const mp3 = @import("mp3");
const player = @import("player");

const usage =
    \\usage:
    \\  fauxlkman decode <in.mp3> <out.wav>
    \\  fauxlkman encode <in.wav> <out.mp3> [--bitrate <kbps>] [--stereo]
    \\  fauxlkman info <in.mp3>
    \\  fauxlkman play <song.mp3>...
    \\
;

const controls =
    \\space pause  ←/→ 5s  [/] 30s  0-9 jump to 0-90%  r restart  p/n prev/next  q quit
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
    } else if (std.mem.eql(u8, cmd, "play")) {
        var playlist = player.createPlaylist("queue");
        for (args[2..]) |path| {
            playlist.addSong(.{ .artist = 0, .duration = 0, .timestamp = 0, .path = path }) catch
                return fail("too many songs (max {d})\n", .{playlist.songs.len});
        }
        try play(init.gpa, io, &playlist);
    } else return fail(usage, .{});
}

const Action = enum { prev, next, quit };

/// Plays the playlist in order. Each song is decoded fully into memory before
/// it starts, so seeking within it is instant.
fn play(gpa: std.mem.Allocator, io: Io, playlist: *const player.Playlist) !void {
    const tracks = playlist.tracks();
    const term: ?Terminal = Terminal.enterRaw() catch null;
    defer if (term) |t| t.restore();
    if (term != null) std.debug.print(controls, .{});

    var index: usize = 0;
    while (index < tracks.len) {
        const song = tracks[index];
        const data = Io.Dir.cwd().readFileAlloc(io, song.path, gpa, .limited(max_file_size)) catch |err| {
            std.debug.print("skipping {s}: {t}\n", .{ song.path, err });
            index += 1;
            continue;
        };
        const decoded = mp3.decode(gpa, data);
        gpa.free(data);
        const pcm = decoded catch |err| {
            std.debug.print("skipping {s}: {t}\n", .{ song.path, err });
            index += 1;
            continue;
        };
        defer gpa.free(pcm.samples);

        var engine: player.playback.Engine = .init(pcm.samples, pcm.channels, pcm.sample_rate);
        const output = player.coreaudio.Output.start(&engine) catch |err| return fail("audio output failed: {t}\n", .{err});
        defer output.deinit();
        engine.play();

        const action = try control(io, &engine, term != null, song.path, index, tracks.len);
        std.debug.print("\n", .{});
        switch (action) {
            .next => index += 1,
            .prev => index -|= 1,
            .quit => break,
        }
    }
}

/// Handles key presses and redraws the status line until the song ends or the
/// user moves to another song.
fn control(io: Io, engine: *player.playback.Engine, interactive: bool, name: []const u8, index: usize, count: usize) !Action {
    while (!engine.isFinished()) {
        std.debug.print("\r\x1b[2K{s} [{d}/{d}] {s}  {f} / {f}", .{
            if (engine.isPlaying()) "▶" else "⏸",
            index + 1,
            count,
            std.fs.path.basename(name),
            Clock{ .seconds = engine.positionSeconds() },
            Clock{ .seconds = engine.durationSeconds() },
        });

        if (!interactive) {
            try io.sleep(.fromMilliseconds(100), .awake);
            continue;
        }
        // Raw mode returns after at most 100 ms with whatever was typed.
        var buf: [8]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
        const keys = buf[0..n];
        if (std.mem.eql(u8, keys, "\x1b[D")) {
            engine.rewind(5);
        } else if (std.mem.eql(u8, keys, "\x1b[C")) {
            engine.skip(5);
        } else for (keys) |k| switch (k) {
            ' ' => engine.togglePause(),
            '[' => engine.rewind(30),
            ']' => engine.skip(30),
            'r' => engine.seek(0),
            '0'...'9' => engine.seekSeconds(engine.durationSeconds() * @as(f64, @floatFromInt(k - '0')) / 10),
            'n' => return .next,
            'p' => return .prev,
            'q', 3 => return .quit, // 3 = ctrl-c
            else => {},
        };
    }
    return .next;
}

const Clock = struct {
    seconds: f64,

    pub fn format(c: Clock, w: *Io.Writer) Io.Writer.Error!void {
        const s: u64 = @intFromFloat(@max(0, c.seconds));
        try w.print("{d:0>2}:{d:0>2}", .{ s / 60, s % 60 });
    }
};

/// Puts the terminal in raw mode: no line buffering or echo, and reads that
/// time out after 100 ms so the status line keeps updating.
const Terminal = struct {
    original: std.posix.termios,

    fn enterRaw() !Terminal {
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        return .{ .original = original };
    }

    fn restore(t: Terminal) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, t.original) catch {};
    }
};

fn fail(comptime fmt: []const u8, args: anytype) error{Failed} {
    std.debug.print(fmt, args);
    return error.Failed;
}

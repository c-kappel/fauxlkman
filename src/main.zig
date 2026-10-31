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
        const tags = try mp3.id3.read(arena, data);
        const fields = [_]struct { []const u8, ?[]const u8 }{
            .{ "title", tags.title },               .{ "artist", tags.artist },
            .{ "album artist", tags.album_artist }, .{ "album", tags.album },
            .{ "year", tags.year },                 .{ "track", tags.track },
        };
        for (fields) |f| if (f[1]) |v| std.debug.print("{s}: {s}\n", .{ f[0], v });
    } else if (std.mem.eql(u8, cmd, "play")) {
        var playlist = player.createPlaylist("queue");
        for (args[2..]) |path| {
            playlist.addSong(.{ .artist = 0, .duration = 0, .timestamp = 0, .path = path }) catch
                return fail("too many songs (max {d})\n", .{playlist.songs.len});
        }
        try play(init.gpa, io, &playlist);
    } else return fail(usage, .{});
}

const Action = enum { prev, next, quit, advanced, finished };

/// Plays the playlist in order. Each song is decoded on a background thread
/// into a buffer that holds the whole song, so playback starts right away and
/// seeking within it is instant. The next song is decoded while the current
/// one plays and follows it without a gap.
fn play(gpa: std.mem.Allocator, io: Io, playlist: *const player.Playlist) !void {
    const term: ?Terminal = Terminal.enterRaw() catch null;
    defer if (term) |t| t.restore();
    if (term != null) std.debug.print(controls, .{});

    var session: Session = .{ .gpa = gpa, .io = io, .songs = playlist.tracks() };
    defer session.deinit();
    try session.run(term != null);
}

/// A playlist entry whose file has been read and is being decoded.
const Loaded = struct {
    index: usize,
    data: []u8,
    tags: mp3.id3.Tags,
    decoding: *player.Decoding,

    fn track(l: Loaded) *player.playback.Track {
        return &l.decoding.track;
    }

    fn deinit(l: Loaded, gpa: std.mem.Allocator) void {
        l.decoding.deinit(gpa);
        l.tags.deinit(gpa);
        gpa.free(l.data);
    }
};

const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    songs: []const player.Song,
    current: ?Loaded = null,
    /// The song after `current`, queued in the engine when the formats match.
    next: ?Loaded = null,
    /// Whether loading the song after `current` has been attempted.
    prefetched: bool = false,
    engine: player.playback.Engine = undefined,
    output: ?player.coreaudio.Output = null,

    fn deinit(s: *Session) void {
        s.stopOutput();
        s.release();
    }

    fn run(s: *Session, interactive: bool) !void {
        s.current = s.load(0, .forward) orelse return;
        while (true) {
            if (s.output == null) try s.startOutput();
            s.prefetch();
            const cur = s.current.?;
            var label_buf: [512]u8 = undefined;
            const label = songLabel(&label_buf, cur.tags, s.songs[cur.index].path);
            const action = try control(s.io, &s.engine, interactive, label, cur.index, s.songs.len);
            std.debug.print("\n", .{});
            switch (action) {
                .advanced => {
                    // The engine continued into the queued song by itself.
                    s.quiesce();
                    cur.deinit(s.gpa);
                    s.current = s.next;
                    s.next = null;
                    s.prefetched = false;
                },
                .finished, .next => {
                    // Reaching the end without advancing means the next song
                    // (if any) needs the output reopened in another format.
                    const n = s.next orelse return;
                    s.next = null;
                    s.switchTo(n);
                },
                .prev => {
                    if (cur.index == 0 or s.engine.positionSeconds() > 3) {
                        s.engine.seek(0);
                        continue;
                    }
                    const p = s.load(cur.index - 1, .backward) orelse {
                        s.engine.seek(0);
                        continue;
                    };
                    s.switchTo(p);
                },
                .quit => return,
            }
        }
    }

    /// Makes `l` the current song, freeing the previous current and next
    /// songs. Switches in place when the format allows; otherwise the output
    /// is reopened on the next loop iteration.
    fn switchTo(s: *Session, l: Loaded) void {
        if (s.output != null and s.engine.accepts(l.track())) {
            s.engine.enqueue(null);
            s.engine.load(l.track());
            s.engine.play();
            s.quiesce();
        } else s.stopOutput();
        s.release();
        s.current = l;
    }

    /// Starts decoding the song after the current one and queues it for
    /// gapless playback.
    fn prefetch(s: *Session) void {
        if (s.prefetched) return;
        s.prefetched = true;
        s.next = s.load(s.current.?.index + 1, .forward);
        if (s.next) |n| if (s.engine.accepts(n.track())) s.engine.enqueue(n.track());
    }

    const Direction = enum { forward, backward };

    /// Starts decoding the first playable song from `from`, moving in `dir`
    /// past songs that can't be read.
    fn load(s: *Session, from: usize, dir: Direction) ?Loaded {
        var i = from;
        while (i < s.songs.len) {
            if (s.open(i)) |l| return l else |err| {
                std.debug.print("\r\x1b[2Kskipping {s}: {t}\n", .{ s.songs[i].path, err });
            }
            if (dir == .backward) {
                if (i == 0) return null;
                i -= 1;
            } else i += 1;
        }
        return null;
    }

    fn open(s: *Session, i: usize) !Loaded {
        const data = try Io.Dir.cwd().readFileAlloc(s.io, s.songs[i].path, s.gpa, .limited(max_file_size));
        errdefer s.gpa.free(data);
        const tags = try mp3.id3.read(s.gpa, data);
        errdefer tags.deinit(s.gpa);
        return .{ .index = i, .data = data, .tags = tags, .decoding = try player.Decoding.start(s.gpa, data) };
    }

    fn startOutput(s: *Session) !void {
        const t = s.current.?.track();
        s.engine = .init(t.channels, t.sample_rate);
        s.engine.load(t);
        s.engine.play();
        s.output = player.coreaudio.Output.start(&s.engine) catch |err| return fail("audio output failed: {t}\n", .{err});
    }

    fn stopOutput(s: *Session) void {
        if (s.output) |o| o.deinit();
        s.output = null;
    }

    /// Waits for two complete render calls, after which the audio thread no
    /// longer touches tracks dropped from the engine before this call. Closes
    /// the output instead if the device stops calling back.
    fn quiesce(s: *Session) void {
        const start = s.engine.renderCount();
        var waited: usize = 0;
        while (s.engine.renderCount() < start + 2) : (waited += 1) {
            if (waited >= 500) return s.stopOutput();
            s.io.sleep(.fromMilliseconds(1), .awake) catch return s.stopOutput();
        }
    }

    /// Frees the current and next songs. They must no longer be referenced
    /// by a running output.
    fn release(s: *Session) void {
        if (s.current) |l| l.deinit(s.gpa);
        if (s.next) |l| l.deinit(s.gpa);
        s.current = null;
        s.next = null;
        s.prefetched = false;
    }
};

/// Handles key presses and redraws the status line until the song ends, the
/// engine moves on to the queued song, or the user picks another song.
fn control(io: Io, engine: *player.playback.Engine, interactive: bool, label: []const u8, index: usize, count: usize) !Action {
    const track = engine.currentTrack();
    while (true) {
        if (engine.currentTrack() != track) return .advanced;
        if (engine.isFinished()) return .finished;
        drawStatus(engine, label, index, count);

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
}

/// Redraws the status line, shortening the song label so the line never
/// wraps (a wrapped line can't be redrawn in place with `\r`).
fn drawStatus(engine: *const player.playback.Engine, label: []const u8, index: usize, count: usize) void {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s} [{d}/{d}] ", .{
        if (engine.isPlaying()) "▶" else "⏸", index + 1, count,
    }) catch "";
    var suffix_buf: [64]u8 = undefined;
    var suffix_w: Io.Writer = .fixed(&suffix_buf);
    suffix_w.print("  {f} / {f}", .{
        Clock{ .seconds = engine.positionSeconds() },
        Clock{ .seconds = engine.durationSeconds() },
    }) catch {};
    const buffered = engine.bufferedFraction();
    if (buffered < 1) suffix_w.print("  decoding {d:.0}%", .{buffered * 100}) catch {};
    const suffix = suffix_w.buffered();

    // Leave the last column free: writing into it makes some terminals wrap.
    const room = (terminalWidth() orelse 80) -| (columns(prefix) + columns(suffix) + 1);
    var fit_buf: [512]u8 = undefined;
    std.debug.print("\r\x1b[2K{s}{s}{s}", .{ prefix, fit(&fit_buf, label, room), suffix });
}

/// "Artist – Title · Album" from the song's tags, or the file name if the
/// song has no title tag.
fn songLabel(buf: []u8, tags: mp3.id3.Tags, path: []const u8) []const u8 {
    const title = tags.title orelse return std.fs.path.basename(path);
    var w: Io.Writer = .fixed(buf);
    if (tags.artist orelse tags.album_artist) |artist| w.print("{s} – ", .{artist}) catch {};
    w.writeAll(title) catch {};
    if (tags.album) |album| w.print(" · {s}", .{album}) catch {};
    return w.buffered();
}

/// Copies `s` into `buf`, cut to at most `max_cols` terminal columns (ending
/// in "…" if shortened), with control characters replaced.
fn fit(buf: []u8, s: []const u8, max_cols: usize) []const u8 {
    if (max_cols == 0) return "";
    const shorten = columns(s) > max_cols;
    const budget = if (shorten) max_cols - 1 else max_cols;
    var n: usize = 0;
    var cols: usize = 0;
    var it = codepoints(s);
    while (it.next()) |cp| {
        const w = cpWidth(cp.value);
        if (cols + w > budget or n + cp.bytes.len + "…".len > buf.len) break;
        for (cp.bytes) |b| {
            buf[n] = if (b < 0x20 or b == 0x7f) '?' else b;
            n += 1;
        }
        cols += w;
    }
    if (shorten) {
        @memcpy(buf[n..][0.."…".len], "…");
        n += "…".len;
    }
    return buf[0..n];
}

/// Approximate display width of `s` in terminal columns.
fn columns(s: []const u8) usize {
    var cols: usize = 0;
    var it = codepoints(s);
    while (it.next()) |cp| cols += cpWidth(cp.value);
    return cols;
}

/// Iterates codepoints of UTF-8 text; invalid UTF-8 is treated as Latin-1
/// bytes so every byte still advances.
const Codepoints = struct {
    s: []const u8,
    i: usize = 0,
    valid: bool,

    const Item = struct { value: u21, bytes: []const u8 };

    fn next(it: *Codepoints) ?Item {
        if (it.i >= it.s.len) return null;
        const len: usize = if (it.valid) std.unicode.utf8ByteSequenceLength(it.s[it.i]) catch 1 else 1;
        const bytes = it.s[it.i..][0..len];
        it.i += len;
        const value: u21 = if (len == 1) bytes[0] else std.unicode.utf8Decode(bytes) catch '?';
        return .{ .value = value, .bytes = bytes };
    }
};

fn codepoints(s: []const u8) Codepoints {
    return .{ .s = s, .valid = std.unicode.utf8ValidateSlice(s) };
}

/// 2 for East Asian wide characters and emoji, 1 otherwise.
fn cpWidth(cp: u21) usize {
    const wide = [_][2]u21{
        .{ 0x1100, 0x115f },  .{ 0x2e80, 0xa4cf },   .{ 0xac00, 0xd7a3 },
        .{ 0xf900, 0xfaff },  .{ 0xfe30, 0xfe4f },   .{ 0xff00, 0xff60 },
        .{ 0xffe0, 0xffe6 },  .{ 0x1f300, 0x1f64f }, .{ 0x1f900, 0x1f9ff },
        .{ 0x20000, 0x3fffd },
    };
    for (wide) |r| if (cp >= r[0] and cp <= r[1]) return 2;
    return 1;
}

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

fn terminalWidth() ?usize {
    var ws: std.posix.winsize = undefined;
    if (ioctl(std.posix.STDERR_FILENO, std.posix.T.IOCGWINSZ, &ws) != 0 or ws.col == 0) return null;
    return ws.col;
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

const testing = std.testing;

test "song label prefers tags and falls back to the file name" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Björk – Hyperballad · Post", songLabel(&buf, .{ .title = "Hyperballad", .artist = "Björk", .album = "Post" }, "x.mp3"));
    try testing.expectEqualStrings("Various – Intro", songLabel(&buf, .{ .title = "Intro", .album_artist = "Various" }, "x.mp3"));
    try testing.expectEqualStrings("01 track.mp3", songLabel(&buf, .{ .artist = "No Title" }, "music/01 track.mp3"));
}

test "fit shortens to the column budget on codepoint boundaries" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("short", fit(&buf, "short", 10));
    try testing.expectEqualStrings("Björk – H…", fit(&buf, "Björk – Hyperballad", 10));
    // Wide characters take two columns each.
    try testing.expectEqual(@as(usize, 6), columns("日本語"));
    try testing.expectEqualStrings("日本…", fit(&buf, "日本語のうた", 5));
    try testing.expectEqualStrings("", fit(&buf, "anything", 0));
    try testing.expectEqualStrings("a?[2J", fit(&buf, "a\x1b[2J", 10));
    // Invalid UTF-8 still advances byte by byte.
    try testing.expectEqual(@as(usize, 3), columns("a\xffb"));
}

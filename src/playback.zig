//! Real-time playback of songs decoded into memory.
//!
//! Each song is a `Track`: a buffer sized for the whole song that a background
//! thread fills with interleaved 16-bit PCM, publishing how many frames are
//! ready. Playback can start as soon as the first frames are in, and seeking
//! or rewinding is just a change of read position: no decoder state has to be
//! rebuilt. A second track can be queued and is switched to mid-buffer when
//! the first one ends, for gapless playback.
//!
//! `render` is called from the audio device's real-time thread and never
//! allocates or locks; the control functions (`load`, `seek`, `rewind`, ...)
//! may be called from any other thread and communicate through atomics.
//!
//! To avoid clicks, seeks crossfade from the old position to the new one and
//! pause/resume ramp the gain, both over `fade_frames`.

const std = @import("std");

const Atomic = std.atomic.Value;

/// Length of the seek crossfade and pause/resume ramp (~5 ms at 44.1 kHz).
pub const fade_frames = 256;

const no_seek = std.math.maxInt(usize);

pub const Track = struct {
    /// Interleaved PCM for the whole song, `channels` samples per frame. Only
    /// the first `ready` frames are valid.
    samples: []const i16,
    channels: u8,
    sample_rate: u32,
    /// Frames decoded so far, stored with release ordering by the decoder.
    ready: Atomic(usize) = .init(0),

    /// A track whose samples will be filled in later; see `ready`.
    pub fn init(samples: []const i16, channels: u8, sample_rate: u32) Track {
        std.debug.assert(channels > 0 and samples.len % channels == 0);
        return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
    }

    /// A track whose samples are all valid already.
    pub fn complete(samples: []const i16, channels: u8, sample_rate: u32) Track {
        var t: Track = .init(samples, channels, sample_rate);
        t.ready = .init(t.totalFrames());
        return t;
    }

    pub fn totalFrames(self: *const Track) usize {
        return self.samples.len / self.channels;
    }

    pub fn readyFrames(self: *const Track) usize {
        return self.ready.load(.acquire);
    }
};

pub const Engine = struct {
    /// Output format. Every track played must match it (see `accepts`).
    channels: u8,
    sample_rate: u32,

    /// Track being played. Written only by the render thread.
    current: Atomic(?*Track) = .init(null),
    /// Track to switch to on the next render call, from the start.
    pending_track: Atomic(?*Track) = .init(null),
    /// Track to continue with, gaplessly, when the current one ends.
    queued: Atomic(?*Track) = .init(null),
    /// Next frame of `current` to play. Written only by the render thread.
    position: Atomic(usize) = .init(0),
    /// Frame to jump to on the next render call, or `no_seek`.
    pending_seek: Atomic(usize) = .init(no_seek),
    playing: Atomic(bool) = .init(false),
    /// Set by the render thread once there is nothing left to play.
    finished: Atomic(bool) = .init(false),
    /// Number of completed render calls; see `renderCount`.
    renders: Atomic(u64) = .init(0),

    // Render-thread state.
    gain: f32 = 0,
    fade_from: usize = 0,
    fade_left: usize = 0,

    pub fn init(channels: u8, sample_rate: u32) Engine {
        return .{ .channels = channels, .sample_rate = sample_rate };
    }

    /// Whether `track` can be played without reopening the output device.
    pub fn accepts(self: *const Engine, track: *const Track) bool {
        return track.channels == self.channels and track.sample_rate == self.sample_rate;
    }

    /// Switches to `track`, from its start, on the next render call.
    pub fn load(self: *Engine, track: *Track) void {
        std.debug.assert(self.accepts(track));
        self.pending_seek.store(no_seek, .release);
        self.pending_track.store(track, .release);
        self.finished.store(false, .release);
    }

    /// Sets (or with null, clears) the track to continue with when the
    /// current one ends.
    pub fn enqueue(self: *Engine, track: ?*Track) void {
        if (track) |t| std.debug.assert(self.accepts(t));
        self.queued.store(track, .release);
    }

    /// The track being played, including one requested by `load` but not yet
    /// picked up by the render thread.
    pub fn currentTrack(self: *const Engine) ?*Track {
        return self.pending_track.load(.acquire) orelse self.current.load(.acquire);
    }

    /// Completed render calls. Once this has advanced by two since a track
    /// was last referenced by `load`/`enqueue`, the render thread no longer
    /// touches it and it may be freed.
    pub fn renderCount(self: *const Engine) u64 {
        return self.renders.load(.acquire);
    }

    pub fn play(self: *Engine) void {
        self.playing.store(true, .release);
    }

    pub fn pause(self: *Engine) void {
        self.playing.store(false, .release);
    }

    pub fn togglePause(self: *Engine) void {
        self.playing.store(!self.playing.load(.acquire), .release);
    }

    pub fn isPlaying(self: *const Engine) bool {
        return self.playing.load(.acquire);
    }

    pub fn isFinished(self: *const Engine) bool {
        return self.finished.load(.acquire);
    }

    fn totalFrames(self: *const Engine) usize {
        const t = self.currentTrack() orelse return 0;
        return t.totalFrames();
    }

    /// Current position in frames, including a seek that has been requested
    /// but not yet picked up by the render thread.
    pub fn currentFrame(self: *const Engine) usize {
        const pending = self.pending_seek.load(.acquire);
        if (pending != no_seek) return pending;
        if (self.pending_track.load(.acquire) != null) return 0;
        return self.position.load(.acquire);
    }

    /// Jumps to `frame` within the current track, clamped to its end.
    pub fn seek(self: *Engine, frame: usize) void {
        const target = @min(frame, self.totalFrames());
        self.pending_seek.store(target, .release);
        if (target < self.totalFrames()) self.finished.store(false, .release);
    }

    pub fn seekSeconds(self: *Engine, seconds: f64) void {
        self.seek(self.secondsToFrames(@max(0, seconds)));
    }

    /// Moves the position by `seconds` (negative rewinds).
    pub fn skip(self: *Engine, seconds: f64) void {
        const cur: f64 = @floatFromInt(self.currentFrame());
        const delta = seconds * @as(f64, @floatFromInt(self.sample_rate));
        self.seek(@intFromFloat(@max(0, cur + delta)));
    }

    pub fn rewind(self: *Engine, seconds: f64) void {
        self.skip(-seconds);
    }

    pub fn positionSeconds(self: *const Engine) f64 {
        return self.framesToSeconds(self.currentFrame());
    }

    pub fn durationSeconds(self: *const Engine) f64 {
        return self.framesToSeconds(self.totalFrames());
    }

    /// Fraction of the current track decoded so far, in [0, 1].
    pub fn bufferedFraction(self: *const Engine) f64 {
        const t = self.currentTrack() orelse return 0;
        const total = t.totalFrames();
        if (total == 0) return 1;
        return @as(f64, @floatFromInt(t.readyFrames())) / @as(f64, @floatFromInt(total));
    }

    fn secondsToFrames(self: *const Engine, seconds: f64) usize {
        return @intFromFloat(seconds * @as(f64, @floatFromInt(self.sample_rate)));
    }

    fn framesToSeconds(self: *const Engine, frames: usize) f64 {
        return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Fills `out` with interleaved f32 samples (`channels` per frame).
    /// Real-time safe: called from the audio thread.
    pub fn render(self: *Engine, out: []f32) void {
        defer _ = self.renders.fetchAdd(1, .release);
        const ch = self.channels;
        const frames = out.len / ch;
        var track = self.current.load(.monotonic);
        var pos = self.position.load(.monotonic);

        if (self.pending_track.swap(null, .acq_rel)) |t| {
            track = t;
            pos = 0;
            self.fade_left = 0;
            self.gain = 0;
        }
        var ready = if (track) |t| t.readyFrames() else 0;

        const target = self.pending_seek.swap(no_seek, .acq_rel);
        if (track) |t| if (target != no_seek and target != pos) {
            // Only crossfade if something audible is playing.
            self.fade_left = if (self.gain > 0 and pos < @min(ready, t.totalFrames())) fade_frames else 0;
            self.fade_from = pos;
            pos = @min(target, t.totalFrames());
        };

        const want: f32 = if (self.playing.load(.acquire)) 1 else 0;
        const step: f32 = 1.0 / @as(f32, fade_frames);

        var i: usize = 0;
        while (i < frames) {
            const t = track orelse break;
            if (self.gain == 0 and want == 0) break;
            if (pos >= t.totalFrames() and self.fade_left == 0) {
                // Continue straight into the queued track, if any.
                const next = self.queued.swap(null, .acq_rel) orelse break;
                track = next;
                pos = 0;
                ready = next.readyFrames();
                continue;
            }
            // Ran ahead of the decoder: output silence until it catches up.
            if (pos >= ready and pos < t.totalFrames()) break;

            if (self.gain < want) self.gain = @min(want, self.gain + step) else if (self.gain > want) self.gain = @max(want, self.gain - step);

            const fade: f32 = if (self.fade_left > 0) @as(f32, @floatFromInt(self.fade_left)) / fade_frames else 0;
            for (out[i * ch ..][0..ch], 0..) |*s, c| {
                var v = sampleAt(t, ready, pos, c) * (1 - fade);
                if (fade > 0) v += sampleAt(t, ready, self.fade_from, c) * fade;
                s.* = v * self.gain;
            }
            if (self.fade_left > 0) {
                self.fade_left -= 1;
                self.fade_from += 1;
            }
            if (pos < t.totalFrames()) pos += 1;
            i += 1;
        }
        @memset(out[i * ch ..], 0);

        self.current.store(track, .release);
        self.position.store(pos, .release);
        const done = if (track) |t| pos >= t.totalFrames() and self.fade_left == 0 and self.queued.load(.acquire) == null else true;
        self.finished.store(done, .release);
    }

    fn sampleAt(t: *const Track, ready: usize, frame: usize, c: usize) f32 {
        if (frame >= ready or frame >= t.totalFrames()) return 0;
        return @as(f32, @floatFromInt(t.samples[frame * t.channels + c])) / 32768.0;
    }
};

const testing = std.testing;

fn ramp(comptime n: usize) [n]i16 {
    var s: [n]i16 = undefined;
    for (&s, 0..) |*v, i| v.* = @intCast(i * 8);
    return s;
}

fn toF32(s: i16) f32 {
    return @as(f32, @floatFromInt(s)) / 32768.0;
}

test "renders silence and holds position while paused" {
    const s = ramp(1024);
    var t: Track = .complete(&s, 1, 44100);
    var e: Engine = .init(1, 44100);
    e.load(&t);
    var out: [64]f32 = @splat(1);
    e.render(&out);
    for (out) |v| try testing.expectEqual(@as(f32, 0), v);
    try testing.expectEqual(@as(usize, 0), e.position.load(.monotonic));
    try testing.expectEqual(&t, e.current.load(.monotonic).?);
}

test "plays forward after the fade-in ramp" {
    const s = ramp(2048);
    var t: Track = .complete(&s, 1, 44100);
    var e: Engine = .init(1, 44100);
    e.load(&t);
    e.play();
    var out: [fade_frames + 16]f32 = undefined;
    e.render(&out);
    try testing.expectEqual(@as(usize, out.len), e.position.load(.monotonic));
    // Fully ramped in: output equals the source sample.
    const last = out.len - 1;
    try testing.expectApproxEqAbs(toF32(s[last]), out[last], 1e-6);
}

test "rewind jumps back and crossfades" {
    const s = ramp(4096);
    var t: Track = .complete(&s, 1, 1000);
    var e: Engine = .init(1, 1000);
    e.load(&t);
    e.play();
    var out: [1024]f32 = undefined;
    e.render(&out);
    e.render(&out);
    try testing.expectEqual(@as(usize, 2048), e.position.load(.monotonic));

    e.rewind(1.5); // 1500 frames at 1 kHz
    try testing.expectEqual(@as(usize, 548), e.currentFrame());
    e.render(out[0..fade_frames]);
    try testing.expectEqual(@as(usize, 548 + fade_frames), e.position.load(.monotonic));
    // Halfway through the crossfade the output mixes both positions.
    const mid = fade_frames / 2;
    try testing.expect(out[mid] < toF32(s[2048 + mid]) and out[mid] > toF32(s[548 + mid]));
    // After the crossfade, output follows the new position exactly.
    e.render(out[0..1]);
    try testing.expectApproxEqAbs(toF32(s[548 + fade_frames]), out[0], 1e-6);
}

test "seek clamps, rewind stops at zero, and the end is reported" {
    const s = ramp(512);
    var t: Track = .complete(&s, 2, 100);
    var e: Engine = .init(2, 100);
    e.load(&t);
    e.seek(10_000);
    try testing.expectEqual(@as(usize, 256), e.currentFrame());
    e.rewind(999);
    try testing.expectEqual(@as(usize, 0), e.currentFrame());

    e.play();
    var out: [600]f32 = undefined;
    e.render(&out);
    try testing.expect(e.isFinished());
    try testing.expectEqual(@as(f32, 0), out[out.len - 1]);
    e.seekSeconds(1);
    try testing.expect(!e.isFinished());
    try testing.expectApproxEqAbs(@as(f64, 2.56), e.durationSeconds(), 1e-9);
}

test "waits for the decoder without skipping ahead" {
    const s = ramp(2048);
    var t: Track = .init(&s, 1, 1000);
    var e: Engine = .init(1, 1000);
    e.load(&t);
    e.play();
    var out: [512]f32 = undefined;

    t.ready.store(fade_frames + 100, .release);
    e.render(&out);
    try testing.expectEqual(@as(usize, fade_frames + 100), e.position.load(.monotonic));
    for (out[fade_frames + 100 ..]) |v| try testing.expectEqual(@as(f32, 0), v);
    try testing.expect(!e.isFinished());

    // Once more is decoded, playback resumes exactly where it stopped.
    t.ready.store(s.len, .release);
    e.render(out[0..1]);
    try testing.expectApproxEqAbs(toF32(s[fade_frames + 100]), out[0], 1e-6);
}

test "continues into the queued track within the same buffer" {
    const a = ramp(600);
    var b: [256]i16 = undefined;
    for (&b, 0..) |*v, i| v.* = @intCast(-1000 - @as(i32, @intCast(i)));
    var ta: Track = .complete(&a, 1, 1000);
    var tb: Track = .complete(&b, 1, 1000);
    var e: Engine = .init(1, 1000);
    e.load(&ta);
    e.enqueue(&tb);
    e.play();

    var out: [800]f32 = undefined;
    e.render(&out);
    // The last frame of A is followed immediately by the first frame of B.
    try testing.expectApproxEqAbs(toF32(a[599]), out[599], 1e-6);
    try testing.expectApproxEqAbs(toF32(b[0]), out[600], 1e-6);
    try testing.expectApproxEqAbs(toF32(b[199]), out[799], 1e-6);
    try testing.expectEqual(&tb, e.current.load(.monotonic).?);
    try testing.expectEqual(@as(usize, 200), e.position.load(.monotonic));
    try testing.expectEqual(@as(?*Track, null), e.queued.load(.monotonic));
    try testing.expect(!e.isFinished());
}

test "load switches tracks and counts renders" {
    const a = ramp(512);
    const b = ramp(256);
    var ta: Track = .complete(&a, 1, 1000);
    var tb: Track = .complete(&b, 1, 1000);
    var e: Engine = .init(1, 1000);
    e.load(&ta);
    e.play();
    var out: [300]f32 = undefined;
    e.render(&out);

    e.load(&tb);
    try testing.expectEqual(&tb, e.currentTrack().?);
    try testing.expectEqual(@as(usize, 0), e.currentFrame());
    e.render(out[0..10]);
    try testing.expectEqual(&tb, e.current.load(.monotonic).?);
    try testing.expectEqual(@as(usize, 10), e.position.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), e.renderCount());
}

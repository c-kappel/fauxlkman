//! Real-time playback of a song that has been fully decoded into memory.
//!
//! The whole song lives in RAM as interleaved 16-bit PCM, so seeking and
//! rewinding are just a change of read position: no decoder state has to be
//! rebuilt. `render` is called from the audio device's real-time thread and
//! never allocates or locks; the control functions (`seek`, `rewind`, ...) may
//! be called from any other thread and communicate through atomics.
//!
//! To avoid clicks, seeks crossfade from the old position to the new one and
//! pause/resume ramp the gain, both over `fade_frames`.

const std = @import("std");

const Atomic = std.atomic.Value;

/// Length of the seek crossfade and pause/resume ramp (~5 ms at 44.1 kHz).
pub const fade_frames = 256;

const no_seek = std.math.maxInt(usize);

pub const Engine = struct {
    /// Interleaved PCM, `channels` samples per frame.
    samples: []const i16,
    channels: u8,
    sample_rate: u32,

    /// Next frame to play. Written only by the render thread.
    position: Atomic(usize) = .init(0),
    /// Frame to jump to on the next render call, or `no_seek`.
    pending_seek: Atomic(usize) = .init(no_seek),
    playing: Atomic(bool) = .init(false),
    /// Set by the render thread once the last frame has been played.
    finished: Atomic(bool) = .init(false),

    // Render-thread state.
    gain: f32 = 0,
    fade_from: usize = 0,
    fade_left: usize = 0,

    pub fn init(samples: []const i16, channels: u8, sample_rate: u32) Engine {
        std.debug.assert(channels > 0 and samples.len % channels == 0);
        return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
    }

    pub fn totalFrames(self: *const Engine) usize {
        return self.samples.len / self.channels;
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

    /// Current position in frames, including a seek that has been requested
    /// but not yet picked up by the render thread.
    pub fn currentFrame(self: *const Engine) usize {
        const pending = self.pending_seek.load(.acquire);
        return if (pending != no_seek) pending else self.position.load(.acquire);
    }

    /// Jumps to `frame`, clamped to the end of the song.
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

    fn secondsToFrames(self: *const Engine, seconds: f64) usize {
        return @intFromFloat(seconds * @as(f64, @floatFromInt(self.sample_rate)));
    }

    fn framesToSeconds(self: *const Engine, frames: usize) f64 {
        return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Fills `out` with interleaved f32 samples (`channels` per frame).
    /// Real-time safe: called from the audio thread.
    pub fn render(self: *Engine, out: []f32) void {
        const ch = self.channels;
        const frames = out.len / ch;
        const total = self.totalFrames();
        var pos = self.position.load(.monotonic);

        const target = self.pending_seek.swap(no_seek, .acq_rel);
        if (target != no_seek and target != pos) {
            // Only crossfade if something audible is playing.
            self.fade_left = if (self.gain > 0 and pos < total) fade_frames else 0;
            self.fade_from = pos;
            pos = target;
        }

        const want: f32 = if (self.playing.load(.acquire)) 1 else 0;
        const step: f32 = 1.0 / @as(f32, fade_frames);

        for (0..frames) |i| {
            const frame = out[i * ch ..][0..ch];
            if (self.gain == 0 and want == 0) {
                @memset(out[i * ch ..], 0);
                break;
            }
            if (self.gain < want) self.gain = @min(want, self.gain + step) else if (self.gain > want) self.gain = @max(want, self.gain - step);

            const fade: f32 = if (self.fade_left > 0) @as(f32, @floatFromInt(self.fade_left)) / fade_frames else 0;
            for (frame, 0..) |*s, c| {
                var v = self.sampleAt(pos, c) * (1 - fade);
                if (fade > 0) v += self.sampleAt(self.fade_from, c) * fade;
                s.* = v * self.gain;
            }
            if (self.fade_left > 0) {
                self.fade_left -= 1;
                self.fade_from += 1;
            }
            if (pos < total) pos += 1;
        }

        self.position.store(pos, .release);
        if (pos >= total and self.fade_left == 0) self.finished.store(true, .release);
    }

    fn sampleAt(self: *const Engine, frame: usize, c: usize) f32 {
        if (frame >= self.totalFrames()) return 0;
        return @as(f32, @floatFromInt(self.samples[frame * self.channels + c])) / 32768.0;
    }
};

const testing = std.testing;

fn ramp(comptime n: usize) [n]i16 {
    var s: [n]i16 = undefined;
    for (&s, 0..) |*v, i| v.* = @intCast(i * 8);
    return s;
}

test "renders silence and holds position while paused" {
    const s = ramp(1024);
    var e: Engine = .init(&s, 1, 44100);
    var out: [64]f32 = @splat(1);
    e.render(&out);
    for (out) |v| try testing.expectEqual(@as(f32, 0), v);
    try testing.expectEqual(@as(usize, 0), e.position.load(.monotonic));
}

test "plays forward after the fade-in ramp" {
    const s = ramp(2048);
    var e: Engine = .init(&s, 1, 44100);
    e.play();
    var out: [fade_frames + 16]f32 = undefined;
    e.render(&out);
    try testing.expectEqual(@as(usize, out.len), e.position.load(.monotonic));
    // Fully ramped in: output equals the source sample.
    const last = out.len - 1;
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(s[last])) / 32768.0, out[last], 1e-6);
}

test "rewind jumps back and crossfades" {
    const s = ramp(4096);
    var e: Engine = .init(&s, 1, 1000);
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
    const old: f32 = @as(f32, @floatFromInt(s[2048 + mid])) / 32768.0;
    const new: f32 = @as(f32, @floatFromInt(s[548 + mid])) / 32768.0;
    try testing.expect(out[mid] < old and out[mid] > new);
    // After the crossfade, output follows the new position exactly.
    e.render(out[0..1]);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(s[548 + fade_frames])) / 32768.0, out[0], 1e-6);
}

test "seek clamps, rewind stops at zero, and the end is reported" {
    const s = ramp(512);
    var e: Engine = .init(&s, 2, 100);
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

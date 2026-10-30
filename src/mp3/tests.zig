//! End-to-end encoder/decoder tests.

const std = @import("std");
const mp3 = @import("mp3.zig");

fn makeSignal(gpa: std.mem.Allocator, frames: usize, channels: u8, rate: u32) ![]i16 {
    const s = try gpa.alloc(i16, frames * channels);
    const fr: f32 = @floatFromInt(rate);
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / fr;
        const l = 0.4 * @sin(2 * std.math.pi * 440 * t) + 0.2 * @sin(2 * std.math.pi * 3000 * t);
        const r = 0.3 * @sin(2 * std.math.pi * 660 * t) + 0.1 * @sin(2 * std.math.pi * 5000 * t);
        s[i * channels] = @intFromFloat(l * 32767);
        if (channels == 2) s[i * channels + 1] = @intFromFloat(r * 32767);
    }
    return s;
}

/// Finds the delay that best aligns `decoded` with `original` (channel 0) and
/// returns the signal-to-noise ratio in dB at that alignment.
fn alignedSnr(original: []const i16, decoded: []const i16, channels: u8) f64 {
    const n = original.len / channels;
    const m = decoded.len / channels;
    var best_snr: f64 = -std.math.inf(f64);
    for (0..2400) |delay| {
        if (delay + n > m) break;
        var sig: f64 = 0;
        var noise: f64 = 0;
        // Skip the start/end so filter ramp-up does not dominate.
        for (2048..n - 2048) |i| for (0..channels) |c| {
            const a: f64 = @floatFromInt(original[i * channels + c]);
            const b: f64 = @floatFromInt(decoded[(i + delay) * channels + c]);
            sig += a * a;
            noise += (a - b) * (a - b);
        };
        const snr = 10 * std.math.log10(sig / @max(noise, 1e-9));
        best_snr = @max(best_snr, snr);
    }
    return best_snr;
}

fn roundTrip(channels: u8, rate: u32, opts: mp3.EncodeOptions) !f64 {
    const gpa = std.testing.allocator;
    const frames = rate / 2;
    const input = try makeSignal(gpa, frames, channels, rate);
    defer gpa.free(input);
    const encoded = try mp3.encode(gpa, input, channels, rate, opts);
    defer gpa.free(encoded);
    const pcm = try mp3.decode(gpa, encoded);
    defer pcm.deinit(gpa);
    try std.testing.expectEqual(channels, pcm.channels);
    try std.testing.expectEqual(rate, pcm.sample_rate);
    try std.testing.expect(pcm.framesPerChannel() >= frames);
    return alignedSnr(input, pcm.samples, channels);
}

test "stereo round trip at 128 kbit/s" {
    const snr = try roundTrip(2, 44100, .{ .bitrate_kbps = 128 });
    try std.testing.expect(snr > 25);
}

test "independent stereo round trip" {
    const snr = try roundTrip(2, 48000, .{ .bitrate_kbps = 192, .stereo_mode = .stereo });
    try std.testing.expect(snr > 25);
}

test "mono round trip at 64 kbit/s" {
    const snr = try roundTrip(1, 32000, .{ .bitrate_kbps = 64 });
    try std.testing.expect(snr > 20);
}

test "decoder survives garbage" {
    const gpa = std.testing.allocator;
    var junk: [8192]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(1234);
    prng.random().bytes(&junk);
    // Plant plausible-looking headers among the junk.
    var i: usize = 0;
    while (i + 4 < junk.len) : (i += 417) @memcpy(junk[i..][0..4], &[_]u8{ 0xff, 0xfb, 0x90, 0x60 });
    if (mp3.decode(gpa, &junk)) |pcm| pcm.deinit(gpa) else |_| {}
}

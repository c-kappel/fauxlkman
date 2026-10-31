//! MP3 (MPEG audio Layer III) decoding and encoding.
//!
//! Decoding supports MPEG-1, MPEG-2 and MPEG-2.5 Layer III streams, including
//! the bit reservoir, all block types, mid/side stereo and MPEG-1 intensity
//! stereo, with gapless trimming when a LAME/Info tag is present.
//!
//! Encoding produces MPEG-1 Layer III CBR streams (32, 44.1, 48 kHz) from
//! 16-bit PCM. See `encoder.zig` for its (intentionally simple) design.

const std = @import("std");

pub const frame = @import("frame.zig");
pub const stream = @import("stream.zig");
pub const wav = @import("wav.zig");
pub const Decoder = @import("decoder.zig").Decoder;
pub const Encoder = @import("encoder.zig").Encoder;
pub const EncodeOptions = @import("encoder.zig").Options;
pub const StereoMode = @import("encoder.zig").StereoMode;
pub const Pcm = wav.Pcm;
pub const encode = @import("encoder.zig").encode;

const decoder_delay = 529;

pub const DecodeError = error{NoAudio} || std.mem.Allocator.Error;

/// Decodes a complete MP3 file into interleaved 16-bit PCM.
pub fn decode(gpa: std.mem.Allocator, data: []const u8) DecodeError!Pcm {
    const layout = try scan(data);
    const samples = try gpa.alloc(i16, layout.frames * layout.channels);
    var decoded: std.atomic.Value(usize) = .init(0);
    decodeInto(data, layout, samples, &decoded, null);
    return .{ .samples = samples, .channels = layout.channels, .sample_rate = layout.sample_rate };
}

/// The shape of a stream's decoded PCM, known before decoding it.
pub const Layout = struct {
    channels: u8,
    sample_rate: u32,
    /// Frames (samples per channel) after gapless trimming.
    frames: usize,
    /// Leading decoded frames dropped by gapless trimming.
    skip: usize,
};

/// Walks the frame headers (without decoding) to find the format and exact
/// length of the decoded audio, so a buffer can be allocated up front.
pub fn scan(data: []const u8) DecodeError!Layout {
    var it: stream.FrameIterator = .init(data);
    var gapless: ?stream.Gapless = null;
    var format: ?struct { channels: u8, sample_rate: u32 } = null;
    var total: usize = 0;
    var first = true;

    while (it.next()) |f| {
        if (first) {
            first = false;
            if (stream.parseInfoTag(f)) |tag| {
                gapless = tag.gapless;
                continue;
            }
        }
        const h = f.header;
        if (format) |fmt| {
            // Mid-stream format changes are not supported; skip such frames.
            if (fmt.channels != h.channels() or fmt.sample_rate != h.sampleRate()) continue;
        } else {
            format = .{ .channels = h.channels(), .sample_rate = h.sampleRate() };
        }
        total += h.samplesPerFrame();
    }

    const fmt = format orelse return error.NoAudio;
    var layout: Layout = .{ .channels = fmt.channels, .sample_rate = fmt.sample_rate, .frames = total, .skip = 0 };
    if (gapless) |g| {
        layout.skip = @min(total, g.delay + decoder_delay);
        layout.frames = @min(total - layout.skip, (total -| g.delay) -| g.padding);
    }
    return layout;
}

/// Decodes `data` into `out` (`layout.frames * layout.channels` samples, as
/// returned by `scan`). After each MP3 frame, the number of output frames
/// written so far is stored to `decoded` with release ordering, so another
/// thread can play the beginning while the rest is still being decoded.
/// Frames that fail to decode become silence. Stops early, leaving the rest
/// of `out` unwritten, if `cancel` becomes true.
pub fn decodeInto(
    data: []const u8,
    layout: Layout,
    out: []i16,
    decoded: *std.atomic.Value(usize),
    cancel: ?*const std.atomic.Value(bool),
) void {
    const ch = layout.channels;
    std.debug.assert(out.len == layout.frames * ch);

    var dec: Decoder = .{};
    var buf: [@import("decoder.zig").max_samples_per_frame * 2]i16 = undefined;
    var it: stream.FrameIterator = .init(data);
    var first = true;
    // Position in the untrimmed decoded stream, and frames written to `out`.
    var stream_pos: usize = 0;
    var written: usize = 0;

    while (it.next()) |f| {
        if (written >= layout.frames) break;
        if (cancel) |c| if (c.load(.monotonic)) return;
        if (first) {
            first = false;
            if (stream.parseInfoTag(f) != null) continue;
        }
        const h = f.header;
        if (h.channels() != ch or h.sampleRate() != layout.sample_rate) continue;
        const n = h.samplesPerFrame();
        const pcm = buf[0 .. n * ch];
        if (dec.decodeFrame(f.bytes, &buf)) |_| {} else |_| @memset(pcm, 0);

        // Copy the part of this frame that falls inside the trimmed range.
        const from = @max(stream_pos, layout.skip + written) - stream_pos;
        stream_pos += n;
        if (from >= n) continue;
        const count = @min(n - from, layout.frames - written);
        @memcpy(out[written * ch ..][0 .. count * ch], pcm[from * ch ..][0 .. count * ch]);
        written += count;
        decoded.store(written, .release);
    }
    // Pad if the stream ended short of what `scan` promised (e.g. a truncated file).
    @memset(out[written * ch ..], 0);
    decoded.store(layout.frames, .release);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("bits.zig");
    _ = @import("tables.zig");
    _ = @import("filterbank.zig");
    _ = @import("decoder.zig");
    _ = @import("encoder.zig");
    _ = @import("tests.zig");
}

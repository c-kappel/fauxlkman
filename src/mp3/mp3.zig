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
    const dec = try gpa.create(Decoder);
    defer gpa.destroy(dec);
    dec.* = .{};

    var samples: std.ArrayList(i16) = .empty;
    errdefer samples.deinit(gpa);

    var it: stream.FrameIterator = .init(data);
    var gapless: ?stream.Gapless = null;
    var format: ?struct { channels: u8, sample_rate: u32 } = null;
    var first = true;
    var buf: [@import("decoder.zig").max_samples_per_frame * 2]i16 = undefined;

    while (it.next()) |f| {
        if (first) {
            first = false;
            if (stream.parseInfoTag(f)) |tag| {
                gapless = tag.gapless;
                continue;
            }
        }
        const info = dec.decodeFrame(f.bytes, &buf) catch continue;
        if (format) |fmt| {
            // Mid-stream format changes are not supported; skip such frames.
            if (fmt.channels != info.channels or fmt.sample_rate != info.sample_rate) continue;
        } else {
            format = .{ .channels = info.channels, .sample_rate = info.sample_rate };
        }
        try samples.appendSlice(gpa, buf[0 .. info.samples * info.channels]);
    }

    const fmt = format orelse return error.NoAudio;
    var pcm_slice = try samples.toOwnedSlice(gpa);

    if (gapless) |g| {
        const total = pcm_slice.len / fmt.channels;
        const skip = @min(total, g.delay + decoder_delay);
        const keep = @min(total - skip, (total -| g.delay) -| g.padding);
        std.mem.copyForwards(i16, pcm_slice, pcm_slice[skip * fmt.channels ..][0 .. keep * fmt.channels]);
        pcm_slice = try gpa.realloc(pcm_slice, keep * fmt.channels);
    }
    return .{ .samples = pcm_slice, .channels = fmt.channels, .sample_rate = fmt.sample_rate };
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

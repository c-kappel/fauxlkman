//! Frame-level parsing of MP3 files: ID3v2 skipping, frame sync, and the
//! Xing/Info + LAME tag used for gapless playback.

const std = @import("std");
const frame = @import("frame.zig");

const Header = frame.Header;

/// Returns the number of bytes occupied by a leading ID3v2 tag (0 if none).
pub fn id3v2Size(data: []const u8) usize {
    if (data.len < 10 or !std.mem.eql(u8, data[0..3], "ID3")) return 0;
    var size: usize = 0;
    for (data[6..10]) |b| size = (size << 7) | (b & 0x7f);
    const footer: usize = if (data[5] & 0x10 != 0) 10 else 0;
    return @min(data.len, 10 + size + footer);
}

pub const Frame = struct {
    header: Header,
    bytes: []const u8,
    offset: usize,
};

/// Iterates over the Layer III frames in a buffer, resynchronizing over junk.
pub const FrameIterator = struct {
    data: []const u8,
    pos: usize,
    locked: ?Header = null,

    pub fn init(data: []const u8) FrameIterator {
        return .{ .data = data, .pos = id3v2Size(data) };
    }

    pub fn next(self: *FrameIterator) ?Frame {
        while (self.pos + Header.size <= self.data.len) : (self.pos += 1) {
            const hdr = Header.parse(self.data[self.pos..]) orelse continue;
            const size = hdr.frameSize();
            if (self.pos + size > self.data.len) return null;
            if (self.locked) |ref| {
                if (hdr.version != ref.version or hdr.sample_rate_index != ref.sample_rate_index) continue;
            } else if (self.pos + size + Header.size <= self.data.len) {
                // Before locking on, require that the next frame also syncs to
                // avoid false positives inside junk data.
                const nxt = Header.parse(self.data[self.pos + size ..]) orelse continue;
                if (nxt.version != hdr.version or nxt.sample_rate_index != hdr.sample_rate_index) continue;
            }
            self.locked = hdr;
            const f: Frame = .{ .header = hdr, .bytes = self.data[self.pos..][0..size], .offset = self.pos };
            self.pos += size;
            return f;
        }
        return null;
    }
};

pub const Gapless = struct {
    /// Encoder delay in samples (before the decoder's own 529-sample delay).
    delay: u32,
    /// Padding samples appended by the encoder at the end.
    padding: u32,
};

pub const InfoTag = struct {
    frames: ?u32 = null,
    gapless: ?Gapless = null,
};

/// Detects a Xing/Info or VBRI header in a frame. Such frames carry metadata
/// instead of audio and must not be played.
pub fn parseInfoTag(f: Frame) ?InfoTag {
    const b = f.bytes;
    const xing = f.header.mainDataOffset() - @as(usize, if (f.header.has_crc) 2 else 0);
    if (b.len >= 4 + 32 + 4 and std.mem.eql(u8, b[36..40], "VBRI")) return .{};
    if (b.len < xing + 8) return null;
    const tag = b[xing..][0..4];
    if (!std.mem.eql(u8, tag, "Xing") and !std.mem.eql(u8, tag, "Info")) return null;

    var info: InfoTag = .{};
    const flags = std.mem.readInt(u32, b[xing + 4 ..][0..4], .big);
    var p = xing + 8;
    if (flags & 1 != 0) {
        if (b.len >= p + 4) info.frames = std.mem.readInt(u32, b[p..][0..4], .big);
        p += 4;
    }
    if (flags & 2 != 0) p += 4;
    if (flags & 4 != 0) p += 100;
    if (flags & 8 != 0) p += 4;
    // LAME extension: 9-byte encoder string, then delay/padding at offset 21.
    if (b.len >= p + 24) {
        const enc = b[p..][0..4];
        if (std.mem.eql(u8, enc, "LAME") or std.mem.eql(u8, enc, "Lavf") or std.mem.eql(u8, enc, "Lavc")) {
            const d = b[p + 21 ..][0..3];
            info.gapless = .{
                .delay = (@as(u32, d[0]) << 4) | (d[1] >> 4),
                .padding = (@as(u32, d[1] & 0x0f) << 8) | d[2],
            };
        }
    }
    return info;
}

test "id3v2 size" {
    const tag = [_]u8{ 'I', 'D', '3', 4, 0, 0, 0, 0, 1, 0 } ++ @as([128]u8, @splat(0));
    try std.testing.expectEqual(@as(usize, 138), id3v2Size(&tag));
    try std.testing.expectEqual(@as(usize, 0), id3v2Size("not a tag at all"));
}

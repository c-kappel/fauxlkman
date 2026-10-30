//! MPEG audio Layer III frame header parsing and derived frame geometry.

const std = @import("std");

pub const Version = enum(u2) {
    mpeg25 = 0,
    mpeg2 = 2,
    mpeg1 = 3,
};

pub const Mode = enum(u2) {
    stereo = 0,
    joint_stereo = 1,
    dual_channel = 2,
    mono = 3,
};

/// Bitrates in kbit/s indexed by the header's bitrate_index.
const bitrates_mpeg1 = [15]u16{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 };
const bitrates_mpeg2 = [15]u16{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 };

const sample_rates = [3][3]u32{
    .{ 44100, 48000, 32000 }, // MPEG-1
    .{ 22050, 24000, 16000 }, // MPEG-2
    .{ 11025, 12000, 8000 }, // MPEG-2.5
};

/// Mode extension bits for joint stereo.
pub const mode_ext_intensity: u2 = 0b01;
pub const mode_ext_ms: u2 = 0b10;

pub const Header = struct {
    version: Version,
    has_crc: bool,
    bitrate_index: u4,
    sample_rate_index: u2,
    padding: bool,
    mode: Mode,
    mode_extension: u2,

    pub const size = 4;

    /// Parses a Layer III frame header. Returns null for anything that is not a
    /// valid, supported header (other layers, free format, reserved values).
    pub fn parse(b: []const u8) ?Header {
        if (b.len < 4) return null;
        if (b[0] != 0xff or (b[1] & 0xe0) != 0xe0) return null;
        const version: u2 = @truncate(b[1] >> 3);
        if (version == 1) return null;
        const layer: u2 = @truncate(b[1] >> 1);
        if (layer != 1) return null;
        const bitrate_index: u4 = @truncate(b[2] >> 4);
        if (bitrate_index == 0 or bitrate_index == 15) return null;
        const sample_rate_index: u2 = @truncate(b[2] >> 2);
        if (sample_rate_index == 3) return null;
        return .{
            .version = @enumFromInt(version),
            .has_crc = (b[1] & 1) == 0,
            .bitrate_index = bitrate_index,
            .sample_rate_index = sample_rate_index,
            .padding = (b[2] >> 1) & 1 == 1,
            .mode = @enumFromInt(@as(u2, @truncate(b[3] >> 6))),
            .mode_extension = @truncate(b[3] >> 4),
        };
    }

    pub fn encode(self: Header) [4]u8 {
        return .{
            0xff,
            0xe0 | (@as(u8, @intFromEnum(self.version)) << 3) | (1 << 1) | @intFromBool(!self.has_crc),
            (@as(u8, self.bitrate_index) << 4) | (@as(u8, self.sample_rate_index) << 2) | (@as(u8, @intFromBool(self.padding)) << 1),
            (@as(u8, @intFromEnum(self.mode)) << 6) | (@as(u8, self.mode_extension) << 4),
        };
    }

    pub fn isMpeg1(self: Header) bool {
        return self.version == .mpeg1;
    }

    fn versionRow(self: Header) usize {
        return switch (self.version) {
            .mpeg1 => 0,
            .mpeg2 => 1,
            .mpeg25 => 2,
        };
    }

    pub fn bitrateKbps(self: Header) u32 {
        return if (self.isMpeg1()) bitrates_mpeg1[self.bitrate_index] else bitrates_mpeg2[self.bitrate_index];
    }

    pub fn sampleRate(self: Header) u32 {
        return sample_rates[self.versionRow()][self.sample_rate_index];
    }

    /// Index 0..8 into the per-sample-rate scalefactor band tables.
    pub fn sfbIndex(self: Header) usize {
        return self.versionRow() * 3 + self.sample_rate_index;
    }

    pub fn channels(self: Header) u8 {
        return if (self.mode == .mono) 1 else 2;
    }

    pub fn granules(self: Header) u8 {
        return if (self.isMpeg1()) 2 else 1;
    }

    pub fn samplesPerFrame(self: Header) usize {
        return @as(usize, self.granules()) * 576;
    }

    /// Total frame length in bytes, including the header.
    pub fn frameSize(self: Header) usize {
        const coeff: u32 = if (self.isMpeg1()) 144000 else 72000;
        return coeff * self.bitrateKbps() / self.sampleRate() + @intFromBool(self.padding);
    }

    pub fn sideInfoSize(self: Header) usize {
        if (self.isMpeg1()) return if (self.mode == .mono) 17 else 32;
        return if (self.mode == .mono) 9 else 17;
    }

    /// Byte offset of the main data within the frame.
    pub fn mainDataOffset(self: Header) usize {
        return size + @as(usize, if (self.has_crc) 2 else 0) + self.sideInfoSize();
    }
};

/// Finds the sample rate / bitrate indices for MPEG-1 encoding.
pub fn mpeg1SampleRateIndex(rate: u32) ?u2 {
    for (sample_rates[0], 0..) |r, i| if (r == rate) return @intCast(i);
    return null;
}

pub fn mpeg1BitrateIndex(kbps: u32) ?u4 {
    for (bitrates_mpeg1[1..], 1..) |b, i| if (b == kbps) return @intCast(i);
    return null;
}

test "parse and encode header" {
    // 128 kbit/s, 44.1 kHz, joint stereo, no CRC.
    const bytes = [4]u8{ 0xff, 0xfb, 0x90, 0x60 };
    const h = Header.parse(&bytes).?;
    try std.testing.expectEqual(Version.mpeg1, h.version);
    try std.testing.expectEqual(@as(u32, 128), h.bitrateKbps());
    try std.testing.expectEqual(@as(u32, 44100), h.sampleRate());
    try std.testing.expectEqual(Mode.joint_stereo, h.mode);
    try std.testing.expectEqual(@as(usize, 417), h.frameSize());
    try std.testing.expectEqual(@as(usize, 32), h.sideInfoSize());
    try std.testing.expectEqualSlices(u8, &bytes, &h.encode());
}

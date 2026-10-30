//! Minimal RIFF/WAVE reader and writer for 16-bit PCM.

const std = @import("std");

pub const Error = error{ NotWav, UnsupportedFormat, Truncated } || std.mem.Allocator.Error;

pub const Pcm = struct {
    /// Interleaved samples.
    samples: []i16,
    channels: u8,
    sample_rate: u32,

    pub fn deinit(self: Pcm, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
    }

    pub fn framesPerChannel(self: Pcm) usize {
        return self.samples.len / self.channels;
    }
};

pub fn read(gpa: std.mem.Allocator, data: []const u8) Error!Pcm {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE"))
        return error.NotWav;

    var channels: ?u16 = null;
    var sample_rate: u32 = 0;
    var pos: usize = 12;
    while (pos + 8 <= data.len) {
        const id = data[pos..][0..4];
        const len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        const body = data[body_start..@min(data.len, body_start + len)];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.Truncated;
            const format = std.mem.readInt(u16, body[0..2], .little);
            const bits = std.mem.readInt(u16, body[14..16], .little);
            // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE (assumed PCM).
            if ((format != 1 and format != 0xfffe) or bits != 16) return error.UnsupportedFormat;
            channels = std.mem.readInt(u16, body[2..4], .little);
            sample_rate = std.mem.readInt(u32, body[4..8], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            const ch = channels orelse return error.UnsupportedFormat;
            if (ch == 0 or ch > 2) return error.UnsupportedFormat;
            const count = body.len / 2 / ch * ch;
            const samples = try gpa.alloc(i16, count);
            for (samples, 0..) |*s, i| s.* = std.mem.readInt(i16, body[i * 2 ..][0..2], .little);
            return .{ .samples = samples, .channels = @intCast(ch), .sample_rate = sample_rate };
        }
        pos = body_start + len + (len & 1);
    }
    return error.Truncated;
}

pub fn write(gpa: std.mem.Allocator, pcm: Pcm) std.mem.Allocator.Error![]u8 {
    const data_len: u32 = @intCast(pcm.samples.len * 2);
    const out = try gpa.alloc(u8, 44 + data_len);
    const block_align: u16 = @as(u16, pcm.channels) * 2;
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], pcm.channels, .little);
    std.mem.writeInt(u32, out[24..28], pcm.sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], pcm.sample_rate * block_align, .little);
    std.mem.writeInt(u16, out[32..34], block_align, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    for (pcm.samples, 0..) |s, i| std.mem.writeInt(i16, out[44 + i * 2 ..][0..2], s, .little);
    return out;
}

test "wav round trip" {
    const gpa = std.testing.allocator;
    var samples = [_]i16{ 0, 1, -1, 32767, -32768, 1234 };
    const bytes = try write(gpa, .{ .samples = &samples, .channels = 2, .sample_rate = 44100 });
    defer gpa.free(bytes);
    const pcm = try read(gpa, bytes);
    defer pcm.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), pcm.channels);
    try std.testing.expectEqual(@as(u32, 44100), pcm.sample_rate);
    try std.testing.expectEqualSlices(i16, &samples, pcm.samples);
}

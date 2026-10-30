//! MPEG-1 Layer III CBR encoder.
//!
//! Deliberately simple: long blocks only, no scalefactors and no
//! psychoacoustic model. Each frame searches for a single quantizer step size
//! shared by all granules and channels, which spreads quantization noise
//! evenly (minimum mean-squared error for the given bit budget). Stereo input
//! is coded as mid/side by default.

const std = @import("std");
const BitWriter = @import("bits.zig").BitWriter;
const frame = @import("frame.zig");
const tables = @import("tables.zig");
const filterbank = @import("filterbank.zig");

const Header = frame.Header;

pub const samples_per_frame = 1152;
/// 320 kbit/s at 32 kHz with padding.
pub const max_frame_size = 1441;

pub const StereoMode = enum {
    /// Mid/side joint stereo.
    joint,
    /// Independent left/right channels.
    stereo,
};

pub const Options = struct {
    bitrate_kbps: u32 = 128,
    stereo_mode: StereoMode = .joint,
};

pub const Error = error{ UnsupportedSampleRate, UnsupportedBitrate, UnsupportedChannels };

/// Largest value representable by the Huffman tables (15 + 13 linbits).
const max_quant = 15 + 8191;

/// Region split (region0_count, region1_count) by the number of scalefactor
/// bands covered by the big-values region.
const region_split = [23][2]u8{
    .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 1 },
    .{ 1, 2 }, .{ 2, 2 }, .{ 2, 3 }, .{ 2, 3 }, .{ 3, 4 }, .{ 3, 4 }, .{ 3, 4 }, .{ 4, 5 },
    .{ 4, 5 }, .{ 4, 6 }, .{ 5, 6 }, .{ 5, 6 }, .{ 5, 7 }, .{ 6, 7 }, .{ 6, 7 },
};

/// Quantized spectrum of one granule/channel plus its Huffman coding layout.
const Granule = struct {
    ix: [576]u16 = undefined,
    big_end: usize = 0,
    count1_end: usize = 0,
    region1: usize = 0,
    region2: usize = 0,
    region0_count: u8 = 0,
    region1_count: u8 = 0,
    table_select: [3]u5 = @splat(0),
    count1_table: u1 = 0,
    bits: u32 = 0,
};

pub const Encoder = struct {
    header: Header,
    channels: u8,
    mid_side: bool,
    /// Spectral lines at or above this index are discarded (lowpass).
    cutoff_line: usize,
    analysis: [2]filterbank.Analysis = .{ .{}, .{} },
    /// Previous granule's subband samples, laid out as [subband * 18 + t].
    prev_subband: [2][576]f32 = @splat(@splat(0)),
    /// Accumulates the fractional bytes per frame to decide padding.
    pad_remainder: u32 = 0,

    pub fn init(sample_rate: u32, channels: u8, options: Options) Error!Encoder {
        const sr_index = frame.mpeg1SampleRateIndex(sample_rate) orelse return error.UnsupportedSampleRate;
        const br_index = frame.mpeg1BitrateIndex(options.bitrate_kbps) orelse return error.UnsupportedBitrate;
        if (channels != 1 and channels != 2) return error.UnsupportedChannels;
        const mid_side = channels == 2 and options.stereo_mode == .joint;
        const mode: frame.Mode = if (channels == 1) .mono else if (mid_side) .joint_stereo else .stereo;

        const cutoff_hz = lowpassHz(options.bitrate_kbps, channels, mid_side);
        const nyquist: f32 = @floatFromInt(sample_rate / 2);
        const line: usize = @intFromFloat(@min(1.0, cutoff_hz / nyquist) * 576.0);

        return .{
            .header = .{
                .version = .mpeg1,
                .has_crc = false,
                .bitrate_index = br_index,
                .sample_rate_index = sr_index,
                .padding = false,
                .mode = mode,
                .mode_extension = if (mid_side) frame.mode_ext_ms else 0,
            },
            .channels = channels,
            .mid_side = mid_side,
            .cutoff_line = line,
        };
    }

    /// Encodes 1152 samples per channel (interleaved) into one frame and
    /// returns its length. `out` must hold at least `max_frame_size` bytes.
    pub fn encodeFrame(self: *Encoder, pcm: []const i16, out: []u8) usize {
        const nch: usize = self.channels;
        std.debug.assert(pcm.len >= samples_per_frame * nch);

        var hdr = self.header;
        const rate = hdr.sampleRate();
        const numerator = 144000 * hdr.bitrateKbps();
        self.pad_remainder += numerator % rate;
        hdr.padding = self.pad_remainder >= rate;
        if (hdr.padding) self.pad_remainder -= rate;
        const size = hdr.frameSize();

        var xr: [2][2][576]f32 = undefined;
        for (0..2) |gr| {
            for (0..nch) |ch| self.transform(pcm[gr * 576 * nch ..], ch, &xr[gr][ch]);
            if (self.mid_side) {
                for (&xr[gr][0], &xr[gr][1]) |*l, *r| {
                    const m = (l.* + r.*) * std.math.sqrt1_2;
                    const s = (l.* - r.*) * std.math.sqrt1_2;
                    l.* = m;
                    r.* = s;
                }
            }
        }

        var granules: [2][2]Granule = undefined;
        const main_bits: u32 = @intCast((size - Header.size - hdr.sideInfoSize()) * 8);
        const gain = quantizeFrame(&xr, nch, &tables.sfb_long[hdr.sfbIndex()], main_bits, &granules);

        @memset(out[0..size], 0);
        out[0..4].* = hdr.encode();
        var side: BitWriter = .init(out[Header.size .. Header.size + hdr.sideInfoSize()]);
        side.writeBits(0, 9); // main_data_begin: no bit reservoir
        side.writeBits(0, if (nch == 1) 5 else 3); // private bits
        side.writeBits(0, @intCast(4 * nch)); // scfsi
        for (0..2) |gr| for (0..nch) |ch| {
            const g = &granules[gr][ch];
            side.writeBits(g.bits, 12);
            side.writeBits(@intCast(g.big_end / 2), 9);
            side.writeBits(gain, 8);
            side.writeBits(0, 4); // scalefac_compress
            side.writeFlag(false); // window_switching
            for (g.table_select) |t| side.writeBits(t, 5);
            side.writeBits(g.region0_count, 4);
            side.writeBits(g.region1_count, 3);
            side.writeFlag(false); // preflag
            side.writeFlag(false); // scalefac_scale
            side.writeBits(g.count1_table, 1);
        };

        var main: BitWriter = .init(out[Header.size + hdr.sideInfoSize() .. size]);
        for (0..2) |gr| for (0..nch) |ch| {
            const start = main.pos;
            writeGranule(&main, &granules[gr][ch], &xr[gr][ch]);
            std.debug.assert(main.pos - start == granules[gr][ch].bits);
        };
        return size;
    }

    /// Analysis filterbank + MDCT for one granule of one channel.
    fn transform(self: *Encoder, pcm: []const i16, ch: usize, xr: *[576]f32) void {
        const nch: usize = self.channels;
        var cur: [576]f32 = undefined;
        for (0..18) |t| {
            var in: [32]f32 = undefined;
            for (&in, 0..) |*v, k| v.* = @as(f32, @floatFromInt(pcm[(t * 32 + k) * nch + ch])) / 32768.0;
            var sub: [32]f32 = undefined;
            self.analysis[ch].process(&in, &sub);
            for (sub, 0..) |v, sb| {
                // Pre-compensate the decoder's frequency inversion.
                cur[sb * 18 + t] = if (sb & 1 == 1 and t & 1 == 1) -v else v;
            }
        }
        for (0..32) |sb| {
            var buf: [36]f32 = undefined;
            @memcpy(buf[0..18], self.prev_subband[ch][sb * 18 ..][0..18]);
            @memcpy(buf[18..], cur[sb * 18 ..][0..18]);
            filterbank.mdctLong(&buf, xr[sb * 18 ..][0..18]);
        }
        self.prev_subband[ch] = cur;

        // Alias reduction butterflies (inverse of the decoder's).
        for (1..32) |sb| {
            for (0..8) |i| {
                const lo = sb * 18 - 1 - i;
                const hi = sb * 18 + i;
                const a = xr[lo];
                const b = xr[hi];
                xr[lo] = a * tables.antialias_cs[i] + b * tables.antialias_ca[i];
                xr[hi] = b * tables.antialias_cs[i] - a * tables.antialias_ca[i];
            }
        }
        @memset(xr[self.cutoff_line..], 0);
    }
};

fn lowpassHz(kbps: u32, channels: u8, mid_side: bool) f32 {
    const per_channel: u32 = if (channels == 1) kbps else if (mid_side) kbps * 2 / 3 else kbps / 2;
    if (per_channel >= 160) return 20000;
    if (per_channel >= 128) return 19000;
    if (per_channel >= 96) return 17500;
    if (per_channel >= 80) return 16000;
    if (per_channel >= 64) return 14500;
    if (per_channel >= 48) return 11000;
    if (per_channel >= 32) return 8000;
    return 5500;
}

/// Finds the smallest global gain (finest quantization) whose coded size fits
/// the frame, leaving the quantized granules in `out`. Returns the gain.
fn quantizeFrame(xr: *const [2][2][576]f32, nch: usize, sfb_l: *const [23]u16, budget: u32, out: *[2][2]Granule) u8 {
    var xr34: [2][2][576]f32 = undefined;
    for (0..2) |gr| for (0..nch) |ch| {
        for (&xr34[gr][ch], xr[gr][ch]) |*d, v| d.* = std.math.pow(f32, @abs(v), 0.75);
    };

    var lo: u32 = 0;
    var hi: u32 = 255;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (tryGain(&xr34, nch, sfb_l, @intCast(mid), budget, out)) hi = mid else lo = mid + 1;
    }
    _ = tryGain(&xr34, nch, sfb_l, @intCast(lo), budget, out);
    return @intCast(lo);
}

fn tryGain(xr34: *const [2][2][576]f32, nch: usize, sfb_l: *const [23]u16, gain: u8, budget: u32, out: *[2][2]Granule) bool {
    // ix = nint((|xr| / step)^(3/4) - 0.0946) with step = 2^((gain - 210) / 4).
    const inv_step34 = @exp2(-0.1875 * (@as(f32, @floatFromInt(gain)) - 210.0));
    var total: u32 = 0;
    for (0..2) |gr| for (0..nch) |ch| {
        const g = &out[gr][ch];
        for (&g.ix, xr34[gr][ch]) |*q, v| {
            const scaled = v * inv_step34 + 0.4054;
            if (scaled > max_quant) return false;
            q.* = @intFromFloat(scaled);
        }
        layoutGranule(g, sfb_l);
        if (g.bits > 4095) return false;
        total += g.bits;
    };
    return total <= budget;
}

/// Splits the spectrum into big-values / count1 / zero regions, selects the
/// Huffman tables and computes the exact number of bits.
fn layoutGranule(g: *Granule, sfb_l: *const [23]u16) void {
    const ix = &g.ix;
    var n: usize = 576;
    while (n >= 2 and ix[n - 1] == 0 and ix[n - 2] == 0) n -= 2;
    g.count1_end = n;
    while (n >= 4 and ix[n - 1] <= 1 and ix[n - 2] <= 1 and ix[n - 3] <= 1 and ix[n - 4] <= 1) n -= 4;
    g.big_end = n;

    // Count1 region: pick the cheaper of tables A and B.
    var c1_bits: [2]u32 = .{ 0, 0 };
    var i = g.big_end;
    while (i < g.count1_end) : (i += 4) {
        const q = quadIndex(ix[i..][0..4]);
        const signs: u32 = @popCount(q);
        for (0..2) |t| c1_bits[t] += tables.quad_codes[t][q].len + signs;
    }
    g.count1_table = @intFromBool(c1_bits[1] < c1_bits[0]);
    g.bits = c1_bits[g.count1_table];

    var bands: usize = 0;
    while (bands < 22 and sfb_l[bands] < g.big_end) bands += 1;
    g.region0_count = region_split[bands][0];
    g.region1_count = region_split[bands][1];
    g.region1 = @min(sfb_l[g.region0_count + 1], g.big_end);
    g.region2 = @min(sfb_l[g.region0_count + g.region1_count + 2], g.big_end);
    const bounds = [4]usize{ 0, g.region1, g.region2, g.big_end };
    for (0..3) |r| {
        const choice = bestTable(ix[bounds[r]..bounds[r + 1]]);
        g.table_select[r] = choice.table;
        g.bits += choice.bits;
    }
}

fn quadIndex(q: *const [4]u16) u4 {
    return @intCast((q[0] << 3) | (q[1] << 2) | (q[2] << 1) | q[3]);
}

const TableChoice = struct { table: u5, bits: u32 };

fn bestTable(ix: []const u16) TableChoice {
    var max: u16 = 0;
    for (ix) |v| max = @max(max, v);
    if (max == 0) return .{ .table = 0, .bits = 0 };

    var candidates: [3]u5 = undefined;
    var n: usize = 0;
    if (max < 16) {
        const list: []const u5 = switch (max) {
            1 => &.{1},
            2 => &.{ 2, 3 },
            3 => &.{ 5, 6 },
            4, 5 => &.{ 7, 8, 9 },
            6, 7 => &.{ 10, 11, 12 },
            else => &.{ 13, 15 },
        };
        @memcpy(candidates[0..list.len], list);
        n = list.len;
    } else {
        // One candidate from each linbits family: the first that fits.
        for ([2]usize{ 16, 24 }) |first| {
            for (first..first + 8) |t| {
                if (max - 15 < (@as(u32, 1) << tables.huffman[t].linbits)) {
                    candidates[n] = @intCast(t);
                    n += 1;
                    break;
                }
            }
        }
    }

    var best: TableChoice = .{ .table = candidates[0], .bits = std.math.maxInt(u32) };
    for (candidates[0..n]) |t| {
        const bits = regionBits(t, ix);
        if (bits < best.bits) best = .{ .table = t, .bits = bits };
    }
    return best;
}

fn regionBits(table: u5, ix: []const u16) u32 {
    const ht = tables.huffman[table];
    const codes = &tables.pair_codes[tables.pairCodeFamily(table)];
    var bits: u32 = 0;
    var i: usize = 0;
    while (i < ix.len) : (i += 2) {
        var x = ix[i];
        var y = ix[i + 1];
        if (ht.linbits > 0) {
            if (x >= 15) {
                bits += ht.linbits;
                x = 15;
            }
            if (y >= 15) {
                bits += ht.linbits;
                y = 15;
            }
        }
        bits += codes[x << 4 | y].len + @intFromBool(x != 0) + @intFromBool(y != 0);
    }
    return bits;
}

fn writeGranule(w: *BitWriter, g: *const Granule, xr: *const [576]f32) void {
    var i: usize = 0;
    while (i < g.big_end) : (i += 2) {
        const table = g.table_select[if (i < g.region1) 0 else if (i < g.region2) 1 else 2];
        if (table == 0) continue;
        const ht = tables.huffman[table];
        const codes = &tables.pair_codes[tables.pairCodeFamily(table)];
        const x = g.ix[i];
        const y = g.ix[i + 1];
        const xc = if (ht.linbits > 0) @min(x, 15) else x;
        const yc = if (ht.linbits > 0) @min(y, 15) else y;
        const code = codes[xc << 4 | yc];
        w.writeBits(code.code, @intCast(code.len));
        if (ht.linbits > 0 and xc == 15) w.writeBits(x - 15, ht.linbits);
        if (x != 0) w.writeFlag(xr[i] < 0);
        if (ht.linbits > 0 and yc == 15) w.writeBits(y - 15, ht.linbits);
        if (y != 0) w.writeFlag(xr[i + 1] < 0);
    }
    while (i < g.count1_end) : (i += 4) {
        const q = quadIndex(g.ix[i..][0..4]);
        const code = tables.quad_codes[g.count1_table][q];
        w.writeBits(code.code, @intCast(code.len));
        for (0..4) |k| if (g.ix[i + k] != 0) w.writeFlag(xr[i + k] < 0);
    }
}

/// Encodes interleaved 16-bit PCM into a complete MP3 stream.
pub fn encode(gpa: std.mem.Allocator, samples: []const i16, channels: u8, sample_rate: u32, options: Options) (Error || std.mem.Allocator.Error)![]u8 {
    var enc: Encoder = try .init(sample_rate, channels, options);
    const per_channel = samples.len / channels;
    // One extra frame flushes the filterbank and MDCT delay.
    const frames = per_channel / samples_per_frame + 2;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, frames * max_frame_size);

    var pcm: [samples_per_frame * 2]i16 = undefined;
    var buf: [max_frame_size]u8 = undefined;
    const chunk = samples_per_frame * @as(usize, channels);
    for (0..frames) |f| {
        const start = @min(f * chunk, samples.len);
        const end = @min(start + chunk, samples.len);
        @memcpy(pcm[0 .. end - start], samples[start..end]);
        @memset(pcm[end - start .. chunk], 0);
        const n = enc.encodeFrame(pcm[0..chunk], &buf);
        out.appendSliceAssumeCapacity(buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

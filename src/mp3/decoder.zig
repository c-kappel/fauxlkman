//! MPEG-1/2/2.5 Layer III decoder.

const std = @import("std");
const BitReader = @import("bits.zig").BitReader;
const frame = @import("frame.zig");
const tables = @import("tables.zig");
const filterbank = @import("filterbank.zig");

const Header = frame.Header;

pub const max_samples_per_frame = 1152;

/// Largest main_data_begin (9 bits) plus the largest possible frame.
const reservoir_capacity = 4096;
const max_main_data_begin = 511;

const GranuleInfo = struct {
    part2_3_length: u32 = 0,
    big_values: u32 = 0,
    global_gain: u32 = 0,
    scalefac_compress: u32 = 0,
    window_switching: bool = false,
    block_type: u2 = 0,
    mixed_block: bool = false,
    table_select: [3]u5 = @splat(0),
    subblock_gain: [3]u3 = @splat(0),
    region0_count: u32 = 0,
    region1_count: u32 = 0,
    preflag: bool = false,
    scalefac_scale: bool = false,
    count1table_select: u1 = 0,

    fn isShort(self: GranuleInfo) bool {
        return self.window_switching and self.block_type == 2;
    }
};

const SideInfo = struct {
    main_data_begin: u32 = 0,
    scfsi: [2][4]bool = @splat(@splat(false)),
    granules: [2][2]GranuleInfo = @splat(@splat(.{})),
};

const Scalefactors = struct {
    long: [22]u8 = @splat(0),
    short: [13][3]u8 = @splat(@splat(0)),
};

pub const FrameInfo = struct {
    sample_rate: u32,
    channels: u8,
    /// Samples per channel written to the output.
    samples: usize,
};

pub const Error = error{ InvalidFrame, TruncatedFrame, OutputTooSmall };

pub const Decoder = struct {
    reservoir: [reservoir_capacity]u8 = undefined,
    reservoir_len: usize = 0,
    scalefactors: [2]Scalefactors = .{ .{}, .{} },
    overlap: [2][576]f32 = @splat(@splat(0)),
    synthesis: [2]filterbank.Synthesis = .{ .{}, .{} },

    /// Decodes one complete frame (header included) into interleaved 16-bit
    /// PCM. `out` must hold at least `samplesPerFrame * channels` samples.
    pub fn decodeFrame(self: *Decoder, bytes: []const u8, out: []i16) Error!FrameInfo {
        const hdr = Header.parse(bytes) orelse return error.InvalidFrame;
        const size = hdr.frameSize();
        if (bytes.len < size) return error.TruncatedFrame;
        const nch = hdr.channels();
        const info: FrameInfo = .{ .sample_rate = hdr.sampleRate(), .channels = nch, .samples = hdr.samplesPerFrame() };
        if (out.len < info.samples * nch) return error.OutputTooSmall;

        const side_start = Header.size + @as(usize, if (hdr.has_crc) 2 else 0);
        var side_reader: BitReader = .init(bytes[side_start..hdr.mainDataOffset()]);
        var side = readSideInfo(&side_reader, hdr);
        const main_data = bytes[hdr.mainDataOffset()..size];

        // Keep only what a future main_data_begin can reach, then append.
        if (self.reservoir_len > max_main_data_begin) {
            const keep = self.reservoir[self.reservoir_len - max_main_data_begin .. self.reservoir_len];
            std.mem.copyForwards(u8, self.reservoir[0..max_main_data_begin], keep);
            self.reservoir_len = max_main_data_begin;
        }
        const have_data = side.main_data_begin <= self.reservoir_len;
        const start = if (have_data) self.reservoir_len - side.main_data_begin else 0;
        @memcpy(self.reservoir[self.reservoir_len..][0..main_data.len], main_data);
        self.reservoir_len += main_data.len;

        if (!have_data) {
            // The bit reservoir references data from before the stream start
            // (e.g. after seeking). Emit silence for this frame.
            @memset(out[0 .. info.samples * nch], 0);
            return info;
        }

        var reader: BitReader = .init(self.reservoir[start..self.reservoir_len]);
        for (0..hdr.granules()) |gr| {
            var xr: [2][576]f32 = undefined;
            var nonzero: [2]usize = undefined;
            for (0..nch) |ch| {
                const gi = &side.granules[gr][ch];
                const part2_start = reader.pos;
                self.readScalefactors(&reader, hdr, &side, gi, gr, ch);
                var is: [576]i32 = undefined;
                nonzero[ch] = readHuffman(&reader, hdr, gi, part2_start + gi.part2_3_length, &is);
                requantize(hdr, gi, &self.scalefactors[ch], &is, nonzero[ch], &xr[ch]);
            }
            if (nch == 2 and hdr.mode == .joint_stereo) {
                processStereo(hdr, &side.granules[gr][1], &self.scalefactors[1], &xr, nonzero);
            }
            for (0..nch) |ch| {
                const gi = &side.granules[gr][ch];
                reorder(hdr, gi, &xr[ch]);
                antialias(gi, &xr[ch]);
                self.hybridSynthesis(gi, ch, &xr[ch]);
                self.polyphaseSynthesis(ch, &xr[ch], out[gr * 576 * nch ..], nch);
            }
        }
        return info;
    }

    fn readScalefactors(self: *Decoder, r: *BitReader, hdr: Header, side: *const SideInfo, gi: *GranuleInfo, gr: usize, ch: usize) void {
        const sf = &self.scalefactors[ch];
        if (hdr.isMpeg1()) {
            const slen = tables.mpeg1_slen[gi.scalefac_compress];
            if (gi.isShort()) {
                var first_short: usize = 0;
                if (gi.mixed_block) {
                    for (0..8) |sfb| sf.long[sfb] = @intCast(r.readBits(@intCast(slen[0])));
                    first_short = 3;
                }
                for (first_short..12) |sfb| {
                    const len: u6 = @intCast(if (sfb < 6) slen[0] else slen[1]);
                    for (0..3) |w| sf.short[sfb][w] = @intCast(r.readBits(len));
                }
                sf.short[12] = @splat(0);
            } else {
                const groups = [5]usize{ 0, 6, 11, 16, 21 };
                for (0..4) |g| {
                    if (gr == 1 and side.scfsi[ch][g]) continue;
                    const len: u6 = @intCast(if (g < 2) slen[0] else slen[1]);
                    for (groups[g]..groups[g + 1]) |sfb| sf.long[sfb] = @intCast(r.readBits(len));
                }
                sf.long[21] = 0;
            }
            return;
        }

        // MPEG-2 / 2.5 (LSF) scalefactors.
        var slen: [4]u32 = undefined;
        var table: usize = undefined;
        var sfc = gi.scalefac_compress;
        const intensity_channel = ch == 1 and hdr.mode == .joint_stereo and
            (hdr.mode_extension & frame.mode_ext_intensity) != 0;
        if (intensity_channel) {
            sfc >>= 1;
            if (sfc < 180) {
                slen = .{ sfc / 36, (sfc % 36) / 6, (sfc % 36) % 6, 0 };
                table = 3;
            } else if (sfc < 244) {
                sfc -= 180;
                slen = .{ (sfc & 63) >> 4, (sfc & 15) >> 2, sfc & 3, 0 };
                table = 4;
            } else {
                sfc -= 244;
                slen = .{ sfc / 3, sfc % 3, 0, 0 };
                table = 5;
            }
        } else if (sfc < 400) {
            slen = .{ (sfc >> 4) / 5, (sfc >> 4) % 5, (sfc & 15) >> 2, sfc & 3 };
            table = 0;
        } else if (sfc < 500) {
            sfc -= 400;
            slen = .{ (sfc >> 2) / 5, (sfc >> 2) % 5, sfc & 3, 0 };
            table = 1;
        } else {
            sfc -= 500;
            slen = .{ sfc / 3, sfc % 3, 0, 0 };
            table = 2;
            gi.preflag = true;
        }
        const kind: usize = if (!gi.isShort()) 0 else if (gi.mixed_block) 2 else 1;
        const counts = tables.lsf_nr_of_sfb[table][kind];

        var values: [39]u8 = @splat(0);
        var n: usize = 0;
        for (counts, slen) |count, len| {
            for (0..count) |_| {
                values[n] = @intCast(r.readBits(@intCast(len)));
                n += 1;
            }
        }
        switch (kind) {
            0 => {
                @memcpy(sf.long[0..21], values[0..21]);
                sf.long[21] = 0;
            },
            1 => for (0..12) |sfb| for (0..3) |w| {
                sf.short[sfb][w] = values[sfb * 3 + w];
            },
            else => {
                @memcpy(sf.long[0..6], values[0..6]);
                for (3..12) |sfb| for (0..3) |w| {
                    sf.short[sfb][w] = values[6 + (sfb - 3) * 3 + w];
                };
            },
        }
        sf.short[12] = @splat(0);
    }

    fn hybridSynthesis(self: *Decoder, gi: *const GranuleInfo, ch: usize, xr: *[576]f32) void {
        const overlap = &self.overlap[ch];
        for (0..32) |sb| {
            const in = xr[sb * 18 ..][0..18];
            var out: [36]f32 = undefined;
            if (gi.isShort() and !(gi.mixed_block and sb < 2)) {
                filterbank.imdctShort(in, &out);
            } else {
                const bt: u2 = if (gi.window_switching and gi.block_type != 2) gi.block_type else 0;
                filterbank.imdctLong(in, bt, &out);
            }
            const ov = overlap[sb * 18 ..][0..18];
            for (0..18) |i| {
                in[i] = out[i] + ov[i];
                ov[i] = out[18 + i];
            }
            // Frequency inversion: negate odd samples of odd subbands.
            if (sb & 1 == 1) {
                var i: usize = 1;
                while (i < 18) : (i += 2) in[i] = -in[i];
            }
        }
    }

    fn polyphaseSynthesis(self: *Decoder, ch: usize, xr: *const [576]f32, out: []i16, nch: usize) void {
        for (0..18) |t| {
            var s: [32]f32 = undefined;
            for (&s, 0..) |*v, sb| v.* = xr[sb * 18 + t];
            var pcm: [32]f32 = undefined;
            self.synthesis[ch].process(&s, &pcm);
            for (pcm, 0..) |p, j| {
                const scaled = std.math.clamp(@round(p * 32768.0), -32768.0, 32767.0);
                out[(t * 32 + j) * nch + ch] = @intFromFloat(scaled);
            }
        }
    }
};

fn readSideInfo(r: *BitReader, hdr: Header) SideInfo {
    var si: SideInfo = .{};
    const nch = hdr.channels();
    if (hdr.isMpeg1()) {
        si.main_data_begin = r.readBits(9);
        _ = r.readBits(if (nch == 1) 5 else 3);
        for (0..nch) |ch| for (0..4) |g| {
            si.scfsi[ch][g] = r.readFlag();
        };
    } else {
        si.main_data_begin = r.readBits(8);
        _ = r.readBits(if (nch == 1) 1 else 2);
    }
    for (0..hdr.granules()) |gr| for (0..nch) |ch| {
        const gi = &si.granules[gr][ch];
        gi.part2_3_length = r.readBits(12);
        gi.big_values = @min(r.readBits(9), 288);
        gi.global_gain = r.readBits(8);
        gi.scalefac_compress = r.readBits(if (hdr.isMpeg1()) 4 else 9);
        gi.window_switching = r.readFlag();
        if (gi.window_switching) {
            gi.block_type = @intCast(r.readBits(2));
            gi.mixed_block = r.readFlag();
            for (0..2) |i| gi.table_select[i] = @intCast(r.readBits(5));
            for (0..3) |i| gi.subblock_gain[i] = @intCast(r.readBits(3));
            // Implicit region counts. Block type 0 with window switching is
            // illegal; treat it as a normal long block.
            if (gi.block_type == 0) gi.window_switching = false;
            gi.region0_count = if (gi.block_type == 2 and !gi.mixed_block) 8 else 7;
            gi.region1_count = 20 - gi.region0_count;
        } else {
            for (0..3) |i| gi.table_select[i] = @intCast(r.readBits(5));
            gi.region0_count = r.readBits(4);
            gi.region1_count = r.readBits(3);
        }
        if (hdr.isMpeg1()) gi.preflag = r.readFlag();
        gi.scalefac_scale = r.readFlag();
        gi.count1table_select = r.readBit();
    };
    return si;
}

fn decodePair(r: *BitReader, tree: []const u16) u16 {
    var p: usize = 0;
    var steps: usize = 0;
    while (!tables.isLeaf(tree[p])) : (steps += 1) {
        if (steps >= 24) return 0;
        p = tables.treeStep(tree, p, r.readBit());
        if (p >= tree.len) return 0;
    }
    return tree[p];
}

fn readSign(r: *BitReader, v: i32) i32 {
    return if (v != 0 and r.readFlag()) -v else v;
}

/// Decodes the Huffman-coded spectrum of one granule/channel. Returns the
/// number of lines that may be nonzero; the rest of `is` is zeroed.
fn readHuffman(r: *BitReader, hdr: Header, gi: *const GranuleInfo, end_bit: usize, is: *[576]i32) usize {
    const sfb_l = &tables.sfb_long[hdr.sfbIndex()];
    const big_end = gi.big_values * 2;
    var region1: usize = undefined;
    var region2: usize = undefined;
    if (gi.isShort()) {
        region1 = if (hdr.sfbIndex() == 8) 72 else 36;
        region2 = 576;
    } else {
        region1 = sfb_l[@min(gi.region0_count + 1, 22)];
        region2 = sfb_l[@min(gi.region0_count + gi.region1_count + 2, 22)];
    }

    var i: usize = 0;
    while (i < big_end) : (i += 2) {
        const table = gi.table_select[if (i < region1) 0 else if (i < region2) 1 else 2];
        const ht = tables.huffman[table];
        if (ht.tree.len == 0) {
            is[i] = 0;
            is[i + 1] = 0;
            continue;
        }
        const leaf = decodePair(r, ht.tree);
        var x: i32 = (leaf >> 4) & 0xf;
        var y: i32 = leaf & 0xf;
        if (ht.linbits > 0 and x == 15) x += @intCast(r.readBits(ht.linbits));
        x = readSign(r, x);
        if (ht.linbits > 0 and y == 15) y += @intCast(r.readBits(ht.linbits));
        y = readSign(r, y);
        is[i] = x;
        is[i + 1] = y;
    }

    const quad_tree = tables.count1_trees[gi.count1table_select];
    while (i + 4 <= 576 and r.pos < end_bit) {
        const q = decodePair(r, quad_tree) & 0xf;
        var vals: [4]i32 = .{ (q >> 3) & 1, (q >> 2) & 1, (q >> 1) & 1, q & 1 };
        for (&vals) |*v| v.* = readSign(r, v.*);
        // A quadruple that runs past the granule's data is padding.
        if (r.pos > end_bit) break;
        is[i..][0..4].* = vals;
        i += 4;
    }
    @memset(is[i..], 0);
    r.pos = end_bit;
    return i;
}

fn pow43(v: i32) f32 {
    const a: f32 = @floatFromInt(@abs(v));
    const m = std.math.pow(f32, a, 4.0 / 3.0);
    return if (v < 0) -m else m;
}

fn requantize(hdr: Header, gi: *const GranuleInfo, sf: *const Scalefactors, is: *const [576]i32, nonzero: usize, xr: *[576]f32) void {
    @memset(xr, 0);
    const sfb_l = &tables.sfb_long[hdr.sfbIndex()];
    const sfb_s = &tables.sfb_short[hdr.sfbIndex()];
    const gain: f32 = 0.25 * (@as(f32, @floatFromInt(gi.global_gain)) - 210.0);
    const mult: f32 = if (gi.scalefac_scale) 1.0 else 0.5;

    // Long-block region: everything for long blocks, the first bands for
    // mixed blocks.
    const long_end: usize = if (!gi.isShort()) 576 else if (gi.mixed_block) sfb_l[if (hdr.isMpeg1()) 8 else 6] else 0;
    var sfb: usize = 0;
    var i: usize = 0;
    while (i < @min(long_end, nonzero)) : (i += 1) {
        while (i >= sfb_l[sfb + 1]) sfb += 1;
        if (is[i] == 0) continue;
        const pre: f32 = if (gi.preflag) @floatFromInt(tables.pretab[sfb]) else 0;
        const exp = gain - mult * (@as(f32, @floatFromInt(sf.long[sfb])) + pre);
        xr[i] = pow43(is[i]) * @exp2(exp);
    }
    if (long_end >= 576) return;

    const first_short: usize = if (gi.mixed_block) 3 else 0;
    for (first_short..13) |s| {
        const width: usize = sfb_s[s + 1] - sfb_s[s];
        for (0..3) |w| {
            const exp = gain - 2.0 * @as(f32, @floatFromInt(gi.subblock_gain[w])) -
                mult * @as(f32, @floatFromInt(sf.short[s][w]));
            const base = @as(usize, sfb_s[s]) * 3 + w * width;
            for (base..base + width) |j| {
                if (j >= nonzero) break;
                if (is[j] != 0) xr[j] = pow43(is[j]) * @exp2(exp);
            }
        }
    }
}

/// Joint stereo: mid/side and (MPEG-1) intensity stereo reconstruction.
fn processStereo(hdr: Header, gi_right: *const GranuleInfo, sf_right: *const Scalefactors, xr: *[2][576]f32, nonzero: [2]usize) void {
    const ms = (hdr.mode_extension & frame.mode_ext_ms) != 0;
    const intensity = (hdr.mode_extension & frame.mode_ext_intensity) != 0 and hdr.isMpeg1();

    // Per-line intensity position; 7 (or no intensity) means "not intensity coded".
    var is_pos: [576]u8 = @splat(7);
    if (intensity) intensityPositions(hdr, gi_right, sf_right, &xr[1], &is_pos);

    const limit = @max(nonzero[0], nonzero[1]);
    const inv_sqrt2: f32 = std.math.sqrt1_2;
    for (0..576) |i| {
        if (is_pos[i] != 7) {
            const ratio = @tan(@as(f32, @floatFromInt(is_pos[i])) * std.math.pi / 12.0);
            const l = xr[0][i];
            xr[0][i] = l * ratio / (1.0 + ratio);
            xr[1][i] = l / (1.0 + ratio);
        } else if (ms and i < limit) {
            const m = xr[0][i];
            const s = xr[1][i];
            xr[0][i] = (m + s) * inv_sqrt2;
            xr[1][i] = (m - s) * inv_sqrt2;
        }
    }
}

fn intensityPositions(hdr: Header, gi: *const GranuleInfo, sf: *const Scalefactors, right: *const [576]f32, is_pos: *[576]u8) void {
    const sfb_l = &tables.sfb_long[hdr.sfbIndex()];
    const sfb_s = &tables.sfb_short[hdr.sfbIndex()];
    if (!gi.isShort()) {
        var last: usize = 576;
        while (last > 0 and right[last - 1] == 0) last -= 1;
        var start: usize = 0;
        while (sfb_l[start] < last) start += 1;
        for (start..22) |sfb| {
            const pos = sf.long[if (sfb == 21) 20 else sfb];
            @memset(is_pos[sfb_l[sfb]..sfb_l[sfb + 1]], pos);
        }
        return;
    }
    // Short blocks: the intensity start is found per window.
    const first: usize = if (gi.mixed_block) 3 else 0;
    for (0..3) |w| {
        var start: usize = first;
        for (first..13) |s| {
            const width: usize = sfb_s[s + 1] - sfb_s[s];
            const base = @as(usize, sfb_s[s]) * 3 + w * width;
            for (right[base..][0..width]) |v| {
                if (v != 0) {
                    start = s + 1;
                    break;
                }
            }
        }
        for (start..13) |s| {
            const width: usize = sfb_s[s + 1] - sfb_s[s];
            const base = @as(usize, sfb_s[s]) * 3 + w * width;
            @memset(is_pos[base..][0..width], sf.short[if (s == 12) 11 else s][w]);
        }
    }
}

/// Reorders short-block lines from band/window order to the subband-interleaved
/// order the IMDCT expects.
fn reorder(hdr: Header, gi: *const GranuleInfo, xr: *[576]f32) void {
    if (!gi.isShort()) return;
    const sfb_s = &tables.sfb_short[hdr.sfbIndex()];
    const first: usize = if (gi.mixed_block) 3 else 0;
    var tmp: [576]f32 = undefined;
    for (first..13) |s| {
        const width: usize = sfb_s[s + 1] - sfb_s[s];
        const base = @as(usize, sfb_s[s]) * 3;
        for (0..3) |w| for (0..width) |j| {
            tmp[base + 3 * j + w] = xr[base + w * width + j];
        };
    }
    const start = @as(usize, sfb_s[first]) * 3;
    @memcpy(xr[start..], tmp[start..]);
}

fn antialias(gi: *const GranuleInfo, xr: *[576]f32) void {
    if (gi.isShort() and !gi.mixed_block) return;
    const limit: usize = if (gi.isShort()) 1 else 31;
    for (1..limit + 1) |sb| {
        for (0..8) |i| {
            const lo = sb * 18 - 1 - i;
            const hi = sb * 18 + i;
            const a = xr[lo];
            const b = xr[hi];
            xr[lo] = a * tables.antialias_cs[i] - b * tables.antialias_ca[i];
            xr[hi] = b * tables.antialias_cs[i] + a * tables.antialias_ca[i];
        }
    }
}

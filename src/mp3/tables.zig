//! Layer III constant tables shared by the decoder and encoder.

const std = @import("std");
const data = @import("tables_data.zig");

pub const synth_window = data.synth_window;

/// Scalefactor band boundaries (in frequency lines) for long blocks, indexed by
/// `Header.sfbIndex()`: MPEG-1 44.1/48/32 kHz, MPEG-2 22.05/24/16 kHz,
/// MPEG-2.5 11.025/12/8 kHz.
pub const sfb_long = [9][23]u16{
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288, 342, 418, 576 },
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60, 72, 88, 106, 128, 156, 190, 230, 276, 330, 384, 576 },
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156, 194, 240, 296, 364, 448, 550, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 114, 136, 162, 194, 232, 278, 332, 394, 464, 540, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    .{ 0, 12, 24, 36, 48, 60, 72, 88, 108, 132, 160, 192, 232, 280, 336, 400, 476, 566, 568, 570, 572, 574, 576 },
};

/// Scalefactor band boundaries for short blocks (per window; multiply by 3 for
/// the position within the granule).
pub const sfb_short = [9][14]u16{
    .{ 0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192 },
    .{ 0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192 },
    .{ 0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192 },
    .{ 0, 4, 8, 12, 18, 24, 32, 42, 56, 74, 100, 132, 174, 192 },
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 136, 180, 192 },
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192 },
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192 },
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192 },
    .{ 0, 8, 16, 24, 36, 52, 72, 96, 124, 160, 162, 164, 166, 192 },
};

/// Pre-emphasis added to long-block scalefactors when `preflag` is set.
pub const pretab = [22]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0 };

/// MPEG-1 scalefactor bit widths (slen1, slen2) by scalefac_compress.
pub const mpeg1_slen = [16][2]u8{
    .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 }, .{ 3, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 1, 3 },
    .{ 2, 1 }, .{ 2, 2 }, .{ 2, 3 }, .{ 3, 1 }, .{ 3, 2 }, .{ 3, 3 }, .{ 4, 2 }, .{ 4, 3 },
};

/// MPEG-2 LSF: number of scalefactors per slen group, indexed by
/// [scalefactor table][block kind: long, short, mixed][group].
pub const lsf_nr_of_sfb = [6][3][4]u8{
    .{ .{ 6, 5, 5, 5 }, .{ 9, 9, 9, 9 }, .{ 6, 9, 9, 9 } },
    .{ .{ 6, 5, 7, 3 }, .{ 9, 9, 12, 6 }, .{ 6, 9, 12, 6 } },
    .{ .{ 11, 10, 0, 0 }, .{ 18, 18, 0, 0 }, .{ 15, 18, 0, 0 } },
    .{ .{ 7, 7, 7, 0 }, .{ 12, 12, 12, 0 }, .{ 6, 15, 12, 0 } },
    .{ .{ 6, 6, 6, 3 }, .{ 12, 9, 9, 6 }, .{ 6, 12, 9, 6 } },
    .{ .{ 8, 8, 5, 0 }, .{ 15, 12, 9, 0 }, .{ 6, 18, 9, 0 } },
};

/// Antialias butterfly coefficients derived from ci[] in ISO/IEC 11172-3.
const antialias_ci = [8]f64{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };

pub const antialias_cs = blk: {
    var cs: [8]f32 = undefined;
    for (antialias_ci, 0..) |c, i| cs[i] = @floatCast(1.0 / @sqrt(1.0 + c * c));
    break :blk cs;
};

pub const antialias_ca = blk: {
    var ca: [8]f32 = undefined;
    for (antialias_ci, 0..) |c, i| ca[i] = @floatCast(c / @sqrt(1.0 + c * c));
    break :blk ca;
};

pub const HuffTable = struct {
    tree: []const u16,
    linbits: u4,
    /// Largest x/y value representable without linbits (exclusive bound).
    xlen: u5,
};

/// Big-value Huffman tables 0..31. Tables 0, 4 and 14 are unused/empty.
pub const huffman = blk: {
    const E: []const u16 = &.{};
    break :blk [32]HuffTable{
        .{ .tree = E, .linbits = 0, .xlen = 0 },
        .{ .tree = &data.tree_1, .linbits = 0, .xlen = 2 },
        .{ .tree = &data.tree_2, .linbits = 0, .xlen = 3 },
        .{ .tree = &data.tree_3, .linbits = 0, .xlen = 3 },
        .{ .tree = E, .linbits = 0, .xlen = 0 },
        .{ .tree = &data.tree_5, .linbits = 0, .xlen = 4 },
        .{ .tree = &data.tree_6, .linbits = 0, .xlen = 4 },
        .{ .tree = &data.tree_7, .linbits = 0, .xlen = 6 },
        .{ .tree = &data.tree_8, .linbits = 0, .xlen = 6 },
        .{ .tree = &data.tree_9, .linbits = 0, .xlen = 6 },
        .{ .tree = &data.tree_10, .linbits = 0, .xlen = 8 },
        .{ .tree = &data.tree_11, .linbits = 0, .xlen = 8 },
        .{ .tree = &data.tree_12, .linbits = 0, .xlen = 8 },
        .{ .tree = &data.tree_13, .linbits = 0, .xlen = 16 },
        .{ .tree = E, .linbits = 0, .xlen = 0 },
        .{ .tree = &data.tree_15, .linbits = 0, .xlen = 16 },
        .{ .tree = &data.tree_16, .linbits = 1, .xlen = 16 },
        .{ .tree = &data.tree_16, .linbits = 2, .xlen = 16 },
        .{ .tree = &data.tree_16, .linbits = 3, .xlen = 16 },
        .{ .tree = &data.tree_16, .linbits = 4, .xlen = 16 },
        .{ .tree = &data.tree_16, .linbits = 6, .xlen = 16 },
        .{ .tree = &data.tree_16, .linbits = 8, .xlen = 16 },
        .{ .tree = &data.tree_16, .linbits = 10, .xlen = 16 },
        .{ .tree = &data.tree_16, .linbits = 13, .xlen = 16 },
        .{ .tree = &data.tree_24, .linbits = 4, .xlen = 16 },
        .{ .tree = &data.tree_24, .linbits = 5, .xlen = 16 },
        .{ .tree = &data.tree_24, .linbits = 6, .xlen = 16 },
        .{ .tree = &data.tree_24, .linbits = 7, .xlen = 16 },
        .{ .tree = &data.tree_24, .linbits = 8, .xlen = 16 },
        .{ .tree = &data.tree_24, .linbits = 9, .xlen = 16 },
        .{ .tree = &data.tree_24, .linbits = 11, .xlen = 16 },
        .{ .tree = &data.tree_24, .linbits = 13, .xlen = 16 },
    };
};

/// Count1 (quadruple) tables A and B.
pub const count1_trees = [2][]const u16{ &data.tree_32, &data.tree_33 };

/// Follows one branch of a dist10-format tree. `bit` selects the right (1) or
/// left (0) child. Offsets >= 250 chain to reach far-away nodes.
pub fn treeStep(tree: []const u16, point: usize, bit: u1) usize {
    var p = point;
    if (bit == 1) {
        while (tree[p] & 0xff >= 250) p += tree[p] & 0xff;
        p += tree[p] & 0xff;
    } else {
        while (tree[p] >> 8 >= 250) p += tree[p] >> 8;
        p += tree[p] >> 8;
    }
    return p;
}

pub fn isLeaf(node: u16) bool {
    return node & 0xff00 == 0;
}

// ---------------------------------------------------------------------------
// Encoder code tables, derived from the decoding trees at compile time so the
// encoder and decoder can never disagree.

pub const Code = struct {
    code: u32 = 0,
    len: u8 = 0,
};

fn buildCodes(comptime tree: []const u16) [256]Code {
    @setEvalBranchQuota(200_000);
    var codes: [256]Code = @splat(.{});
    const Item = struct { point: usize, code: u32, len: u8 };
    var stack: [64]Item = undefined;
    var sp: usize = 1;
    stack[0] = .{ .point = 0, .code = 0, .len = 0 };
    while (sp > 0) {
        sp -= 1;
        const it = stack[sp];
        const node = tree[it.point];
        if (isLeaf(node)) {
            codes[node & 0xff] = .{ .code = it.code, .len = it.len };
            continue;
        }
        for ([2]u1{ 0, 1 }) |bit| {
            const next = treeStep(tree, it.point, bit);
            if (next < tree.len) {
                stack[sp] = .{ .point = next, .code = (it.code << 1) | bit, .len = it.len + 1 };
                sp += 1;
            }
        }
    }
    return codes;
}

/// Codes indexed by [tree family][x << 4 | y]. Family is the table number for
/// tables 1..15; tables 16..23 share family 16 and 24..31 share family 24.
pub const pair_codes = blk: {
    var all: [32][256]Code = @splat(@splat(.{}));
    for (huffman, 0..) |t, i| {
        if (t.tree.len == 0 or (i > 16 and i < 24) or i > 24) continue;
        all[i] = buildCodes(t.tree);
    }
    break :blk all;
};

pub fn pairCodeFamily(table: usize) usize {
    if (table >= 24) return 24;
    if (table >= 16) return 16;
    return table;
}

/// Count1 codes indexed by [table][v << 3 | w << 2 | x << 1 | y].
pub const quad_codes = [2][16]Code{
    buildCodes(&data.tree_32)[0..16].*,
    buildCodes(&data.tree_33)[0..16].*,
};

test "derived huffman codes are complete and prefix-decodable" {
    const BitReader = @import("bits.zig").BitReader;
    for (huffman, 0..) |t, i| {
        if (t.tree.len == 0) continue;
        const fam = pair_codes[pairCodeFamily(i)];
        for (0..t.xlen) |x| for (0..t.xlen) |y| {
            const c = fam[x << 4 | y];
            try std.testing.expect(c.len > 0 and c.len <= 19);
            // Decode the code back through the tree.
            var buf: [4]u8 = @splat(0);
            var w = @import("bits.zig").BitWriter.init(&buf);
            w.writeBits(c.code, @intCast(c.len));
            var r: BitReader = .init(&buf);
            var p: usize = 0;
            while (!isLeaf(t.tree[p])) p = treeStep(t.tree, p, r.readBit());
            try std.testing.expectEqual(@as(u16, @intCast(x << 4 | y)), t.tree[p]);
            try std.testing.expectEqual(@as(usize, c.len), r.pos);
        };
    }
    // Table B is a fixed 4-bit code with inverted value.
    for (quad_codes[1], 0..) |c, v| {
        try std.testing.expectEqual(@as(u8, 4), c.len);
        try std.testing.expectEqual(@as(u32, 15 - @as(u32, @intCast(v))), c.code);
    }
}

//! Polyphase subband filterbanks and the hybrid (I)MDCT stage of Layer III.

const std = @import("std");
const tables = @import("tables.zig");

const pi = std.math.pi;

/// Synthesis matrixing coefficients N[i][k] = cos((16 + i)(2k + 1)pi / 64).
const synth_matrix = blk: {
    @setEvalBranchQuota(100_000);
    var m: [64][32]f32 = undefined;
    for (0..64) |i| for (0..32) |k| {
        m[i][k] = @floatCast(@cos(@as(f64, @floatFromInt((16 + i) * (2 * k + 1))) * pi / 64.0));
    };
    break :blk m;
};

/// Analysis matrixing coefficients M[k][i] = cos((2k + 1)(i - 16)pi / 64).
const analysis_matrix = blk: {
    @setEvalBranchQuota(100_000);
    var m: [32][64]f32 = undefined;
    for (0..32) |k| for (0..64) |i| {
        const ii: f64 = @as(f64, @floatFromInt(i)) - 16.0;
        m[k][i] = @floatCast(@cos(@as(f64, @floatFromInt(2 * k + 1)) * ii * pi / 64.0));
    };
    break :blk m;
};

/// Analysis window C[i] = D[i] / 32.
const analysis_window = blk: {
    var w: [512]f32 = undefined;
    for (tables.synth_window, 0..) |d, i| w[i] = d / 32.0;
    break :blk w;
};

/// 32-band polyphase synthesis filterbank (one per channel).
pub const Synthesis = struct {
    v: [1024]f32 = @splat(0),
    offset: usize = 0,

    /// Consumes one sample from each of the 32 subbands and produces 32 PCM
    /// samples in the range [-1, 1].
    pub fn process(self: *Synthesis, s: *const [32]f32, out: *[32]f32) void {
        self.offset = (self.offset + 1024 - 64) & 1023;
        const v = self.v[self.offset..][0..64];
        for (v, synth_matrix) |*dst, row| {
            var sum: f32 = 0;
            for (row, s) |n, x| sum += n * x;
            dst.* = sum;
        }
        const d = &tables.synth_window;
        for (out, 0..) |*o, j| {
            var sum: f32 = 0;
            for (0..8) |i| {
                sum += self.v[(self.offset + i * 128 + j) & 1023] * d[i * 64 + j];
                sum += self.v[(self.offset + i * 128 + 96 + j) & 1023] * d[i * 64 + 32 + j];
            }
            o.* = sum;
        }
    }
};

/// 32-band polyphase analysis filterbank (one per channel).
pub const Analysis = struct {
    x: [512]f32 = @splat(0),
    offset: usize = 0,

    /// Consumes 32 PCM samples (oldest first) and produces one sample for each
    /// of the 32 subbands.
    pub fn process(self: *Analysis, in: *const [32]f32, out: *[32]f32) void {
        self.offset = (self.offset + 512 - 32) & 511;
        for (in, 0..) |sample, k| self.x[self.offset + 31 - k] = sample;
        var y: [64]f32 = undefined;
        for (&y, 0..) |*dst, i| {
            var sum: f32 = 0;
            for (0..8) |j| sum += analysis_window[i + 64 * j] * self.x[(self.offset + i + 64 * j) & 511];
            dst.* = sum;
        }
        for (out, analysis_matrix) |*o, row| {
            var sum: f32 = 0;
            for (row, y) |m, yy| sum += m * yy;
            o.* = sum;
        }
    }
};

// ---------------------------------------------------------------------------
// Hybrid filterbank (MDCT)

/// cos(pi/72 * (2i + 19)(2k + 1)) for the 36-point long transform.
const long_cos = blk: {
    @setEvalBranchQuota(100_000);
    var t: [36][18]f32 = undefined;
    for (0..36) |i| for (0..18) |k| {
        t[i][k] = @floatCast(@cos(pi / 72.0 * @as(f64, @floatFromInt((2 * i + 19) * (2 * k + 1)))));
    };
    break :blk t;
};

/// cos(pi/24 * (2i + 7)(2k + 1)) for the 12-point short transform.
const short_cos = blk: {
    @setEvalBranchQuota(10_000);
    var t: [12][6]f32 = undefined;
    for (0..12) |i| for (0..6) |k| {
        t[i][k] = @floatCast(@cos(pi / 24.0 * @as(f64, @floatFromInt((2 * i + 7) * (2 * k + 1)))));
    };
    break :blk t;
};

fn sinWindow(comptime n: f64, i: f64) f32 {
    return @floatCast(@sin(pi / n * (i + 0.5)));
}

/// Long-block windows for block types 0 (normal), 1 (start) and 3 (stop).
/// Entry 2 holds the short window in its first 12 slots.
pub const windows = blk: {
    @setEvalBranchQuota(10_000);
    var w: [4][36]f32 = @splat(@splat(0));
    for (0..36) |i| {
        const fi: f64 = @floatFromInt(i);
        w[0][i] = sinWindow(36, fi);
        // Start window.
        if (i < 18) w[1][i] = sinWindow(36, fi) else if (i < 24) w[1][i] = 1 else if (i < 30) w[1][i] = sinWindow(12, fi - 18) else w[1][i] = 0;
        // Stop window.
        if (i < 6) w[3][i] = 0 else if (i < 12) w[3][i] = sinWindow(12, fi - 6) else if (i < 18) w[3][i] = 1 else w[3][i] = sinWindow(36, fi);
        if (i < 12) w[2][i] = sinWindow(12, fi);
    }
    break :blk w;
};

/// Inverse MDCT of one subband for long blocks, windowed for `block_type`.
pub fn imdctLong(in: *const [18]f32, block_type: u2, out: *[36]f32) void {
    const win = &windows[block_type];
    for (out, long_cos, win) |*o, row, w| {
        var sum: f32 = 0;
        for (row, in) |c, x| sum += c * x;
        o.* = sum * w;
    }
}

/// Inverse MDCT of one subband for short blocks: three overlapped 12-point
/// transforms. Input is interleaved as in[3 * k + window].
pub fn imdctShort(in: *const [18]f32, out: *[36]f32) void {
    @memset(out, 0);
    const win = &windows[2];
    for (0..3) |w| {
        for (0..12) |i| {
            var sum: f32 = 0;
            for (0..6) |k| sum += short_cos[i][k] * in[3 * k + w];
            out[6 + 6 * w + i] += sum * win[i];
        }
    }
}

/// Forward MDCT of one subband for normal long blocks (block type 0).
/// `in` holds the previous and current granule's 18 subband samples.
pub fn mdctLong(in: *const [36]f32, out: *[18]f32) void {
    const win = &windows[0];
    for (out, 0..) |*o, k| {
        var sum: f32 = 0;
        for (0..36) |i| sum += in[i] * win[i] * long_cos[i][k];
        o.* = sum * (1.0 / 9.0);
    }
}

test "analysis followed by synthesis reconstructs the input" {
    var ana: Analysis = .{};
    var syn: Synthesis = .{};
    const n = 32 * 64;
    var input: [n]f32 = undefined;
    var output: [n]f32 = undefined;
    for (&input, 0..) |*x, i| {
        const t: f32 = @floatFromInt(i);
        x.* = 0.5 * @sin(t * 0.05) + 0.25 * @sin(t * 0.9);
    }
    var block: usize = 0;
    while (block < n) : (block += 32) {
        var sb: [32]f32 = undefined;
        ana.process(input[block..][0..32], &sb);
        syn.process(&sb, output[block..][0..32]);
    }
    // The cascade delays the signal by 481 samples.
    const delay = 481;
    var max_err: f32 = 0;
    for (delay + 512..n) |i| max_err = @max(max_err, @abs(output[i] - input[i - delay]));
    try std.testing.expect(max_err < 1e-3);
}

test "mdct followed by imdct reconstructs with overlap-add" {
    var prev: [18]f32 = @splat(0);
    var overlap: [18]f32 = @splat(0);
    var signal: [18 * 8]f32 = undefined;
    for (&signal, 0..) |*x, i| x.* = @sin(@as(f32, @floatFromInt(i)) * 0.3);
    var out: [18 * 8]f32 = undefined;
    for (0..8) |g| {
        const cur = signal[g * 18 ..][0..18];
        var buf: [36]f32 = undefined;
        @memcpy(buf[0..18], &prev);
        @memcpy(buf[18..], cur);
        var coeffs: [18]f32 = undefined;
        mdctLong(&buf, &coeffs);
        var y: [36]f32 = undefined;
        imdctLong(&coeffs, 0, &y);
        for (0..18) |i| out[g * 18 + i] = y[i] + overlap[i];
        @memcpy(&overlap, y[18..]);
        prev = cur.*;
    }
    for (18..18 * 8) |i| try std.testing.expectApproxEqAbs(signal[i - 18], out[i], 1e-4);
}

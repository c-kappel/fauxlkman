const std = @import("std");

/// MSB-first bit reader over a byte slice. Reads past the end yield zero bits,
/// which keeps the decoder robust against truncated or corrupt frames.
pub const BitReader = struct {
    data: []const u8,
    /// Current position in bits from the start of `data`.
    pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn readBits(self: *BitReader, n: u6) u32 {
        if (n == 0) return 0;
        std.debug.assert(n <= 32);
        const byte = self.pos >> 3;
        var window: u64 = 0;
        for (0..5) |i| {
            window <<= 8;
            if (byte + i < self.data.len) window |= self.data[byte + i];
        }
        const shift: u6 = @intCast(40 - (self.pos & 7) - n);
        self.pos += n;
        return @truncate((window >> shift) & ((@as(u64, 1) << n) - 1));
    }

    pub fn readBit(self: *BitReader) u1 {
        const byte = self.pos >> 3;
        const bit: u3 = @intCast(7 - (self.pos & 7));
        self.pos += 1;
        if (byte >= self.data.len) return 0;
        return @truncate(self.data[byte] >> bit);
    }

    pub fn readFlag(self: *BitReader) bool {
        return self.readBit() == 1;
    }
};

/// MSB-first bit writer into a caller-provided buffer that must start zeroed.
pub const BitWriter = struct {
    buf: []u8,
    /// Current position in bits from the start of `buf`.
    pos: usize = 0,

    pub fn init(buf: []u8) BitWriter {
        return .{ .buf = buf };
    }

    pub fn writeBits(self: *BitWriter, value: u32, n: u6) void {
        var i = n;
        while (i > 0) {
            i -= 1;
            if ((value >> @intCast(i)) & 1 == 1) {
                self.buf[self.pos >> 3] |= @as(u8, 0x80) >> @intCast(self.pos & 7);
            }
            self.pos += 1;
        }
    }

    pub fn writeFlag(self: *BitWriter, flag: bool) void {
        self.writeBits(@intFromBool(flag), 1);
    }
};

test "bit writer and reader round trip" {
    var buf: [16]u8 = @splat(0);
    var w: BitWriter = .init(&buf);
    w.writeBits(0b101, 3);
    w.writeBits(0x7ff, 11);
    w.writeBits(0xdeadbeef, 32);
    w.writeFlag(true);

    var r: BitReader = .init(&buf);
    try std.testing.expectEqual(@as(u32, 0b101), r.readBits(3));
    try std.testing.expectEqual(@as(u32, 0x7ff), r.readBits(11));
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), r.readBits(32));
    try std.testing.expect(r.readFlag());
    try std.testing.expectEqual(@as(usize, 47), r.pos);
}

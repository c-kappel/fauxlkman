//! ID3 tag parsing: song title, artist, album, year and track number.
//!
//! Reads ID3v2.2, v2.3 and v2.4 tags at the start of the file, falling back
//! field by field to an ID3v1 tag in the last 128 bytes. Text in any ID3
//! encoding (Latin-1, UTF-16 with BOM, UTF-16BE, UTF-8) is converted to UTF-8,
//! and control characters are replaced with spaces so tag text is safe to
//! print to a terminal.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tags = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    year: ?[]const u8 = null,
    track: ?[]const u8 = null,

    pub fn deinit(self: Tags, gpa: Allocator) void {
        for ([_]?[]const u8{ self.title, self.artist, self.album_artist, self.album, self.year, self.track }) |field| {
            if (field) |s| gpa.free(s);
        }
    }
};

const Field = enum { title, artist, album_artist, album, year, track };

/// Reads the tags of an MP3 file. Missing or malformed tags yield null fields.
pub fn read(gpa: Allocator, data: []const u8) Allocator.Error!Tags {
    var tags: Tags = .{};
    errdefer tags.deinit(gpa);
    try readV2(gpa, data, &tags);
    try readV1(gpa, data, &tags);
    return tags;
}

fn set(gpa: Allocator, tags: *Tags, field: Field, value: ?[]u8) void {
    const v = value orelse return;
    switch (field) {
        inline else => |f| {
            if (@field(tags, @tagName(f)) == null) @field(tags, @tagName(f)) = v else gpa.free(v);
        },
    }
}

fn syncsafe(b: *const [4]u8) u32 {
    var v: u32 = 0;
    for (b) |x| v = (v << 7) | (x & 0x7f);
    return v;
}

/// Removes the unsynchronisation scheme: every 0xFF 0x00 becomes 0xFF.
fn unsynchronise(gpa: Allocator, b: []const u8) Allocator.Error![]u8 {
    var out = try gpa.alloc(u8, b.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        out[n] = b[i];
        n += 1;
        if (b[i] == 0xff and i + 1 < b.len and b[i + 1] == 0) i += 1;
    }
    return gpa.realloc(out, n);
}

fn frameField(id: []const u8) ?Field {
    const map = [_]struct { []const u8, Field }{
        .{ "TIT2", .title }, .{ "TT2", .title },
        .{ "TPE1", .artist }, .{ "TP1", .artist },
        .{ "TPE2", .album_artist }, .{ "TP2", .album_artist },
        .{ "TALB", .album }, .{ "TAL", .album },
        .{ "TYER", .year }, .{ "TYE", .year }, .{ "TDRC", .year },
        .{ "TRCK", .track }, .{ "TRK", .track },
    };
    for (map) |m| if (std.mem.eql(u8, id, m[0])) return m[1];
    return null;
}

fn readV2(gpa: Allocator, data: []const u8, tags: *Tags) Allocator.Error!void {
    if (data.len < 10 or !std.mem.eql(u8, data[0..3], "ID3")) return;
    const major = data[3];
    const flags = data[5];
    if (major < 2 or major > 4) return;
    // v2.2 used this bit for a compression scheme that was never defined.
    if (major == 2 and flags & 0x40 != 0) return;
    const size = syncsafe(data[6..10]);
    const raw = data[10..@min(data.len, 10 + size)];

    // v2.2/v2.3 unsynchronise the whole tag; v2.4 does it per frame.
    const tag_unsync = flags & 0x80 != 0;
    const body = if (tag_unsync and major < 4) try unsynchronise(gpa, raw) else raw;
    defer if (body.ptr != raw.ptr) gpa.free(body);

    var p: usize = 0;
    if (major >= 3 and flags & 0x40 != 0) {
        if (body.len < 4) return;
        p = if (major == 3) 4 + std.mem.readInt(u32, body[0..4], .big) else syncsafe(body[0..4]);
    }

    const id_len: usize = if (major == 2) 3 else 4;
    const header_len: usize = if (major == 2) 6 else 10;
    while (p + header_len <= body.len) {
        const id = body[p..][0..id_len];
        if (id[0] == 0) break; // padding
        const frame_size: usize = switch (major) {
            2 => std.mem.readInt(u24, body[p + 3 ..][0..3], .big),
            3 => std.mem.readInt(u32, body[p + 4 ..][0..4], .big),
            else => syncsafe(body[p + 4 ..][0..4]),
        };
        const format: u8 = if (major == 2) 0 else body[p + 9];
        p += header_len;
        if (frame_size > body.len - p) break;
        var content = body[p..][0..frame_size];
        p += frame_size;

        const field = frameField(id) orelse continue;
        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);
        if (major == 3) {
            if (format & 0xc0 != 0) continue; // compressed or encrypted
            if (format & 0x20 != 0) content = content[@min(1, content.len)..]; // group id
        } else if (major == 4) {
            if (format & 0x0c != 0) continue; // compressed or encrypted
            if (format & 0x40 != 0) content = content[@min(1, content.len)..]; // group id
            if (format & 0x01 != 0) content = content[@min(4, content.len)..]; // data length
            if (format & 0x02 != 0 or tag_unsync) {
                owned = try unsynchronise(gpa, content);
                content = owned.?;
            }
        }
        set(gpa, tags, field, try decodeText(gpa, content));
    }
}

fn readV1(gpa: Allocator, data: []const u8, tags: *Tags) Allocator.Error!void {
    if (data.len < 128) return;
    const t = data[data.len - 128 ..];
    if (!std.mem.eql(u8, t[0..3], "TAG")) return;
    set(gpa, tags, .title, try latin1(gpa, t[3..33]));
    set(gpa, tags, .artist, try latin1(gpa, t[33..63]));
    set(gpa, tags, .album, try latin1(gpa, t[63..93]));
    set(gpa, tags, .year, try latin1(gpa, t[93..97]));
    // ID3v1.1: a zero byte before the last comment byte marks a track number.
    if (t[125] == 0 and t[126] != 0) set(gpa, tags, .track, try std.fmt.allocPrint(gpa, "{d}", .{t[126]}));
}

/// Decodes an ID3v2 text frame (encoding byte + text) into trimmed UTF-8.
/// Only the first of several null-separated values is kept.
fn decodeText(gpa: Allocator, content: []const u8) Allocator.Error!?[]u8 {
    if (content.len < 1) return null;
    const text = content[1..];
    return switch (content[0]) {
        0 => latin1(gpa, text),
        1, 2 => utf16(gpa, text, content[0] == 2),
        3 => utf8(gpa, text),
        else => null,
    };
}

fn latin1(gpa: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (text[0..end]) |b| {
        var buf: [2]u8 = undefined;
        const n = std.unicode.utf8Encode(b, &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return finish(gpa, out.items);
}

fn utf8(gpa: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    if (!std.unicode.utf8ValidateSlice(text[0..end])) return latin1(gpa, text[0..end]);
    return finish(gpa, text[0..end]);
}

fn utf16(gpa: Allocator, text: []const u8, big_endian_default: bool) Allocator.Error!?[]u8 {
    var b = text;
    var big = big_endian_default;
    if (b.len >= 2 and b[0] == 0xff and b[1] == 0xfe) {
        big = false;
        b = b[2..];
    } else if (b.len >= 2 and b[0] == 0xfe and b[1] == 0xff) {
        big = true;
        b = b[2..];
    }
    const units = try gpa.alloc(u16, b.len / 2);
    defer gpa.free(units);
    var n: usize = 0;
    while (n < units.len) : (n += 1) {
        const u = std.mem.readInt(u16, b[n * 2 ..][0..2], if (big) .big else .little);
        if (u == 0) break;
        units[n] = std.mem.nativeToLittle(u16, u);
    }
    const s = std.unicode.utf16LeToUtf8Alloc(gpa, units[0..n]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null, // unpaired surrogate
    };
    defer gpa.free(s);
    return finish(gpa, s);
}

/// Copies valid UTF-8 `s` with C0/C1 control characters replaced by spaces
/// and whitespace trimmed; returns null if nothing is left.
fn finish(gpa: Allocator, s: []const u8) Allocator.Error!?[]u8 {
    const out = try gpa.dupe(u8, s);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] < 0x20 or out[i] == 0x7f) out[i] = ' ';
        // U+0080..U+009F, encoded as C2 80..C2 9F.
        if (out[i] == 0xc2 and i + 1 < out.len and out[i + 1] >= 0x80 and out[i + 1] <= 0x9f) {
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 1;
        }
    }
    const trimmed = std.mem.trim(u8, out, " ");
    if (trimmed.len == 0) {
        gpa.free(out);
        return null;
    }
    std.mem.copyForwards(u8, out, trimmed);
    return try gpa.realloc(out, trimmed.len);
}

const testing = std.testing;

fn v2Tag(comptime major: u8, comptime flags: u8, comptime frames: []const u8) []const u8 {
    const n = frames.len;
    const size = [4]u8{ (n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f };
    return "ID3" ++ [_]u8{ major, 0, flags } ++ size ++ frames;
}

fn v23Frame(comptime id: *const [4]u8, comptime content: []const u8) []const u8 {
    const n = content.len;
    return id ++ [_]u8{ n >> 24, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, 0, 0 } ++ content;
}

test "ID3v2.3 with Latin-1 and UTF-16 text" {
    const data = comptime v2Tag(3, 0, v23Frame("TIT2", "\x01\xff\xfeH\x00\xe9\x00!\x00") ++
        v23Frame("TPE1", "\x00Bj\xf6rk") ++ v23Frame("TALB", "\x00Post\x00") ++
        v23Frame("TRCK", "\x003/11") ++ "\x00\x00\x00\x00\x00\x00\x00\x00") ++ "\xff\xfb audio";
    const tags = try read(testing.allocator, data);
    defer tags.deinit(testing.allocator);
    try testing.expectEqualStrings("Hé!", tags.title.?);
    try testing.expectEqualStrings("Björk", tags.artist.?);
    try testing.expectEqualStrings("Post", tags.album.?);
    try testing.expectEqualStrings("3/11", tags.track.?);
    try testing.expectEqual(@as(?[]const u8, null), tags.year);
}

test "ID3v2.4 with syncsafe sizes, UTF-8 and per-frame unsynchronisation" {
    const title = "\x03Caf\xc3\xa9";
    const frame1 = "TIT2" ++ [_]u8{ 0, 0, 0, title.len, 0, 0 } ++ title;
    // Unsynchronised UTF-16BE: 0xFF 0x00 in the content stands for 0xFF.
    const art = "\x02\x00A\xff\x00\x00\x00B";
    const frame2 = "TPE1" ++ [_]u8{ 0, 0, 0, art.len, 0, 0x02 } ++ art;
    const year = "\x032024";
    const frame3 = "TDRC" ++ [_]u8{ 0, 0, 0, year.len, 0, 0 } ++ year;
    const tags = try read(testing.allocator, comptime v2Tag(4, 0, frame1 ++ frame2 ++ frame3));
    defer tags.deinit(testing.allocator);
    try testing.expectEqualStrings("Café", tags.title.?);
    try testing.expectEqualStrings("A\u{ff00}B", tags.artist.?);
    try testing.expectEqualStrings("2024", tags.year.?);
}

test "ID3v2.2 three-letter frames" {
    const frame = "TT2" ++ [_]u8{ 0, 0, 6 } ++ "\x00Hello";
    const tags = try read(testing.allocator, comptime v2Tag(2, 0, frame));
    defer tags.deinit(testing.allocator);
    try testing.expectEqualStrings("Hello", tags.title.?);
}

test "ID3v1 fills fields missing from ID3v2" {
    var v1: [128]u8 = @splat(0);
    @memcpy(v1[0..3], "TAG");
    @memcpy(v1[3..][0..9], "Old Title");
    @memcpy(v1[33..][0..10], "Old Artist");
    @memcpy(v1[93..][0..4], "1999");
    v1[126] = 7;
    const prefix = comptime v2Tag(3, 0, v23Frame("TIT2", "\x00New Title")) ++ "audio";
    var data: [prefix.len + v1.len]u8 = undefined;
    @memcpy(data[0..prefix.len], prefix);
    @memcpy(data[prefix.len..], &v1);
    const tags = try read(testing.allocator, &data);
    defer tags.deinit(testing.allocator);
    try testing.expectEqualStrings("New Title", tags.title.?);
    try testing.expectEqualStrings("Old Artist", tags.artist.?);
    try testing.expectEqualStrings("1999", tags.year.?);
    try testing.expectEqualStrings("7", tags.track.?);
    try testing.expectEqual(@as(?[]const u8, null), tags.album);
}

test "control characters are neutralised and junk is ignored" {
    const tags = try read(testing.allocator, comptime v2Tag(3, 0, v23Frame("TIT2", "\x00evil\x1b[2Jtitle")));
    defer tags.deinit(testing.allocator);
    try testing.expectEqualStrings("evil [2Jtitle", tags.title.?);

    // Latin-1 0x9B is the C1 CSI control; album artist does not override artist.
    const c1 = try read(testing.allocator, comptime v2Tag(3, 0, v23Frame("TPE2", "\x00Various") ++ v23Frame("TPE1", "\x00a\x9b2Jb")));
    defer c1.deinit(testing.allocator);
    try testing.expectEqualStrings("a  2Jb", c1.artist.?);
    try testing.expectEqualStrings("Various", c1.album_artist.?);

    // Truncated and oversized frames must not crash.
    const bad = try read(testing.allocator, "ID3\x03\x00\x00\x00\x00\x00\x20TIT2\x7f\xff\xff\xff\x00\x00\x00x");
    defer bad.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), bad.title);
    const none = try read(testing.allocator, "no tags here");
    try testing.expectEqual(@as(?[]const u8, null), none.title);
}

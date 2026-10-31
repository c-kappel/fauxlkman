const std = @import("std");
const mp3 = @import("mp3");

pub const playback = @import("playback.zig");
pub const coreaudio = @import("coreaudio.zig");

/// A song being decoded on a background thread. Its `track` can be handed to
/// a `playback.Engine` immediately: the buffer is allocated for the whole song
/// up front and the engine plays whatever has been decoded so far.
pub const Decoding = struct {
    track: playback.Track,
    buffer: []i16,
    data: []const u8,
    layout: mp3.Layout,
    thread: std.Thread,
    cancel: std.atomic.Value(bool) = .init(false),

    pub const Error = mp3.DecodeError || std.Thread.SpawnError;

    /// Starts decoding `data`, which must stay alive until `deinit`.
    pub fn start(gpa: std.mem.Allocator, data: []const u8) Error!*Decoding {
        const layout = try mp3.scan(data);
        const buffer = try gpa.alloc(i16, layout.frames * layout.channels);
        errdefer gpa.free(buffer);
        const self = try gpa.create(Decoding);
        errdefer gpa.destroy(self);
        self.* = .{
            .track = .init(buffer, layout.channels, layout.sample_rate),
            .buffer = buffer,
            .data = data,
            .layout = layout,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Decoding) void {
        mp3.decodeInto(self.data, self.layout, self.buffer, &self.track.ready, &self.cancel);
    }

    /// Stops decoding if still running and frees the buffer. The track must
    /// no longer be referenced by any engine.
    pub fn deinit(self: *Decoding, gpa: std.mem.Allocator) void {
        self.cancel.store(true, .monotonic);
        self.thread.join();
        gpa.free(self.buffer);
        gpa.destroy(self);
    }
};

pub const Song = struct {
    artist: u32,
    duration: u32,
    timestamp: u32,
    /// Path to the song's MP3 file.
    path: []const u8 = "",
};

pub const Playlist = struct {
    songs: [250]Song,
    latest: u16,
    name: []const u8,
    artist_id: ?u8,

    /// Appends a song after the last one added.
    pub fn addSong(self: *Playlist, song: Song) error{PlaylistFull}!void {
        if (self.latest >= self.songs.len) return error.PlaylistFull;
        self.songs[self.latest] = song;
        self.latest += 1;
    }

    /// The songs added so far, in play order.
    pub fn tracks(self: *const Playlist) []const Song {
        return self.songs[0..self.latest];
    }
};

pub const Artist = struct {
    id: u8,
    name: []const u8,
};

pub fn createPlaylist(name: []const u8) Playlist {
    return Playlist{
        .songs = @splat(Song{ .artist = 0, .duration = 0, .timestamp = 0 }),
        .latest = 0,
        .name = name,
        .artist_id = null,
    };
}

pub fn createAlbum(artist_id: u8, name: []const u8) Playlist {
    return Playlist{
        .songs = @splat(Song{ .artist = 0, .duration = 0, .timestamp = 0 }),
        .latest = 0,
        .name = name,
        .artist_id = artist_id,
    };
}

test {
    _ = playback;
}

test "background decoding fills the track to the same samples as decode" {
    const gpa = std.testing.allocator;
    var pcm: [4410 * 2]i16 = undefined;
    for (&pcm, 0..) |*v, i| v.* = @intFromFloat(8000 * @sin(@as(f32, @floatFromInt(i / 2)) * 0.06));
    const encoded = try mp3.encode(gpa, &pcm, 2, 44100, .{});
    defer gpa.free(encoded);
    const expected = try mp3.decode(gpa, encoded);
    defer gpa.free(expected.samples);

    const d = try Decoding.start(gpa, encoded);
    defer d.deinit(gpa);
    while (d.track.readyFrames() < d.track.totalFrames()) std.atomic.spinLoopHint();

    try std.testing.expectEqual(@as(u8, 2), d.track.channels);
    try std.testing.expectEqualSlices(i16, expected.samples, d.track.samples);
}

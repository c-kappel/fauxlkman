pub const playback = @import("playback.zig");
pub const coreaudio = @import("coreaudio.zig");

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

const Song = struct {
    artist: u32,
    duration: u32,
    timestamp: u32,
};

const Playlist = struct {
    songs: [250]Song,
    latest: u16,
    name: []const u8,
    artist_id: ?u8,
};

const Artist = struct {
    id: u8,
    name: []const u8,
};

pub fn createPlaylist(name: []const u8) Playlist {
    return Playlist{
        .songs = [_]Song{Song{ .artist = 0, .duration = 0, .timestamp = 0 }} ** 250,
        .latest = 0,
        .name = name,
        .artist_id = null,
    };
}

pub fn createAlbum(artist_id: u8, name: []const u8) Playlist {
    return Playlist{
        .songs = [_]Song{Song{ .artist = 0, .duration = 0, .timestamp = 0 }} ** 250,
        .latest = 0,
        .name = name,
        .artist_id = artist_id,
    };
}

const Song = struct {
    artist: u32,
    duration: u32,
    timestamp: u32,
};

const Playlist = struct {
    songs: [250]Song,
};

pub fn createPlaylist(name: []const u8) void {}

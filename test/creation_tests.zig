const std = @import("std");
const player = @import("player");

test "createPlaylist sets the name and defaults the rest" {
    const playlist = player.createPlaylist("Road Trip");

    try std.testing.expectEqualStrings("Road Trip", playlist.name);
    try std.testing.expectEqual(@as(u16, 0), playlist.latest);
    try std.testing.expectEqual(@as(?u8, null), playlist.artist_id);
    try std.testing.expectEqual(@as(usize, 250), playlist.songs.len);
    try std.testing.expectEqual(@as(u32, 0), playlist.songs[0].artist);
}

test "createAlbum sets the name, artist id, and defaults the rest" {
    const album = player.createAlbum(7, "Greatest Hits");

    try std.testing.expectEqualStrings("Greatest Hits", album.name);
    try std.testing.expectEqual(@as(u16, 0), album.latest);
    try std.testing.expectEqual(@as(?u8, 7), album.artist_id);
    try std.testing.expectEqual(@as(usize, 250), album.songs.len);
    try std.testing.expectEqual(@as(u32, 0), album.songs[0].artist);
}

test "addSong appends in order until the playlist is full" {
    var playlist = player.createPlaylist("Queue");
    try playlist.addSong(.{ .artist = 1, .duration = 0, .timestamp = 0, .path = "a.mp3" });
    try playlist.addSong(.{ .artist = 2, .duration = 0, .timestamp = 0, .path = "b.mp3" });

    try std.testing.expectEqual(@as(usize, 2), playlist.tracks().len);
    try std.testing.expectEqualStrings("a.mp3", playlist.tracks()[0].path);
    try std.testing.expectEqualStrings("b.mp3", playlist.tracks()[1].path);

    while (playlist.latest < playlist.songs.len) try playlist.addSong(.{ .artist = 0, .duration = 0, .timestamp = 0 });
    try std.testing.expectError(error.PlaylistFull, playlist.addSong(.{ .artist = 0, .duration = 0, .timestamp = 0 }));
}

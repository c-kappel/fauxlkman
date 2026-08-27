const std = @import("std");
const player = @import("../src/player.zig");

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

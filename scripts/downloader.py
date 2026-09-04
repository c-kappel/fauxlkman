"""HLS audio pipeline: master playlist -> selected audio track -> its media playlist."""

from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass, field


@dataclass
class AudioTrack:
    group_id: str
    name: str
    language: str | None
    uri: str
    is_default: bool
    is_autoselect: bool
    channels: int | None
    characteristics: str | None


def _resolve_uri(base: str, uri: str) -> str:
    """Resolves a playlist-relative URI against its base, supporting both HTTP(S) and local-file bases."""
    if uri.startswith('http://') or uri.startswith('https://'):
        return uri
    if base.startswith('http://') or base.startswith('https://'):
        return urllib.parse.urljoin(base, uri)
    return os.path.join(os.path.dirname(base), uri)


def _parse_attributes(attr_string: str) -> dict[str, str]:
    attrs = {}
    for match in re.finditer(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', attr_string):
        key, value = match.group(1), match.group(2)
        attrs[key] = value.strip('"')
    return attrs


def parse_master_playlist(text: str) -> tuple[list[AudioTrack], dict[str, int]]:
    """Returns (audio tracks, group_id -> highest bandwidth of variants using that group)."""
    tracks = []
    group_bandwidth: dict[str, int] = {}

    for line in text.splitlines():
        line = line.strip()

        if line.startswith('#EXT-X-MEDIA:') and 'TYPE=AUDIO' in line:
            attrs = _parse_attributes(line[len('#EXT-X-MEDIA:'):])
            if 'URI' not in attrs:
                continue
            tracks.append(AudioTrack(
                group_id=attrs.get('GROUP-ID', ''),
                name=attrs.get('NAME', ''),
                language=attrs.get('LANGUAGE'),
                uri=attrs['URI'],
                is_default=attrs.get('DEFAULT') == 'YES',
                is_autoselect=attrs.get('AUTOSELECT') == 'YES',
                channels=int(attrs['CHANNELS']) if attrs.get('CHANNELS', '').isdigit() else None,
                characteristics=attrs.get('CHARACTERISTICS'),
            ))

        elif line.startswith('#EXT-X-STREAM-INF:'):
            attrs = _parse_attributes(line[len('#EXT-X-STREAM-INF:'):])
            audio_group = attrs.get('AUDIO')
            bandwidth = int(attrs['BANDWIDTH']) if attrs.get('BANDWIDTH', '').isdigit() else 0
            if audio_group:
                group_bandwidth[audio_group] = max(group_bandwidth.get(audio_group, 0), bandwidth)

    return tracks, group_bandwidth


def _is_narration_track(track: AudioTrack) -> bool:
    characteristics = (track.characteristics or '').lower()
    name = (track.name or '').lower()
    return (
        'describes-video' in characteristics
        or 'descriptive' in name
        or 'narration' in name
    )


def select_audio_track(
    tracks: list[AudioTrack],
    group_bandwidth: dict[str, int],
    lang: str = 'en',
    exclude_narration: bool = True,
    quality: str = 'highest',
) -> AudioTrack | None:
    candidates = tracks

    if exclude_narration:
        without_narration = [t for t in candidates if not _is_narration_track(t)]
        if without_narration:
            candidates = without_narration

    if lang:
        lang_matches = [t for t in candidates if (t.language or '').lower() == lang.lower()]
        if lang_matches:
            candidates = lang_matches

    if not candidates:
        return None

    def rank(t: AudioTrack) -> tuple[int, int, bool]:
        return (group_bandwidth.get(t.group_id, 0), t.channels or 0, t.is_default)

    candidates.sort(key=rank, reverse=(quality == 'highest'))
    return candidates[0]


@dataclass
class Segment:
    uri: str
    duration: float
    byterange: tuple[int, int] | None  # (length, offset), or None if the segment is a whole file


@dataclass
class MediaPlaylist:
    base_url: str
    is_vod: bool
    target_duration: float | None
    init_segment_uri: str | None
    init_segment_byterange: tuple[int, int] | None
    segments: list[Segment] = field(default_factory=list)


def _parse_byterange(value: str | None, cursor: int) -> tuple[tuple[int, int] | None, int]:
    """Parses an EXT-X-BYTERANGE value ('<length>[@<offset>]'); missing offset means
    contiguous with the previous range, tracked via `cursor`."""
    if not value:
        return None, cursor
    if '@' in value:
        length_str, offset_str = value.split('@', 1)
        length, offset = int(length_str), int(offset_str)
    else:
        length, offset = int(value), cursor
    return (length, offset), offset + length


def parse_media_playlist(text: str, base_url: str) -> MediaPlaylist:
    is_vod = False
    target_duration = None
    init_segment_uri = None
    init_segment_byterange = None
    segments: list[Segment] = []

    cursor = 0
    pending_duration = None
    pending_byterange = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        if line.startswith('#EXT-X-TARGETDURATION:'):
            target_duration = float(line.split(':', 1)[1])

        elif line.startswith('#EXT-X-ENDLIST'):
            is_vod = True

        elif line.startswith('#EXT-X-MAP:'):
            attrs = _parse_attributes(line[len('#EXT-X-MAP:'):])
            if 'URI' in attrs:
                init_segment_uri = _resolve_uri(base_url, attrs['URI'])
                init_segment_byterange, cursor = _parse_byterange(attrs.get('BYTERANGE'), cursor)

        elif line.startswith('#EXT-X-BYTERANGE:'):
            pending_byterange, cursor = _parse_byterange(line[len('#EXT-X-BYTERANGE:'):], cursor)

        elif line.startswith('#EXTINF:'):
            pending_duration = float(line[len('#EXTINF:'):].split(',', 1)[0])

        elif not line.startswith('#'):
            segments.append(Segment(
                uri=_resolve_uri(base_url, line),
                duration=pending_duration or 0.0,
                byterange=pending_byterange,
            ))
            pending_duration = None
            pending_byterange = None

    return MediaPlaylist(
        base_url=base_url,
        is_vod=is_vod,
        target_duration=target_duration,
        init_segment_uri=init_segment_uri,
        init_segment_byterange=init_segment_byterange,
        segments=segments,
    )


def fetch_media_playlist(master_playlist_source: str, track: AudioTrack) -> MediaPlaylist:
    media_playlist_url = _resolve_uri(master_playlist_source, track.uri)
    text = _load_playlist_text(media_playlist_url)
    return parse_media_playlist(text, base_url=media_playlist_url)


def _fetch_bytes(uri: str, byterange: tuple[int, int] | None, retries: int = 3) -> bytes:
    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            if uri.startswith('http://') or uri.startswith('https://'):
                req = urllib.request.Request(uri)
                if byterange:
                    length, offset = byterange
                    req.add_header('Range', f'bytes={offset}-{offset + length - 1}')
                with urllib.request.urlopen(req) as resp:  # noqa: S310
                    data = resp.read()
                    # Some servers ignore Range and return the whole resource with 200;
                    # slice manually rather than silently writing the wrong bytes.
                    if byterange and resp.status != 206:
                        length, offset = byterange
                        data = data[offset:offset + length]
                    return data
            with open(uri, 'rb') as f:
                if byterange:
                    length, offset = byterange
                    f.seek(offset)
                    return f.read(length)
                return f.read()
        except OSError as exc:
            last_error = exc
            if attempt == retries:
                raise
    raise last_error  # unreachable, satisfies type checkers


def download_audio(media: MediaPlaylist, output_path: str) -> str:
    """Fetches the init segment (if any) and every media segment in order, writing the
    raw concatenated bytes to output_path. Valid as-is for fMP4/CMAF audio (init + fragments);
    MPEG-TS segments will need remuxing afterward rather than being played back directly."""
    with open(output_path, 'wb') as out:
        if media.init_segment_uri:
            out.write(_fetch_bytes(media.init_segment_uri, media.init_segment_byterange))
        for segment in media.segments:
            out.write(_fetch_bytes(segment.uri, segment.byterange))
    return output_path


def _load_playlist_text(source: str) -> str:
    if source.startswith('http://') or source.startswith('https://'):
        with urllib.request.urlopen(source) as resp:  # noqa: S310
            return resp.read().decode('utf-8')
    with open(source, encoding='utf-8') as f:
        return f.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Select an audio rendition from an HLS master playlist.')
    parser.add_argument('playlist', help='Path or URL to the master .m3u8 playlist')
    parser.add_argument('--lang', default='en', help='Preferred audio language code (default: en)')
    parser.add_argument('--include-narration', action='store_true',
                         help='Do not exclude descriptive/narration audio tracks')
    parser.add_argument('--quality', choices=['highest', 'lowest'], default='highest',
                         help='Audio quality preference when multiple bitrates are available (default: highest)')
    parser.add_argument('-o', '--output', default='audio.m4a', help='Output file path (default: audio.m4a)')
    args = parser.parse_args(argv)

    text = _load_playlist_text(args.playlist)
    tracks, group_bandwidth = parse_master_playlist(text)

    if not tracks:
        print('No audio tracks found in master playlist.', file=sys.stderr)
        return 1

    selected = select_audio_track(
        tracks, group_bandwidth,
        lang=args.lang,
        exclude_narration=not args.include_narration,
        quality=args.quality,
    )

    if not selected:
        print('No audio track matched the given criteria.', file=sys.stderr)
        return 1

    bandwidth = group_bandwidth.get(selected.group_id)
    print(f'name={selected.name!r} language={selected.language} group={selected.group_id} '
          f'bandwidth={bandwidth} channels={selected.channels} uri={selected.uri}')

    media = fetch_media_playlist(args.playlist, selected)
    print(f'media playlist: {"vod" if media.is_vod else "live"}, '
          f'{len(media.segments)} segments, target_duration={media.target_duration}, '
          f'init_segment={media.init_segment_uri!r}')

    if not media.is_vod:
        print('Refusing to download a live/in-progress playlist; only VOD is supported for now.', file=sys.stderr)
        return 1

    download_audio(media, args.output)
    size = os.path.getsize(args.output)
    print(f'wrote {args.output} ({size} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

### Fauxlkman

A music player in Zig

### Player

```
./zig-out/bin/fauxlkman play song1.mp3 song2.mp3 ...
```

Each song is decoded into memory as interleaved 16-bit PCM (~10 MB per stereo minute at 44.1 kHz). Playback only moves a read position, so rewinding and seeking take effect within one audio buffer, with no decoder state to rebuild.

Decoding runs in the background:

1. `mp3.scan` walks the frame headers without decoding them to get the format and the exact trimmed length, so the song's buffer is allocated once, up front.
2. A thread (`player.Decoding`) fills that buffer with `mp3.decodeInto`, publishing the number of ready frames after each MP3 frame. Playback starts as soon as the first frames are in (about 50 ms after launch). If you seek past what's decoded, playback holds in silence until the decoder catches up.
3. While a song plays, the next one is decoded too and queued in the engine. When the current song ends, the audio thread switches to it in the middle of the same buffer, so there's no gap. A song with a different sample rate or channel count reopens the output instead.

- `src/playback.zig`: `Track` (a song's buffer plus a count of ready frames) and `Engine`. `Engine.render` runs on the audio thread (no allocation or locks). `load`/`enqueue`/`seek`/`rewind`/`togglePause` can be called from any thread and talk to it through atomics. Seeks crossfade and pause/resume ramp over 256 frames to avoid clicks. A track is freed only after two more render calls finish (`renderCount`), once the audio thread can no longer be reading it.
- `src/coreaudio.zig`: macOS output through the default-output AudioUnit (AudioToolbox). The unit pulls f32 frames from the engine at the song's sample rate.
- `src/player.zig`: `Song`/`Playlist` model and the background `Decoding`. `play` queues its arguments as a playlist.

Controls: `space` pause, `←`/`→` ±5 s, `[`/`]` ±30 s, `0`–`9` jump to 0–90%, `r` restart, `p` previous (or restart if more than 3 s in), `n` next, `q` quit.

### Downloader

### MP3 codec

A pure-Zig MP3 (MPEG audio Layer III) decoder and encoder lives in `src/mp3/`.

```
zig build -Doptimize=ReleaseFast
./zig-out/bin/fauxlkman decode in.mp3 out.wav
./zig-out/bin/fauxlkman encode in.wav out.mp3 [--bitrate 192] [--stereo]
./zig-out/bin/fauxlkman info in.mp3
zig build test
```

#### Decoding pipeline

Supports MPEG-1/2/2.5 Layer III, mono/stereo, CBR and VBR. Each frame (1152 samples per channel for MPEG-1, 576 for MPEG-2/2.5) goes through:

1. **Frame sync** (`stream.zig`): skip any ID3v2 tag, then scan for the 11-bit sync word and check that the next frame header also parses. A leading Xing/Info frame is not played; its LAME tag supplies encoder delay/padding for gapless trimming.
2. **Header + side info** (`frame.zig`, `decoder.zig`): bitrate, sample rate, channel mode, then per granule/channel the part2_3 length, big_values, global gain, block type, Huffman table selection and region boundaries.
3. **Bit reservoir**: a frame's main data may start up to 511 bytes back, inside earlier frames. Main data is appended to a reservoir buffer and read from `main_data_begin` bytes before the current frame's data.
4. **Scalefactors**: MPEG-1 (`slen1`/`slen2` with scfsi reuse between granules) or MPEG-2 LSF (`nr_of_sfb` tables).
5. **Huffman decoding**: the big-values region decodes pairs with tables 0–31 (with linbits and sign bits). The count1 region decodes quadruples of values in {-1, 0, 1} with table A or B. Everything past that is zero.
6. **Requantization**: `xr = sign(is) * |is|^(4/3) * 2^(gain/4 - scalefactor terms)`, using per-window subblock gain for short blocks.
7. **Stereo processing**: mid/side → left/right, plus MPEG-1 intensity stereo.
8. **Reorder**: short-block lines go from band/window order into the interleaved order the IMDCT expects.
9. **Alias reduction**: 8 butterflies across each subband boundary (none for pure short blocks).
10. **IMDCT + overlap-add** (`filterbank.zig`): an 18→36-point transform per subband (or three 6→12-point transforms for short blocks), windowed by block type and overlap-added with the previous granule.
11. **Frequency inversion**: negate odd time samples in odd subbands.
12. **Polyphase synthesis**: a 32-band filterbank (512-tap window D[i]) turns subband samples into PCM, which is clamped to 16-bit.

#### Encoding pipeline

Outputs MPEG-1 Layer III CBR at 32/44.1/48 kHz, 32–320 kbit/s, from 16-bit PCM WAV. The encoder runs the decoder's steps in reverse:

1. **Polyphase analysis** (`filterbank.zig`): a 32-band filterbank (window C[i] = D[i] / 32) splits each 576-sample granule into 32 subbands × 18 samples. Odd samples of odd subbands are negated to cancel the decoder's frequency inversion.
2. **MDCT**: the previous and current 18 subband samples (36 total) are windowed with the long sine window and transformed into 18 spectral lines per subband. Long blocks only.
3. **Alias reduction**: the inverse of the decoder's butterflies.
4. **Lowpass**: spectral lines above a bitrate-dependent cutoff (e.g. ~16 kHz at 128k stereo) are zeroed.
5. **Mid/side** (default for stereo): `M = (L+R)/√2`, `S = (L−R)/√2`. Use `--stereo` for independent channels.
6. **Quantization**: binary search for the smallest global gain whose coded size fits the frame. `ix = nint((|xr| / step)^(3/4) − 0.0946)`. One step size is shared by all granules and channels, which spreads quantization noise evenly (minimum mean-squared error for the bit budget). There are no scalefactors and no psychoacoustic model.
7. **Huffman coding**: the spectrum is split into big-values / count1 / zero regions, big-values are split into three sub-regions, and the cheapest table is picked for each region. Encoder code tables are built at compile time from the same trees the decoder uses.
8. **Bitstream**: header, side info and main data are written. There is no bit reservoir (`main_data_begin = 0`); padding bits keep the average bitrate exact.

The encoder delays audio by 1057 samples (481 filterbank + 576 MDCT), and no Info/LAME tag is written, so encoded files start with that much extra silence.

Standard tables (Huffman trees, synthesis window) in `src/mp3/tables_data.zig` were generated from [PDMP3](https://github.com/technosaurus/PDMP3) (public domain).

# FFmpeg Codec Interoperability Testing

## Purpose

The codec matrix publishes short synthetic streams from the installed FFmpeg
CLI into a real `TRtmpServer`. It distinguishes four separate outcomes:

- `PASS`: FFmpeg published the stream, TRTMP ingested media packets, the wire
  header used the expected legacy codec ID or enhanced FourCC, and TRTMP
  classified codec configuration/keyframes correctly.
- `PARTIAL`: transport and wire signaling worked, but TRTMP classification was
  incomplete.
- `FAIL`: an available publisher failed or TRTMP did not receive the expected
  media/signaling.
- `SKIP`: the installed FFmpeg lacks the encoder or its RTMP publisher does not
  implement that FourCC.

The matrix validates ingest and packet-level interpretation. It does not claim
that the optional FFmpeg-backed preview decoder supports every listed codec.
The enhanced tag classifier covers single-track FourCC layouts, all three
Multitrack layouts, and chained ModEx headers. It exposes bounded per-track
payload slices, rejects duplicate track IDs and truncated/oversized layouts,
and retains timestamp-nanosecond modifiers. Relay and buffering
preserve the original media payload byte-for-byte.

The optional FFmpeg decoder currently handles legacy AVC/AAC plus Enhanced
RTMP HEVC, AV1, VP9, Opus, FLAC, AC-3, and E-AC-3. VP8 remains packet-level
only because the installed FFmpeg publisher cannot produce `vp08` RTMP.

## Run

From the repository root:

```bash
bash Tests/ffmpeg-codec-matrix.sh
```

Use strict mode as the regression gate. It also fails on `PARTIAL` results:

```bash
bash Tests/ffmpeg-codec-matrix.sh --strict
```

Useful focused runs:

```bash
bash Tests/ffmpeg-codec-matrix.sh --tier 1 --strict
bash Tests/ffmpeg-codec-matrix.sh --tier 2 --strict
bash Tests/ffmpeg-codec-matrix.sh --keep-logs
```

The runner builds `Examples/RtmpCodecInteropProbe.pas`, starts it on localhost,
and publishes one stream per available codec. The default port is 1940 and can
be changed with `--port` or `PORT`. Run `--help` for all overrides.

## Covered Matrix

| Tier | Media | Codec | Expected signaling |
|---|---|---|---|
| 1 | Video | H.264/AVC | Legacy CodecID 7 |
| 1 | Audio | AAC | Legacy SoundFormat 10 |
| 1 | Audio | MP3 | Legacy SoundFormat 2 |
| 2 | Video | HEVC/H.265 | `hvc1` |
| 2 | Video | AV1 | `av01` |
| 2 | Video | VP9 | `vp09` |
| 2 | Video | VP8 | `vp08` |
| 2 | Audio | Opus | `Opus` |
| 2 | Audio | FLAC | `fLaC` |
| 2 | Audio | AC-3 | `ac-3` |
| 2 | Audio | E-AC-3 | `ec-3` |

## Baseline: FFmpeg 8.1.2

With `libx264`, `libx265`, `libvpx`, `libsvtav1`, `libmp3lame`, and `libopus`
enabled, strict mode passes all requested codecs except VP8. FFmpeg 8.1.2
rejects `vp08` in its RTMP protocol before connecting, despite having the
`libvpx` VP8 encoder. The runner records this as a publisher-side `SKIP`.

The first baseline run exposed AMF0 strict-array marker `$0A` as the common
Enhanced RTMP connection blocker. FFmpeg uses a strict array for its enhanced
codec capability advertisement. `TRTMP.RTMP.Protocol.AMF0` now decodes/encodes that type with a
declared-count guard, allowing enhanced publishers to complete `connect`.

## Deterministic Smokes

The normal smoke suite includes tests that do not depend on an installed
FFmpeg CLI or local sockets:

- `RtmpAmf0Smoke`: strict-array round trip, malformed-count rejection, and
  bounded integral `capsEx` parsing.
- `RtmpFlvSmoke`: enhanced audio/video headers, Multitrack layouts, chained
  ModEx, per-track payload slices, composition time, and malformed guards.
- `RtmpAnalyzerEnhancedSmoke`: enhanced codec names plus Multitrack, ModEx, and
  timestamp-nanosecond metrics.
- `RtmpClientSmoke`: bidirectional `$0F` `capsEx` handshake plus packet-exact
  Multitrack and ModEx relay over a real loopback RTMP connection.
- `RtmpDecoderSmoke`: real AVC/AAC frames wrapped in Multitrack envelopes,
  including automatic track-zero selection, explicit video/audio track IDs,
  bounded slices, independent decoder state, and missing/range guards.

Run them together with the rest of the project:

```bash
bash smoke-test.sh
```

## Enhanced Decode And Preview Smokes

Two live tests cover the optional FFmpeg-backed layer:

```bash
bash Tests/ffmpeg-enhanced-decode-smoke.sh
bash Tests/ffmpeg-enhanced-preview-smoke.sh
```

The decoder test publishes separate `hvc1`, `av01`, `vp09`, `Opus`, `fLaC`,
`ac-3`, and `ec-3` streams. It requires decoded 320x180 HEVC/AV1/VP9 video plus
48 kHz stereo output for every audio codec, and exercises Enhanced RTMP
metadata, multichannel configuration, and empty shutdown-frame handling.

The installed FFmpeg 8.1.2 RTMP/FLV muxer has no Multitrack output option, so
live validation remains single-track. Multitrack decode is instead covered by
deterministic envelopes containing the same real AVC/AAC fixtures used by the
legacy decoder smoke.

The preview test publishes HEVC, AV1, and VP9 through isolated `TRtmpPreview`
sessions and requires at least one 320x180 RGBA frame from each, covering
ingest, queueing, decode, and frame conversion. Both runners require `libx265`,
`libsvtav1`, and `libvpx-vp9`; the decoder runner also requires `libopus` and
the native FFmpeg FLAC/AC-3/E-AC-3 encoders. Their default base ports are 1960
and 1961 respectively, and `--help` lists the available overrides.

The preview runner configures `libvpx-vp9` for real-time, zero-lag output.
Without that setting, libvpx may buffer the complete short fixture until the
publisher disconnects, which does not model a live preview source.

## Relay Matrix

The relay matrix starts a fresh two-hop topology for every codec:

```text
FFmpeg publisher -> TRtmpServer -> TRtmpClient -> TRtmpServer verifier
```

Run it with:

```bash
bash Tests/ffmpeg-relay-matrix.sh
```

For each case it verifies:

- the downstream `connect` command contains the configured `fourCcLive` strict
  array;
- client and server exchange their configured integral `capsEx` values;
- source and downstream signaling, FourCC, codec configuration, and keyframe
  flags agree;
- packet count and payload-byte count agree;
- an ordered FNV-1a digest over RTMP message type, timestamp, payload length,
  and payload bytes agrees.

The FFmpeg 8.1.2 baseline passes the same ten codecs as the ingest matrix, with
VP8 skipped because the publisher rejects `vp08` before connecting.

`TRtmpClientConfig.EnhancedCodecs` controls the advertised comma-separated
FourCC list. Its default is `RTMP_DEFAULT_ENHANCED_CODECS`; setting it to an
empty string disables `fourCcLive` advertisement.

`TRtmpClientConfig.EnhancedCapabilities` controls `capsEx`; its default is
`RTMP_DEFAULT_ENHANCED_CAPABILITIES` (`$0F`, Reconnect Request, Multitrack,
ModEx, and timestamp nanosecond offsets), and zero disables advertisement. The server has the
equivalent config field and echoes its own supported value in the connect
`_result`.

## External Receiver Smoke

An additional boundary smoke uses FFmpeg itself as the downstream RTMP server
and demuxer:

```bash
bash Tests/ffmpeg-external-relay-smoke.sh
```

It covers representative legacy video (H.264), enhanced video (HEVC), and
enhanced audio (Opus). FFmpeg must identify and stream-copy each relayed codec
after accepting the `TRtmpClient` publish session.

## Enhanced Reconnect Bootstrap

`RtmpClientReconnectLiveEdgeSmoke` uses classifier-produced enhanced HEVC
packets. It verifies that both the initial session and a reconnect receive the
retained `hvc1` sequence header before the first coded keyframe, and that the
reconnect resumes from the newest keyframe rather than stale outage traffic.

## RTMPS Integration

The TLS integration fixture combines the real codec and cryptographic paths:

```bash
bash Tests/ffmpeg-rtmps-integration.sh
```

It generates a temporary CA/server identity and verifies:

- FFmpeg publishes H.264/AAC into a TLS-enabled `TRtmpServer` with CA and IP
  verification enabled;
- FFmpeg rejects the same endpoint when configured with an unrelated CA;
- `TRtmpClient` publishes to a second TLS-enabled `TRtmpServer` with peer
  verification enabled;
- source and relayed packet counts, byte counts, and ordered payload digests
  are identical.

## Sustained Ingest

`Tests/ffmpeg-ingest-soak.sh` publishes real-time H.264/AAC and samples the
server process RSS throughout the run. It fails on server/publisher exit,
missing media, or RSS growth beyond `MAX_RSS_GROWTH_KB`.

```bash
bash Tests/ffmpeg-ingest-soak.sh
DURATION=300 MAX_RSS_GROWTH_KB=131072 \
  bash Tests/ffmpeg-ingest-soak.sh
```

The default duration is 60 seconds. Longer release-candidate runs can use the
same deterministic harness without changing the repository.

# Interop Notes

## Verified Paths

### OBS -> TRTMP ingest

- publish workflow is working end-to-end
- metadata, AAC config, AVC config, audio packets, and video packets are accepted
- this path previously exposed reassembly/backpressure bugs, which were fixed and retested

### FFmpeg -> TRTMP ingest

- local `ffmpeg` publish works against the ingest server
- the server sends RTMP peer-control defaults immediately after handshake so
  `ffmpeg` does not stall waiting for them
- FFmpeg 8.1.2 strict live-matrix coverage passes H.264, AAC, MP3, HEVC, AV1,
  VP9, Opus, FLAC, AC-3, and E-AC-3 ingest and packet classification
- VP8 remains unexercised because FFmpeg 8.1.2 rejects `vp08` in its RTMP
  publisher before connecting
- enhanced `connect` capability arrays are accepted through AMF0 strict-array
  support
- Enhanced RTMP `capsEx` is parsed as a bounded integral AMF number; malformed,
  fractional, negative, and overflowing values are ignored safely

### TRTMP -> nginx-rtmp

- restream publish works
- downstream playback was confirmed

### TRTMP -> Enhanced RTMP targets

- `TRtmpClient` advertises a configurable `fourCcLive` strict array
- clients and servers advertise configurable `capsEx` flags and retain the
  peer flags; the default `$0F` declares Reconnect Request, Multitrack, ModEx,
  and nanosecond timestamp support
- the two-hop FFmpeg relay matrix passes H.264, AAC, MP3, HEVC, AV1, VP9,
  Opus, FLAC, AC-3, and E-AC-3 with identical packet counts, byte counts,
  timestamps, and ordered payload digests
- FFmpeg 8.1.2 acting as an external downstream RTMP server successfully
  identifies relayed H.264, HEVC, and Opus streams
- enhanced HEVC reconnect bootstrap sends the retained `hvc1` sequence header
  and resumes from the newest retained keyframe
- `NetConnection.Connect.ReconnectRequest` is validated at the connection
  level, supports absolute and relative `tcUrl` redirects, cuts over before the
  next non-config video keyframe, and reconnects without failure backoff;
  server sessions can queue the same request with `RequestReconnect`
- deterministic and loopback smokes preserve Multitrack and ModEx packets
  byte-for-byte while exposing their track/modifier metadata to the analyzer

### Hardened ingest path

- server smokes cover invalid command ordering, teardown commands, malformed
  chunk sequences, extended timestamps, oversized chunk-size changes, oversized
  declared message sizes, and excessive chunk-stream state creation
- constrained-buffer smokes verify that live eviction pressure is surfaced in
  warnings and stats instead of remaining silent

### Win64 preview path

- live preview works with real OBS ingest
- the validated path is: ingest -> decode -> frame conversion -> PasSFML render
- Delphi 37 compile checks cover the Enhanced RTMP decoder and preview probes

### Enhanced decode and preview

- FFmpeg 8.1.2 `hvc1`, `av01`, and `vp09` sequence headers and coded frames
  decode as HEVC, AV1, and VP9
- FFmpeg 8.1.2 `Opus` sequence headers and coded frames decode as 48 kHz stereo
- FFmpeg 8.1.2 `fLaC`, `ac-3`, and `ec-3` streams decode as 48 kHz stereo
- empty Enhanced audio coded-frame envelopes emitted at shutdown are accepted
  as no-op control data
- Enhanced metadata and multichannel-configuration packets are accepted as
  stream control data rather than submitted as compressed frames
- ModEx-wrapped single-track coded frames use their unwrapped payload offsets;
  Multitrack decoding selects bounded per-track slices without submitting
  neighboring track bytes to FFmpeg
- `TRtmpFFmpegPacketDecoder.TrackID=-1` prefers track 0 and otherwise the first
  track; an explicit `0..255` ID never falls back to a different track
- applications decode tracks independently by assigning one decoder instance
  per desired track; decoded frame metadata reports the active track ID
- deterministic fixtures decode two `avc1` video tracks and an explicit `mp4a`
  audio track; the installed FFmpeg muxer cannot currently publish Multitrack
  RTMP for an equivalent live-wire test
- the headless preview path converts decoded HEVC, AV1, and VP9 frames to RGBA
  and reports the expected dimensions

## Relay Policy

### Reconnect bootstrap

- reconnect resumes from the latest retained keyframe window
- this intentionally avoids replaying stale pre-outage backlog
- regression coverage exists in `Examples/RtmpClientReconnectLiveEdgeSmoke.pas`

### Timestamp modes

- pass-through
- rebased
- smoothed

These are implemented for relay behavior and already covered by smoke tests.

## Diagnostics Notes

### Log filtering

- visible log filtering does not disable internal publish/session events
- stats and event hooks remain active even when normal output is suppressed

### Error buckets

Current stats distinguish:

- protocol failures
- transport failures
- session failures

### Latency-oriented counters

Current server stats expose:

- last packet idle time
- current media timeline lag
- maximum observed timeline lag

Timeline lag is calculated as wall-clock arrival elapsed minus media timestamp
elapsed since the first packet in the current publish. Positive values mean
packets are arriving slower than their media timeline; negative values mean the
media timeline is advancing faster than wall-clock arrival time. These are ingest
diagnostics, not end-to-end player latency claims.

## Known Limits

### Target coverage

Real-world coverage is still narrower than the protocol surface:

- OBS publish
- `ffmpeg` publish
- nginx-rtmp target

More targets still need explicit validation before claiming broad interop.

The latest protocol hardening has automated coverage, but OBS/Windows and
additional target testing should be repeated before a release claim.

### Twitch / VOD-track behavior

Current OBS source and deterministic fixtures establish the OBS 30.2+ layout:
live AAC is track 0 and the VOD/archive encoder is emitted as Enhanced audio
TrackID 1. Codec headers are retained per track and survive packet-exact relay
startup/reconnect. `TRtmpClientConfig.RequiredAudioTrackID=1` (or gateway
`require_twitch_vod_audio=true`) prevents silent fallback when either track-zero
or track-one configuration is missing.

See [Twitch VOD Audio Relay](twitch-vod-audio-relay.md). Actual Twitch ingest
and VOD playback still need credentialed validation before a production claim.

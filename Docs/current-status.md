# Current Status

## Summary

TRTMP is beyond concept stage. The repository contains a usable native RTMP
ingest/relay stack with optional decode and preview layers on top.

## Proven Working

- RTMP ingest from OBS
- RTMP ingest from `ffmpeg`
- restream from `TRtmpClient` into nginx-rtmp
- playback verification of the restreamed output
- Win64 Delphi compile validation for the main runners
- live Win64 preview validation: OBS -> TRTMP ingest -> FFmpeg decode -> PasSFML render
- automated hardening smokes for malformed command flow, chunk reassembly,
  message-size caps, chunk-stream caps, and constrained buffer budgets
- FFmpeg-driven codec matrix for legacy H.264/AAC/MP3 and Enhanced RTMP FourCC
  signaling
- Enhanced RTMP packet classification for HEVC, AV1, VP9, VP8, Opus, FLAC,
  AC-3, and E-AC-3
- AMF0 strict-array support required by FFmpeg enhanced codec advertisement
- configurable `TRtmpClient` `fourCcLive` capability advertisement
- bidirectional Enhanced RTMP `capsEx` negotiation with strict AMF number
  validation; Reconnect Request, Multitrack, ModEx, and nanosecond offsets are
  advertised by default
- Enhanced RTMP reconnect-request emission and relay handling with relative or
  absolute redirects, keyframe-boundary cutover, bounded wait, immediate
  reconnect, and live-edge bootstrap
- Enhanced RTMP Multitrack and ModEx header interpretation, including
  per-track bounds/duplicate checks and timestamp-nanosecond modifiers
- selected-track FFmpeg decoding with independent decoder instances, automatic
  track-zero preference, explicit track IDs, and enhanced `avc1`/`mp4a` mapping
- exact ModEx nanosecond PTS propagation through decode and preview
- per-track codec-header retention and required-track enforcement for modern
  OBS/Twitch VOD audio relay
- packet-exact Enhanced RTMP relay matrix with timestamp/payload digests
- external FFmpeg receiver validation for H.264, HEVC, and Opus relay
- enhanced HEVC reconnect bootstrap at the newest retained keyframe
- optional FFmpeg decoding of Enhanced RTMP HEVC, AV1, VP9, Opus, FLAC, AC-3,
  and E-AC-3, validated with live synthetic publishers
- headless HEVC/AV1/VP9 preview validation through decode and RGBA conversion

## Core Runtime Coverage

- handshake and chunk parsing
- AMF0 command flow
- publish-session handling
- bounded packet buffering
- reconnect and relay bootstrap
- packet-level analyzer stats
- low-latency preview queue/drop policy
- protocol safety limits for session count, chunk size, message size, and
  chunk-stream state count
- live buffer-pressure warnings and eviction counters
- deterministic ingest timeline-lag coverage
- Delphi-friendly config constructors and fluent setup helpers
- protocol-aware `TRTMP.RTMP.*` unit namespaces with shared `Core`, `Transport`,
  and `FFmpeg` branches reserved for cross-protocol infrastructure
- repository-wide code-style normalization plus an automated style check in
  the smoke matrix
- optional thread-safe server authorization boundary for connect and publish,
  including query-token helpers and fail-closed exception handling
- built-in Windows Schannel and Unix system-OpenSSL `rtmps://` transports,
  certificate-backed loopback tests, secure URL defaults, verification/SNI
  policy inputs, and downgrade prevention
- verified FFmpeg-to-TRTMP RTMPS ingest and packet-exact TRTMP RTMPS relay,
  including untrusted-certificate and hostname-rejection coverage
- configurable real-time FFmpeg ingest/RSS soak harness
- verified five-minute FFmpeg H.264/AAC ingest soak with 1,668 KiB peak RSS
  growth on the 2026-08-01 release-preparation run

## Current Strengths

- The ingest and relay path is materially usable.
- The stats/logging surface is good enough for live troubleshooting.
- The main protocol-hardening guardrails are now implemented and covered by
  targeted smokes.
- The optional preview path is reusable instead of being locked into one demo.
- The decoder and preview layers remain optional and outside the core RTMP path.
- The public API is easier to consume from Delphi applications without hiding
  the lower-level extension points.

## Main Remaining Gaps

- broader interop validation against more RTMP targets
- higher-level simultaneous routing/mixing of multiple decoded tracks
- renewed OBS/Windows runtime validation after the latest hardening changes
- optional preview dependencies remain user-supplied in the ignored
  `ThirdParty/` tree
- Schannel custom trust roots and server-side mutual TLS
- actual Twitch ingest/VOD acceptance validation with credentials

VP8 is intentionally not a current implementation priority. Its packet-level
FourCC remains recognized, but decode/preview and live-publisher validation are
deferred.

## Recommended Entry Points

- [Gateway Console](../Examples/RtmpGatewayConsole.pas)
- [Gateway Config](../Examples/RtmpGatewayConsole.ini)
- [Implementation Design](implementation-design.md)
- [Interop Notes](interop-notes.md)
- [API Ergonomics Notes](api-ergonomics.md)
- [Production-Readiness Checklist](production-readiness-checklist.md)
- [TODO](TODO.md)
- [Postponed Live Validation](postponed-live-validation.md)

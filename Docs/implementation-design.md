# RTMP Framework Implementation Design

## Scope

TRTMP is designed as a Delphi-first RTMP framework with practical FPC support.
The core stays native Pascal and packet-oriented. Optional decode/render layers
are allowed, but they are not part of the mandatory ingest/relay runtime path.

## Compiler Strategy

- Primary target: Delphi on Windows
- Compatibility target: FPC 3.2.x in Delphi mode
- Practical rule: use conservative Pascal patterns that behave consistently in both

## Project Layout

```text
Docs/
  current-status.md
  api-ergonomics.md
  implementation-design.md
  interop-notes.md
  production-readiness-checklist.md
  TODO.md

Examples/
  runnable consoles
  preview demos
  smoke tests
  helper scripts

Source/
  core RTMP units
  optional decode units
  optional preview units
```

Supporting external trees:

- `ThirdParty/TRadioPlayer/Headers` for FFmpeg Pascal headers and Linux helper units
- `ThirdParty/PasSFML/Source` for optional rendering

## Core Units

### `RtmpCompat`

- compiler/runtime bridge helpers
- timing helpers
- conditional portability shims

### `RtmpTypes`

- message types
- flags
- configs
- immutable stat snapshots

### `RtmpBytes`

- endian-safe RTMP/AMF binary helpers
- 24-bit integer support
- writer helpers for hot-path serialization

### `RtmpAmf0`

- minimal AMF0 value model
- command/data encode/decode helpers

### `RtmpCommand`

- parsed command helpers for `connect`, `createStream`, `publish`,
  `releaseStream`, and `FCPublish`

### `RtmpTransport` / `RtmpTransportNative`

- replaceable transport boundary
- native socket backend for Windows/Unix-style environments

### `RtmpPacket`

- normalized RTMP message/media packet object
- shared payload ownership

### `RtmpBuffer`

- bounded ring buffer
- packet, byte, and window limits
- retained metadata/audio-config/video-config/keyframe bootstrap state

### `RtmpStats`

- cumulative and live counters
- warning/error classification
- ingest-oriented latency diagnostics

### `RtmpAnalyzer`

- packet-level inspection
- bitrate, FPS, jitter, drift
- AAC/AVC config parsing for real stream properties

### `RtmpProtocol`

- handshake helpers
- chunk header parse/write logic
- message type mapping

### `RtmpChunkReassembler`

- inbound chunk-stream state
- full message reconstruction
- truncated/invalid-sequence handling

### `RtmpFlv`

- FLV tag interpretation
- audio/video/config/keyframe classification

### `RtmpServerSession` / `RtmpServer`

- ingest workflow
- session lifecycle
- command validation
- packet dispatch
- server-side stats/logging

### `RtmpClient`

- outbound RTMP publish
- reconnect/backoff
- bootstrap replay
- relay timestamp modes

## Optional Decode / Preview Layer

These units are opt-in and intentionally separated from the core RTMP path:

- `RtmpDecoder`
- `RtmpFFmpeg`
- `RtmpFFmpegApi`
- `RtmpDecoderFFmpeg`
- `RtmpFrameConvertFFmpeg`
- `RtmpPreview`
- `RtmpPreviewSfml`

Design rules:

- ingest and relay must work without them
- decode is driven from RTMP codec-config packets plus subsequent media packets
- preview has its own bounded queue and drop policy
- rendering remains a consumer concern, not a server concern

## Main Design Principles

- native Pascal first
- packet immutability after normalization
- low-copy hot path where practical
- analyzer optionality
- clean separation between transport, protocol, buffering, analysis, and relay
- Delphi-first API shape without abandoning FPC compatibility

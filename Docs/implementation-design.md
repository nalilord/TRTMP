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

All units follow the protocol-aware namespace policy documented in
[Unit Namespaces](unit-namespaces.md).

### `TRTMP.Core.Compat`

- compiler/runtime bridge helpers
- timing helpers
- conditional portability shims

### `TRTMP.RTMP.Types`

- message types
- flags
- configs
- immutable stat snapshots

### `TRTMP.Core.Bytes`

- endian-safe RTMP/AMF binary helpers
- 24-bit integer support
- writer helpers for hot-path serialization

### `TRTMP.RTMP.Protocol.AMF0`

- minimal AMF0 value model
- command/data encode/decode helpers

### `TRTMP.RTMP.Protocol.Command`

- parsed command helpers for `connect`, `createStream`, `publish`,
  `releaseStream`, and `FCPublish`

### `TRTMP.Transport` / `TRTMP.Transport.Native`

- replaceable transport boundary
- native socket backend for Windows/Unix-style environments

### `TRTMP.Transport.TLS` / `TRTMP.Transport.Platform`

- provider-neutral TLS client/listener options
- certificate, CA, SNI, peer-verification, and minimum-version policy
- automatic Schannel selection on Windows and system OpenSSL selection on Unix
- secure transport dispatch without coupling the RTMP protocol units to a TLS
  implementation

### `TRTMP.Transport.TLS.SChannel`

- native Windows Schannel/SSPI transport without third-party DLLs
- PFX/P12 server and optional client identities
- Windows trust-store validation and TLS 1.2/1.3 policy

### `TRTMP.Transport.TLS.OpenSSL`

- dynamically loaded system OpenSSL transport for Unix
- PEM identities, encrypted PEM keys, system/custom trust, SNI, and hostname/IP
  validation
- optional client certificates and server-side mutual TLS

### `TRTMP.RTMP.Media.Packet`

- normalized RTMP message/media packet object
- shared payload ownership

### `TRTMP.RTMP.Media.Buffer`

- bounded ring buffer
- packet, byte, and window limits
- retained metadata/audio-config/video-config/keyframe bootstrap state

### `TRTMP.RTMP.Media.Stats`

- cumulative and live counters
- warning/error classification
- ingest-oriented latency diagnostics

### `TRTMP.RTMP.Media.Analyzer`

- packet-level inspection
- bitrate, FPS, jitter, drift
- AAC/AVC config parsing for real stream properties

### `TRTMP.RTMP.Protocol.Core`

- handshake helpers
- chunk header parse/write logic
- message type mapping

### `TRTMP.RTMP.Protocol.Chunk`

- inbound chunk-stream state
- full message reconstruction
- truncated/invalid-sequence handling

### `TRTMP.RTMP.Protocol.FLV`

- FLV tag interpretation
- audio/video/config/keyframe classification

### `TRTMP.RTMP.Server.Session` / `TRTMP.RTMP.Server`

- ingest workflow
- session lifecycle
- command validation
- packet dispatch
- server-side stats/logging

### `TRTMP.RTMP.Client`

- outbound RTMP publish
- reconnect/backoff
- bootstrap replay
- relay timestamp modes

### `TRTMP.RTMP.Auth`

- application-supplied connect and publish authorization policy
- normalized peer/app/stream contexts
- fail-closed decisions and query-parameter helpers

## Optional Decode / Preview Layer

These units are opt-in and intentionally separated from the core RTMP path:

- `TRTMP.RTMP.Decode`
- `TRTMP.FFmpeg`
- `TRTMP.FFmpeg.API`
- `TRTMP.RTMP.Decode.FFmpeg`
- `TRTMP.FFmpeg.FrameConvert`
- `TRTMP.RTMP.Preview`
- `TRTMP.RTMP.Preview.SFML`

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

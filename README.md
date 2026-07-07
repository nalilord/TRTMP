# TRTMP

TRTMP is a native RTMP framework for Delphi and Free Pascal focused on low-latency
ingest, packet-level analysis, bounded buffering, restreaming, and optional live
preview. The core stays packet-first: RTMP handshake, chunk parsing, AMF command
handling, FLV packet normalization, buffering, and relay are implemented in
Pascal without requiring FFmpeg.

Optional decode and preview layers sit on top of that core. They are used for
live display and diagnostics, not as part of the mandatory ingest/relay hot path.

## Goals

- Accept RTMP publish sessions from tools such as OBS and `ffmpeg`.
- Inspect and normalize incoming media/data traffic at packet level.
- Buffer packets safely for relay, reconnect bootstrap, and live switching.
- Publish the buffered or live stream to downstream RTMP targets.
- Expose Delphi-friendly classes, configs, events, and stats.
- Keep the core compiler-friendly for both Delphi and FPC.

## Non-goals

- No transcoding pipeline in the core.
- No mandatory FFmpeg dependency for ingest or relay.
- No requirement to decode audio/video just to move the stream.

## Architecture

The project is split into a few clear layers:

- `Source/`
  Core RTMP implementation: transport abstraction, protocol handling, packet model,
  buffering, analysis, relay, optional decode/preview units.
- `Examples/`
  Runnable consoles, smoke tests, preview demos, and helper scripts.
- `Docs/`
  Design notes, interop notes, status tracking, and the working TODO list.

The main runtime pieces are:

- `TRtmpServer`
  Ingest server with publish-session handling and stats.
- `TRtmpClient`
  RTMP publish client for relay/restream use.
- `TRtmpBuffer`
  Bounded packet ring with retained metadata/config/keyframe bootstrap state.
- `TRtmpAnalyzer`
  Packet-level metrics and codec-config inspection.
- `TRtmpPreview`
  Optional decode/callback preview core.
- `TRtmpPreviewSfml`
  Optional PasSFML renderer on top of `TRtmpPreview`.

## Current Capability

Implemented and verified:

- RTMP ingest server for OBS and `ffmpeg`
- RTMP restream client with reconnect/backoff
- packet-level analyzer snapshots
- bounded shared packet buffer with bootstrap retention
- ingest hardening limits for sessions, chunk size, message size, and
  chunk-stream state count
- live buffer-pressure warnings and eviction counters
- Delphi-friendly config constructors and fluent config helpers
- configurable relay timestamp modes
- optional FFmpeg-backed decode path
- optional live preview path through PasSFML

Real-world validation already performed:

- OBS publish into the ingest server
- `ffmpeg` publish into the ingest server
- restream into nginx-rtmp with playback confirmation
- Win64 Delphi live preview from OBS ingest

## Repository Layout

```text
Bin/
Docs/
Examples/
Source/
ThirdParty/
build-delphi.sh
build-fpc.sh
smoke-test.sh
```

Notes:

- `ThirdParty/PasSFML/` and `ThirdParty/TRadioPlayer/` are supporting vendor trees
  used for optional preview and FFmpeg header integration.
- `ThirdParty/` is reserved for locally built support libraries such as Linux
  CSFML/SFML artifacts.

## Build

FPC:

```bash
./build-fpc.sh Examples/RtmpGatewayConsole.pas
```

Delphi Win64:

```bash
./build-delphi.sh Examples/RtmpGatewayConsole.pas Win64
```

Optional FFmpeg/preview builds:

```bash
./build-fpc.sh Examples/RtmpDecoderSmoke.pas --with-ffmpeg
./build-fpc.sh Examples/RtmpPreviewCallbackConsole.pas --with-ffmpeg

./build-delphi.sh Examples/RtmpPreviewCallbackConsole.pas Win64 --with-ffmpeg
./build-delphi.sh Examples/RtmpLivePreview.pas Win64 --with-ffmpeg --with-sfml
```

## Automated Verification

Run the release smoke matrix with:

```bash
bash smoke-test.sh
```

If the current environment blocks local socket tests:

```bash
bash smoke-test.sh --skip-socket
```

The matrix covers:

- FPC build checks
- optional FFmpeg/preview build checks
- local runtime smokes
- socket-based server/client smokes
- Delphi Win64 compile checks

## Main Runners

- [Gateway Console](Examples/RtmpGatewayConsole.pas)
  Config-driven ingest or ingest+relay runner.
- [Graph Gateway Console](Examples/RtmpGraphGatewayConsole.pas)
  Pipeline-oriented gateway sample.
- [Ingest Console](Examples/RtmpIngestConsole.pas)
  Minimal ingest harness.
- [Restream Console](Examples/RtmpRestreamConsole.pas)
  Simple relay harness.
- [Play Console](Examples/RtmpPlayConsole.pas)
  RTMP play-side sample.
- [Live Preview](Examples/RtmpLivePreview.pas)
  Ingest + decode + render preview.
- [Preview Callback Console](Examples/RtmpPreviewCallbackConsole.pas)
  Headless decoded-frame consumer sample.

## Quick Start

### Ingest Only

Build and run:

```bash
./build-fpc.sh Examples/RtmpGatewayConsole.pas
./Bin/linux/RtmpGatewayConsole Examples/RtmpGatewayConsole.ini
```

Set `relay.enabled=false` in [RtmpGatewayConsole.ini](Examples/RtmpGatewayConsole.ini)
and publish to:

```text
rtmp://127.0.0.1:1935/live
```

with stream key:

```text
test
```

### Ingest + Relay

Set `relay.enabled=true` and configure `relay.target_url` in
[RtmpGatewayConsole.ini](Examples/RtmpGatewayConsole.ini), then run the same
gateway console. The local ingest URL remains:

```text
rtmp://127.0.0.1:1935/live/test
```

### FFmpeg Test Publisher

```bash
./Examples/ffmpeg_push_test.sh
```

### Live Preview

Linux/WSLg helper:

```bash
./Examples/run-live-preview-wsl.sh
```

Windows build:

```bash
./build-delphi.sh Examples/RtmpLivePreview.pas Win64 --with-ffmpeg --with-sfml
```

## Optional Dependencies

### FFmpeg headers

The optional decoder path uses FFmpeg Pascal headers from:

- [ThirdParty/TRadioPlayer/Headers](ThirdParty/TRadioPlayer/Headers)

### PasSFML

The optional renderer path uses:

- [ThirdParty/PasSFML/Source](ThirdParty/PasSFML/Source)

## Status And Planning

- [Current Status](Docs/current-status.md)
- [Implementation Design](Docs/implementation-design.md)
- [Interop Notes](Docs/interop-notes.md)
- [API Ergonomics Notes](Docs/api-ergonomics.md)
- [Production-Readiness Checklist](Docs/production-readiness-checklist.md)
- [TODO](Docs/TODO.md)

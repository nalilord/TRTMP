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
- No mandatory third-party TLS DLLs: Windows uses Schannel, while Unix RTMPS
  uses the system OpenSSL installation through the provider interface.
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
- `Tools/`
  Repository formatting and code-style checks.

The main runtime pieces are:

- `TRtmpServer`
  Ingest server with publish-session handling and stats.
- `TRtmpClient`
  RTMP publish client for relay/restream use.
- `TRtmpCircularBuffer`
  Bounded packet ring with retained metadata/config/keyframe bootstrap state.
- `TRtmpAnalyzer`
  Packet-level metrics and codec-config inspection.
- `TRtmpPreview`
  Optional decode/callback preview core.
- `TRtmpSfmlPreviewRenderer`
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
- optional fail-closed connect and publish authorization hooks
- built-in Windows Schannel and Unix system-OpenSSL RTMPS transports, with
  fail-closed scheme handling and an overridable provider boundary
- Delphi-friendly config constructors and fluent config helpers
- configurable relay timestamp modes
- Enhanced RTMP HEVC, AV1, VP9, Opus, FLAC, AC-3, and E-AC-3 packet signaling
- Enhanced RTMP Multitrack and ModEx parsing with packet-exact buffering/relay
- selectable Multitrack decoding: one independent decoder instance per audio or
  video track, with automatic track-zero preference
- bidirectional configurable `capsEx` negotiation; reconnect requests,
  Multitrack, ModEx, and nanosecond offsets are advertised by default
- exact ModEx nanosecond timestamps through FFmpeg decode and preview
- reconnect-safe Twitch VOD audio retention plus an optional required-track
  relay guard
- optional FFmpeg-backed AVC/AAC plus HEVC, AV1, VP9, Opus, FLAC, AC-3, and
  E-AC-3 decode path
- optional live preview path through PasSFML

Real-world validation already performed:

- OBS publish into the ingest server
- `ffmpeg` publish into the ingest server
- restream into nginx-rtmp with playback confirmation
- Win64 Delphi live preview from OBS ingest

## Repository Layout

```text
Docs/
Examples/
Source/
Tests/
Tools/
Code_Style_Guide.md
LICENSE
build-delphi.sh
build-fpc.sh
build-wsl-generic.sh
smoke-test.sh
```

Notes:

- `Bin/` and `Temp/` are ignored build-output directories created on demand.
- `ThirdParty/` is intentionally ignored and is not part of a clean checkout.
  Place optional PasSFML sources, FFmpeg Pascal headers, and locally built
  CSFML/SFML artifacts there when enabling decode or rendering.

## Build

FPC:

```bash
./build-fpc.sh Examples/RtmpGatewayConsole.pas
```

Delphi Win64:

```bash
./build-delphi.sh Examples/RtmpGatewayConsole.pas Win64
```

For custom Pascal projects, `build-wsl-generic.sh` provides a configurable WSL
wrapper for Delphi Win32/Win64 and FPC Linux64 builds. Run it with `--help` for
the supported environment overrides.

Optional FFmpeg/preview builds:

```bash
./build-fpc.sh Examples/RtmpDecoderSmoke.pas --with-ffmpeg
./build-fpc.sh Examples/RtmpPreviewCallbackConsole.pas --with-ffmpeg

./build-delphi.sh Examples/RtmpPreviewCallbackConsole.pas Win64 --with-ffmpeg
./build-delphi.sh Examples/RtmpLivePreview.pas Win64 --with-ffmpeg --with-sfml
```

Code style:

```bash
Tools/check-code-style.sh
Tools/check-unit-names.sh
Tools/format-pascal-style.pl Source/*.pas Examples/*.pas
```

Library units use `TRTMP` as the project namespace and `TRTMP.RTMP` for the
current protocol implementation. See [Unit Namespaces](Docs/unit-namespaces.md)
for the namespace policy and migration map.

Server policy hooks are documented in
[Server Authorization](Docs/server-authorization.md).
RTMPS platform behavior is documented in
[RTMPS / TLS Transport](Docs/rtmps-tls.md).
Checks that require credentials, hosted targets, or an interactive Windows
session are tracked in
[Postponed Live Validation](Docs/postponed-live-validation.md).

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
- verified OpenSSL and Schannel TLS transport smokes
- real FFmpeg RTMPS ingest and packet-exact RTMPS relay
- Delphi Win64 compile checks

Enhanced RTMP codec interoperability has a separate FFmpeg-driven live matrix:

```bash
bash Tests/ffmpeg-codec-matrix.sh --strict
```

It validates legacy H.264/AAC/MP3 plus enhanced HEVC, AV1, VP9, Opus, FLAC,
AC-3, and E-AC-3 signaling. VP8 is also probed but reports an expected skip
because FFmpeg's RTMP publisher cannot emit `vp08`; TRTMP still recognizes it
at packet level. See
[FFmpeg Codec Interoperability Testing](Docs/codec-interop-testing.md) for result
semantics, encoder requirements, and current publisher limitations.

Verify packet-exact relay and an external FFmpeg receiver with:

```bash
bash Tests/ffmpeg-relay-matrix.sh
bash Tests/ffmpeg-external-relay-smoke.sh
bash Tests/ffmpeg-rtmps-integration.sh
```

Run a real-time 60-second ingest/RSS soak separately, or include it in the main
matrix with `--with-soak`:

```bash
bash Tests/ffmpeg-ingest-soak.sh
bash smoke-test.sh --with-soak --skip-sfml
```

Exercise the optional Enhanced RTMP decoder and enhanced-video preview/conversion
pipeline with real FFmpeg publishers:

```bash
bash Tests/ffmpeg-enhanced-decode-smoke.sh
bash Tests/ffmpeg-enhanced-preview-smoke.sh
```

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

The optional decoder path expects locally supplied FFmpeg Pascal headers at:

- `ThirdParty/TRadioPlayer/Headers`

### PasSFML

The optional renderer path expects locally supplied PasSFML sources at:

- `ThirdParty/PasSFML/Source`

## Status And Planning

- [Current Status](Docs/current-status.md)
- [Implementation Design](Docs/implementation-design.md)
- [Interop Notes](Docs/interop-notes.md)
- [FFmpeg Codec Interoperability Testing](Docs/codec-interop-testing.md)
- [Twitch VOD Audio Relay](Docs/twitch-vod-audio-relay.md)
- [API Ergonomics Notes](Docs/api-ergonomics.md)
- [Production-Readiness Checklist](Docs/production-readiness-checklist.md)
- [Code Style Guide](Code_Style_Guide.md)
- [TODO](Docs/TODO.md)

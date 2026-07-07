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
- renewed OBS/Windows runtime validation after the latest hardening changes
- final repository presentation and third-party packaging decisions
- capture-backed Twitch/VOD-track compatibility work

## Recommended Entry Points

- [Gateway Console](../Examples/RtmpGatewayConsole.pas)
- [Gateway Config](../Examples/RtmpGatewayConsole.ini)
- [Implementation Design](implementation-design.md)
- [Interop Notes](interop-notes.md)
- [API Ergonomics Notes](api-ergonomics.md)
- [Production-Readiness Checklist](production-readiness-checklist.md)
- [TODO](TODO.md)

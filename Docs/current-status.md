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

## Core Runtime Coverage

- handshake and chunk parsing
- AMF0 command flow
- publish-session handling
- bounded packet buffering
- reconnect and relay bootstrap
- packet-level analyzer stats
- low-latency preview queue/drop policy

## Current Strengths

- The ingest and relay path is materially usable.
- The stats/logging surface is good enough for live troubleshooting.
- The optional preview path is reusable instead of being locked into one demo.
- The decoder and preview layers remain optional and outside the core RTMP path.

## Main Remaining Gaps

- broader interop validation against more RTMP targets
- API ergonomics review from a Delphi library-consumer perspective
- top-level licensing and final repository presentation
- capture-backed Twitch/VOD-track compatibility work

## Recommended Entry Points

- [Gateway Console](../Examples/RtmpGatewayConsole.pas)
- [Gateway Config](../Examples/RtmpGatewayConsole.ini)
- [Implementation Design](implementation-design.md)
- [Interop Notes](interop-notes.md)
- [TODO](TODO.md)

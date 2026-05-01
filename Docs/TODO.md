# TODO

## Production Priority Order

This is the current implementation order for getting the library into
productive use as a low-latency RTMP stack:

1. Server
2. Client
3. Stats / Logging
4. Packet / Processor
5. Packet / Decoder via FFmpeg 8.1 headers

Reason:

- the immediate use case is a low-latency RTMP server for live display,
- ingest stability and latency behavior matter more than decode features,
- decoder integration should come after the runtime path is production-safe.

## Completed

### Foundation
- [x] Define shared RTMP types, enums, config records, and stats records.
- [x] Implement packet model with shared payload ownership.
- [x] Implement native transport abstraction with pluggable backend boundary.
- [x] Provide default native socket transport for Windows/Unix style targets.

### Protocol Core
- [x] Implement endian-safe byte readers/writers.
- [x] Implement RTMP simple handshake helpers.
- [x] Implement chunk header parsing and serialization.
- [x] Implement inbound chunk reassembly across chunk stream state.
- [x] Implement AMF0 encode/decode for command flow.
- [x] Implement command parsing helpers for `connect`, `createStream`, `publish`, `releaseStream`, and `FCPublish`.

### Ingest Server
- [x] Implement inbound RTMP publish flow in `TRtmpServerSession`.
- [x] Handle `connect`, `createStream`, and `publish` for OBS-style ingest.
- [x] Reject invalid command ordering for `connect`, `createStream`, and `publish`.
- [x] Handle explicit teardown commands such as `FCUnpublish` and `deleteStream`.
- [x] Handle inbound `SetChunkSize`, ACKs, and ping/pong peer control.
- [x] Normalize inbound RTMP/FLV messages into `TRtmpPacket` objects.
- [x] Wire server packet dispatch into buffer and stats.
- [x] Enforce server-side session admission via `MaxSessions`.
- [x] Enforce inbound chunk-size caps via `MaxChunkSize`.
- [x] Wire analyzer snapshots into server stats when enabled.
- [x] Provide runnable ingest console harness.

### Buffering And Stats
- [x] Implement bounded circular packet buffer.
- [x] Support both packet-count and byte-count limits.
- [x] Retain metadata, audio config, video config, and latest keyframe for bootstrap.
- [x] Expose buffer occupancy and eviction statistics.
- [x] Make relay/bootstrap reads use cloned snapshots instead of live packet references.
- [x] Ensure retained keyframe can still be replayed after ring eviction.

### Outbound Client / Restream
- [x] Implement outbound RTMP handshake and publish flow.
- [x] Implement relay from shared buffer into outbound target.
- [x] Replay bootstrap headers and buffered media on connect/reconnect.
- [x] Implement reconnect with backoff.
- [x] Add explicit target-response classification for connect/create/publish failures.
- [x] Tolerate optional `releaseStream` and `FCPublish` rejection.
- [x] Prevent media send before publish acceptance.
- [x] Implement timestamp modes: pass-through, rebased, smoothed.
- [x] Provide runnable restream console harness.

### Verification / Smokes
- [x] Add client publish smoke test.
- [x] Add reconnect smoke test.
- [x] Add reconnect live-edge smoke test.
- [x] Add timestamp-mode smoke test.
- [x] Add publish-reject smoke test.
- [x] Add buffer eviction/bootstrap smoke test.
- [x] Add chunk reassembler smoke for invalid header sequences, truncated chunks, and extended timestamps.
- [x] Add server hardening smoke for max-session admission and oversized chunk-size rejection.
- [x] Add server command-flow smoke for invalid publish ordering and teardown commands.
- [x] Verify ingest from local `ffmpeg 8.1` publish.
- [x] Live-test OBS ingest locally.
- [x] Live-test restream to nginx RTMP and confirm playback via VLC.

## Current Priority
- [ ] Server: harden ingest-side protocol handling for malformed or hostile input.
- [ ] Server: reduce latency risks and clarify low-latency runtime behavior.
- [ ] Server: expand automated coverage around server session and reassembler edge cases.
- [ ] Client: improve interop coverage beyond the OBS -> nginx happy path.
- [ ] Stats / Logging: make production diagnostics clearer under live load.

## Next Tasks

### 1. Server
- [x] Define a production-readiness checklist for ingest stability and low-latency behavior.
- [x] Add malformed-input tests for chunk reassembly edge cases.
- [x] Add tests for invalid chunk header sequences and truncated messages.
- [x] Add tests for extended timestamp edge cases.
- [x] Decide and document how strictly to handle unsupported message types.
- [x] Audit the ingest hot path for avoidable copies and blocking operations.
- [x] Review buffering strategy specifically for live-preview latency, not just relay safety.
- [x] Define explicit server-side behavior when buffer pressure grows.
- [x] Separate "buffer eviction" from "intentional live drop policy" in stats and logging.
- [x] Add tests for sustained ingest under small buffer budgets.

### 2. Client
- [ ] Re-check reconnect and publish behavior against real-world targets after server hardening.
- [x] Decide whether relay should skip ahead to latest keyframe under long target outages.
- [ ] Re-test with OBS on Windows after the latest hardening changes.
- [ ] Test relay into additional RTMP targets beyond nginx-rtmp.
- [x] Capture known interop quirks in docs.

### 3. Stats / Logging
- [x] Improve error categorization in ingest logs and stats.
- [x] Make session/server stats more actionable for live operations.
- [x] Add clearer latency-oriented counters where possible.
- [x] Review log noise vs signal for production runtime use.

### 4. Packet / Processor
- [x] Parse AVC/AAC config payloads more deeply.
- [x] Extract resolution, sample rate, and channel info from real headers.
- [x] Improve jitter/drift reporting.
- [x] Add analyzer-specific tests instead of relying only on packet flags.

### 5. Packet / Decoder
- [x] Define decoder boundary and ownership model before integrating decode code.
- [x] Add packet-decoder scaffolding against FFmpeg 8.1 headers.
- [x] Keep decoder work optional and separated from the low-latency server path.
- [x] Add tests or fixtures for decode input/output contracts.
- [x] Add an optional frame-conversion layer for decoded video frames.
- [x] Add a simple PasSFML render demo for the Windows-side decode-to-display path.
- [x] Add a live ingest preview example using RTMP server + FFmpeg decode + PasSFML render.
- [x] Extract the preview/decode/render loop into reusable preview units.
- [x] Add configurable stream selection, scaling policy, and bounded drop policy for preview consumers.
- [x] Expose decoded-frame callbacks so non-SFML consumers can use the preview path.
- [x] Add explicit preview follow/select modes plus deeper preview-local stats.
- [x] Add a callback-only preview example for non-SFML consumers.

### Windows / Delphi Productization
- [x] Build a cleaner config-driven runner for Delphi/Windows use.
- [x] Add a Delphi build helper and validate Win64 compile on the main runners.
- [ ] Review unit/API surface for Delphi ergonomics.
- [x] Test compile and runtime behavior under actual Delphi, not only FPC.
- [ ] Decide how custom transports such as Indy should be documented and plugged in.

### Documentation
- [x] Add a short README with build/run/test commands.
- [x] Add a "current status" overview for new contributors.
- [x] Document example workflows: ingest-only and ingest+restream.
- [x] Document timestamp-mode behavior with practical guidance.

## Later

### Platform-Specific / Twitch Compatibility
- [ ] Create a reliable real-world test case for Twitch VOD-track behavior.
- [ ] Capture two comparable OBS publish sessions:
  one with Twitch VOD track disabled and one with it enabled.
- [ ] Keep OBS in actual Twitch service mode for capture instead of generic custom RTMP mode.
- [ ] Record raw packet/message differences at the RTMP session level.
- [ ] Diff command messages, data messages, audio packets, and control packets between the two captures.
- [ ] Determine whether the Twitch-specific difference is:
  extra audio track packets, extra AMF/data messages, enhanced RTMP signaling, or another ingest convention.
- [ ] Add fixture files or reproducible capture notes to the repo.
- [ ] Add logging in the library to expose unknown/non-media RTMP messages without dropping them.
- [ ] Add a strict passthrough mode for non-media/data/control messages.
- [ ] Extend the packet model with track-aware fields if the capture confirms multiple logical audio tracks.
- [ ] Model track identity/role explicitly, for example `TrackId`, `TrackKind`, `TrackRole`.
- [ ] Preserve and relay Twitch/VOD-track related signaling byte-faithfully by default.
- [ ] Add regression tests that prove the relevant Twitch-side signaling survives ingest and relay unchanged.
- [ ] Document Twitch / VOD-track findings once the capture-based analysis is done.

### Advanced Routing
- [ ] One-to-many forwarding from a single ingest source.
- [ ] Stream selection by app/key.
- [ ] Config-driven pipeline assembly.
- [ ] Per-target relay policy and buffering options.

### Nice To Have
- [ ] Structured test fixtures instead of only example-smoke executables.
- [ ] Optional authentication / authorization hooks.
- [ ] RTMPS/TLS strategy.
- [ ] More detailed metrics export.

## Notes
- Keep Delphi/Windows as the primary design target even when validating through secondary toolchains.
- Prefer adding targeted smoke or fixture coverage alongside each protocol hardening change.
- Do not run long-lived servers in the background except during explicit live test rounds.
- Treat Twitch VOD-track behavior as a capture-first feature, not a guess-first feature.
- Do not assume classic single-audio-track RTMP is sufficient until the Twitch-side packet flow is understood.

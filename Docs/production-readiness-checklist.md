# RTMP Server Production-Readiness Checklist

This checklist is for deciding when the ingest server is ready for productive
low-latency use.

## Protocol Correctness

- [x] Handshake completes against OBS and FFmpeg reliably.
- [x] `connect`, `createStream`, and `publish` command flow is accepted in the correct order.
- [x] Out-of-order command flow is rejected with a clear RTMP error/status response.
- [x] Teardown commands such as `FCUnpublish`, `deleteStream`, and `closeStream` are handled intentionally.
- [x] Unknown RTMP message types are ignored without destabilizing the session.
- [x] Malformed chunk-header sequences fail fast and close the session cleanly.
- [x] Extended timestamps reconstruct correctly across chunk continuations.

## Runtime Stability

- [x] `MaxSessions` admission control is enforced.
- [x] Oversized inbound chunk-size changes are rejected.
- [x] Oversized inbound message allocations are rejected before payload allocation.
- [x] Excessive inbound chunk-stream state creation is rejected.
- [x] Session teardown always releases the server slot.
- [x] Known allocation and buffering hazards are capped by protocol and buffer limits.
- [x] No unbounded memory-growth path appears in renewed long ingest runs.
  The 2026-08-01 five-minute automated run completed with 2,688 KiB baseline
  RSS, 4,356 KiB peak RSS, and 1,668 KiB growth.
- [x] Buffer limits are applied at startup and visible in runtime stats.
- [x] Buffer eviction under pressure is observable and predictable.

## Low-Latency Behavior

- [x] The ingest path does not block on avoidable copies in the hot path.
- [x] Packet buffering policy is explicitly chosen for live-display latency, not only relay safety.
- [x] A sustained ingest run under a deliberately small buffer budget remains stable.
- [x] Current bitrate reflects live traffic rather than only cumulative averages.
- [x] Debug logging can be enabled for diagnosis without being required for normal operation.

## Interop Coverage

- [ ] OBS publish remains stable over multi-minute runs.
- [x] FFmpeg 8.1 publish remains stable over multi-minute runs.
  This is automated by `Tests/ffmpeg-ingest-soak.sh`; release runs should use
  `DURATION=300` or longer.
- [x] The ingest server tolerates optional stream-control commands such as `releaseStream` and `FCPublish`.
- [x] Restream client still interoperates with the hardened server path.

## Operational Observability

- [x] Session errors, protocol errors, and admission rejections are distinguishable in logs and stats.
- [x] Buffer occupancy, retention, and eviction numbers are visible during live runs.
- [x] Latency-oriented ingest counters have deterministic coverage.
- [x] Stream analyzer snapshots are available when enabled and absent when disabled.
- [x] The runtime can be exercised with a reproducible local publisher command.

## Exit Rule

The server is ready for productive low-latency use when:

- protocol correctness checks are green,
- runtime stability items have no known red flags,
- OBS and FFmpeg both pass sustained publish runs,
- and remaining TODO items are polish rather than ingest-risk items.

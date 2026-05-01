# RTMP Server Production-Readiness Checklist

This checklist is for deciding when the ingest server is ready for productive
low-latency use.

## Protocol Correctness

- [ ] Handshake completes against OBS and FFmpeg reliably.
- [ ] `connect`, `createStream`, and `publish` command flow is accepted in the correct order.
- [ ] Out-of-order command flow is rejected with a clear RTMP error/status response.
- [ ] Teardown commands such as `FCUnpublish`, `deleteStream`, and `closeStream` are handled intentionally.
- [ ] Unknown RTMP message types are ignored without destabilizing the session.
- [ ] Malformed chunk-header sequences fail fast and close the session cleanly.
- [ ] Extended timestamps reconstruct correctly across chunk continuations.

## Runtime Stability

- [ ] `MaxSessions` admission control is enforced.
- [ ] Oversized inbound chunk-size changes are rejected.
- [ ] Session teardown always releases the server slot.
- [ ] No known unbounded memory-growth path remains in long ingest runs.
- [ ] Buffer limits are applied at startup and visible in runtime stats.
- [ ] Buffer eviction under pressure is observable and predictable.

## Low-Latency Behavior

- [ ] The ingest path does not block on avoidable copies in the hot path.
- [ ] Packet buffering policy is explicitly chosen for live-display latency, not only relay safety.
- [ ] A sustained ingest run under a deliberately small buffer budget remains stable.
- [ ] Current bitrate reflects live traffic rather than only cumulative averages.
- [ ] Debug logging can be enabled for diagnosis without being required for normal operation.

## Interop Coverage

- [ ] OBS publish remains stable over multi-minute runs.
- [ ] FFmpeg 8.1 publish remains stable over multi-minute runs.
- [ ] The ingest server tolerates optional stream-control commands such as `releaseStream` and `FCPublish`.
- [ ] Restream client still interoperates with the hardened server path.

## Operational Observability

- [ ] Session errors, protocol errors, and admission rejections are distinguishable in logs and stats.
- [ ] Buffer occupancy, retention, and eviction numbers are visible during live runs.
- [ ] Stream analyzer snapshots are available when enabled and absent when disabled.
- [ ] The runtime can be exercised with a reproducible local publisher command.

## Exit Rule

The server is ready for productive low-latency use when:

- protocol correctness checks are green,
- runtime stability items have no known red flags,
- OBS and FFmpeg both pass sustained publish runs,
- and remaining TODO items are polish rather than ingest-risk items.

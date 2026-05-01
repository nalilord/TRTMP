# Interop Notes

## Verified Paths

### OBS -> TRTMP ingest

- publish workflow is working end-to-end
- metadata, AAC config, AVC config, audio packets, and video packets are accepted
- this path previously exposed reassembly/backpressure bugs, which were fixed and retested

### FFmpeg -> TRTMP ingest

- local `ffmpeg` publish works against the ingest server
- the server sends RTMP peer-control defaults immediately after handshake so
  `ffmpeg` does not stall waiting for them

### TRTMP -> nginx-rtmp

- restream publish works
- downstream playback was confirmed

### Win64 preview path

- live preview works with real OBS ingest
- the validated path is: ingest -> decode -> frame conversion -> PasSFML render

## Relay Policy

### Reconnect bootstrap

- reconnect resumes from the latest retained keyframe window
- this intentionally avoids replaying stale pre-outage backlog
- regression coverage exists in `Examples/RtmpClientReconnectLiveEdgeSmoke.pas`

### Timestamp modes

- pass-through
- rebased
- smoothed

These are implemented for relay behavior and already covered by smoke tests.

## Diagnostics Notes

### Log filtering

- visible log filtering does not disable internal publish/session events
- stats and event hooks remain active even when normal output is suppressed

### Error buckets

Current stats distinguish:

- protocol failures
- transport failures
- session failures

### Latency-oriented counters

Current server stats expose:

- last packet idle time
- current media timeline lag
- maximum observed timeline lag

These are ingest diagnostics, not end-to-end player latency claims.

## Known Limits

### Target coverage

Real-world coverage is still narrower than the protocol surface:

- OBS publish
- `ffmpeg` publish
- nginx-rtmp target

More targets still need explicit validation before claiming broad interop.

### Twitch / VOD-track behavior

This is still intentionally capture-first. No broad claim should be made until a
real fixture-backed understanding of that signaling exists.

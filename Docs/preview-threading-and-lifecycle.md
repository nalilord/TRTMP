# Preview callbacks and server lifetime

The September 2026 StreamBridge hardening changes establish these ownership rules:

- Call `TRtmpPreview.Poll`, `Start`, `Stop`, and selection/configuration methods on the preview's owner thread. For a graphical application this is the main/render thread.
- `OnFrame`, `OnStreamStarted`, and `OnStreamStopped` are delivered by `Poll` on that thread. Connection events are copied into a queue by RTMP session threads; code that previously expected a stream callback before its first `Poll` must now poll to receive it.
- `OnLog` can still execute on a network thread. Log handlers must be thread-safe and must not access renderer/Lua objects directly.
- `TRtmpServer`'s own session/data callbacks remain on session threads. Call server `Stop`/destruction from its control/owner thread, not from one of those callbacks, because `Stop` joins the session threads.
- Server `Stop` stops admission, joins the accept thread, requests cancellation of every session, and joins all sessions before returning. Completed threads are reaped during normal acceptance. Socket/TLS cleanup stays on the session's thread; cancellation is checked between bounded I/O waits.
- Preview `Stop` discards pending connection notifications and clears its decoder state after server shutdown. No queued notification is delivered by a later `Poll`.
- Deferred decoder opens use an owned clone of the cached codec configuration. Selection and packet admission share the preview lock, and frames from a decoder awaiting a selection reset are suppressed.

`DefaultRtmpServerConfig` now sets `HandshakeTimeoutMS=10000` and `IdleTimeoutMS=30000`. These elapsed deadlines are separate from per-read waits. A handshake has one total deadline; receiving occasional partial handshake bytes does not extend it. After handshake, a complete successfully handled RTMP message resets the inactivity deadline. Successful outgoing traffic also counts for a playback client. A nonpositive deadline disables that particular deadline for explicit library configurations; the default StreamBridge player uses both defaults.

The existing `ReadTimeoutMS` and `WriteTimeoutMS` still control I/O behavior. Individual waits are capped at 200 ms to poll cancellation; a send operation observes the configured overall write deadline. These settings do not determine the application's shorter decoded-video freshness timeout.

Run the regression suite with Free Pascal and the FFmpeg Pascal headers:

```bash
FFMPEG_HEADERS_DIR=/path/to/FFmpeg/Headers bash Tests/run-hardening-tests.sh
```

The suite checks shutdown/restart, handshake and idle expiry/slot reuse, malformed-AMF cleanup with heap tracing, and start/stop callback ownership/selection. It writes diagnostics under a unique `/tmp/trtmp-hardening-tests.*` directory. Additional compiler/linker options can be supplied as script arguments.

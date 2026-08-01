# Postponed Live Validation

Local behavior must be covered by automated fixtures wherever practical. The
checks below remain deliberately postponed because they require credentials,
an external service, a Windows desktop session, or unavailable optional local
dependencies.

## External services and credentials

- Credentialed Twitch ingest with VOD/archive audio enabled, followed by an
  actual VOD playback check.
- Relay acceptance against additional hosted RTMP/RTMPS targets beyond the
  locally tested TRTMP, FFmpeg, and nginx-rtmp endpoints.
- Real-target reconnect and publish-policy behavior after network interruption.

These checks must not be replaced with claims based only on local emulation.
The packet capture and deterministic TrackID 1 coverage remain useful before
that acceptance round.

## Interactive Windows checks

- Current OBS service-mode ingest into the Delphi Win64 server.
- Current live preview through the FFmpeg/PasSFML Windows rendering path.
- Long Windows desktop runs with reconnects and application shutdown/restart.

The Delphi Win64 compile matrix and Schannel runtime fixture stay automated,
but they do not claim OBS GUI or rendering acceptance.

## Toolchain and optional dependency checks

- FPC Win64 compilation awaits an installed Win64 FPC RTL in the build
  environment. The Windows branches retain FPC-compatible unit conditionals.
- The optional Linux SFML matrix awaits a populated
  `ThirdParty/Linux/Csfml` prefix. Core, FFmpeg, RTMP, and TLS matrices do not
  depend on it.

## Re-entry rule

When the required environment becomes available, capture the exact versions,
commands/settings, observable result, and any wire fixture that can be retained
without credentials. Then promote repeatable portions into `Tests/`.

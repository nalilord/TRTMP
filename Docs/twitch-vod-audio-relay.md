# Twitch VOD Audio Relay

## Current OBS Wire Format

OBS Studio 30.2 and newer use Enhanced RTMP/FLV Multitrack audio for Twitch
VOD audio. The normal live AAC feed is track 0. The additional archive/VOD
encoder is output index 1 and is serialized as Enhanced RTMP audio TrackID 1.
OBS normally uses UI audio track 1 for live audio and UI audio track 2 for VOD
audio, but the selected mixer can be changed in Advanced Output settings.

TRTMP preserves both packet streams byte-for-byte. Its bootstrap buffer retains
codec configuration independently for every TrackID, so relay startup and
reconnect no longer let the TrackID 1 sequence header replace track 0.

## Enforcing VOD Audio on a Relay

Set the gateway relay option:

```ini
[relay]
enabled=true
target_url=rtmp://your-twitch-ingest/app/stream-key
require_twitch_vod_audio=true
```

This is equivalent to `required_audio_track_id=1`. The client will not connect
and publish media to the destination until retained codec configurations exist
for both live track 0 and VOD track 1. This prevents a temporary OBS setup error
from silently producing a Twitch stream without the VOD feed.

The relay cannot manufacture a VOD mix. OBS must encode and send the alternate
audio feed. The guard only verifies the required signaling is present and keeps
it intact through startup and reconnect.

## OBS Setup

Preferred setup:

1. Select the Twitch service in OBS so the Twitch VOD Track controls remain
   available.
2. Select/configure the TRTMP relay as the ingest server if the OBS service UI
   permits a custom server.
3. Enable Twitch VOD Track and route the intended audio sources to both the live
   and VOD mixer tracks as appropriate.
4. Enable `require_twitch_vod_audio=true` in TRTMP.

For OBS custom-service mode, current OBS source also supports VOD controls when
its user configuration contains:

```ini
[General]
EnableCustomServerVodTrack=true
```

The exact OBS settings-file location is platform-specific. Restart OBS after
changing the user configuration, then enable Twitch VOD Track in Output
settings.

## Validation Boundary

The repository tests cover the OBS 30.2+ wire layout, per-track bootstrap
retention, packet-exact loopback relay, reconnect-safe headers, and strict relay
enforcement. An actual Twitch ingest/VOD acceptance run is still required
before claiming end-to-end Twitch production validation.

References:

- [OBS Twitch VOD Track Guide](https://obsproject.com/kb/twitch-vod-track-guide)
- [OBS current RTMP audio packet routing](https://github.com/obsproject/obs-studio/blob/master/plugins/obs-outputs/rtmp-stream.c)
- [OBS Enhanced FLV audio muxing](https://github.com/obsproject/obs-studio/blob/master/plugins/obs-outputs/flv-mux.c)

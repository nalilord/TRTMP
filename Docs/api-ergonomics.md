# API Ergonomics Notes

TRTMP exposes Delphi-friendly config records and class events while keeping the
core compatible with FPC Delphi mode.

## Config Style

Use the `CreateDefault` class functions when writing library-style code. The
top-level `DefaultRtmp*Config` functions remain available for simple procedural
setup.

```pascal
ServerConfig := TRtmpServerConfig.CreateDefault
  .WithBind('0.0.0.0', 1935)
  .WithBufferLimits(1024, 16 * 1024 * 1024, 3000)
  .WithProtocolLimits(131072, 8 * 1024 * 1024, 64)
  .WithTimeouts(10000, 10000)
  .WithEnhancedCapabilities(RTMP_DEFAULT_ENHANCED_CAPABILITIES);

ClientConfig := TRtmpClientConfig.CreateDefault
  .WithTarget('rtmp://example.invalid/live/stream', '', '')
  .WithEnhancedCodecs('hvc1,av01,vp09,Opus,fLaC,ac-3,ec-3')
  .WithEnhancedCapabilities(RTMP_DEFAULT_ENHANCED_CAPABILITIES)
  .WithReconnect(1000, 15000)
  .WithReconnectBoundaryTimeout(2000)
  .WithOutChunkSize(4096)
  .WithTimestampMode(tmPassThrough);
```

The default Enhanced RTMP capabilities are `$0F` (Reconnect Request,
Multitrack, ModEx, and timestamp-nanosecond offsets). A reconnect request waits
for the next video keyframe before switching; `ReconnectBoundaryTimeoutMS`
limits that wait for audio-only streams or delayed keyframes. Zero switches
immediately.
`TRtmpServerSession.EnhancedCapabilities` exposes the connecting peer's flags,
while `TRtmpClient.PeerEnhancedCapabilities` exposes the server's returned
flags. Set either config value to zero to omit `capsEx` advertisement.

For RTMPS, use an `rtmps://` target. The default factory uses Schannel on
Windows and system OpenSSL on Unix:

```pascal
ClientConfig:=TRtmpClientConfig.CreateDefault
  .WithTargetUrl('rtmps://ingest.example.test/live/key')
  .WithTlsVerification(True, 'trusted-ca.pem');
```

An empty TLS `ServerName` uses the URL host for SNI and certificate hostname
verification. TLS 1.2 and peer verification are defaults. Server TLS is enabled
with `TRtmpServerConfig.WithTls`. `TransportFactory` remains replaceable for
applications that need another provider. See
[RTMPS / TLS Transport](rtmps-tls.md) for platform-specific certificate formats.

For selected-track decode, use one decoder instance per desired track:

```pascal
VideoDecoder := TRtmpFFmpegPacketDecoder.Create;
VideoDecoder.TrackID := 1; // -1 prefers track 0, then the first available track
VideoDecoder.OpenFromConfig(VideoConfigPacket);
```

`ActiveTrackID` reports the track opened by the sequence header, and
`TRtmpDecodedFrameInfo.TrackID` carries it with every decoded frame. Explicit
IDs never fall back to another track. Changing `TrackID` closes the existing
codec context so data from two tracks cannot share stale decoder state.
`TRtmpPreviewConfig.VideoTrackID` applies the same policy to preview output.

For relays that must not silently lose an auxiliary audio track:

```pascal
ClientConfig := ClientConfig.WithRequiredAudioTrack(1);
```

Track 1 is the current OBS/Twitch VOD audio wire ID. Requiring a nonzero audio
track also requires retained track-zero configuration. The relay waits through
its normal reconnect loop until both headers exist.

The protocol limits are ingest safety limits:

- `MaxChunkSize`: maximum accepted inbound RTMP chunk size.
- `MaxMessageSize`: maximum declared inbound RTMP message size before payload
  allocation.
- `MaxChunkStreams`: maximum inbound chunk-stream states retained per session.

## Construction Style

Both server and client support default construction plus config assignment:

```pascal
Server := TRtmpServer.Create;
Server.Config := ServerConfig;
```

They also support config constructors for concise setup:

```pascal
Server := TRtmpServer.Create(ServerConfig);
Client := TRtmpClient.Create(ClientConfig);
```

The config constructors do not start sockets or worker threads. Call `Start`
explicitly after assigning events, transport factories, packet sinks, or buffers.

## Transport Boundary

`TRtmpServer.TransportFactory` and `TRtmpClient.TransportFactory` accept any
implementation of `IRtmpTransportFactory`. This is the intended extension point
for custom transports such as Indy-based sockets or test doubles.

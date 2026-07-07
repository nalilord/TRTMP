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
  .WithTimeouts(10000, 10000);

ClientConfig := TRtmpClientConfig.CreateDefault
  .WithTarget('rtmp://example.invalid/live/stream', '', '')
  .WithReconnect(1000, 15000)
  .WithOutChunkSize(4096)
  .WithTimestampMode(tmPassThrough);
```

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

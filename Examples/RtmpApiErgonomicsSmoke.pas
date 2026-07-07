program RtmpApiErgonomicsSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  RtmpBuffer,
  RtmpClient,
  RtmpPacket,
  RtmpServer,
  RtmpTypes;

procedure AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if not AValue then
    raise Exception.Create(AMessage);
end;

procedure TestServerConfigFluentApi;
var
  Buffer: TRtmpCircularBuffer;
  Config: TRtmpServerConfig;
  Server: TRtmpServer;
begin
  Config := TRtmpServerConfig.CreateDefault.
    WithBind('127.0.0.1', 1999).
    WithBufferLimits(12, 4096, 250).
    WithProtocolLimits(2048, 65536, 8).
    WithTimeouts(1500, 2500);

  AssertTrue('server bind address helper failed', Config.BindAddress = '127.0.0.1');
  AssertTrue('server bind port helper failed', Config.Port = 1999);
  AssertTrue('server buffer packet helper failed', Config.BufferMaxPackets = 12);
  AssertTrue('server buffer byte helper failed', Config.BufferMaxBytes = 4096);
  AssertTrue('server buffer duration helper failed', Config.BufferMaxDurationMS = 250);
  AssertTrue('server max chunk helper failed', Config.MaxChunkSize = 2048);
  AssertTrue('server max message helper failed', Config.MaxMessageSize = 65536);
  AssertTrue('server max chunk streams helper failed', Config.MaxChunkStreams = 8);
  AssertTrue('server read timeout helper failed', Config.ReadTimeoutMS = 1500);
  AssertTrue('server write timeout helper failed', Config.WriteTimeoutMS = 2500);

  Server := TRtmpServer.Create(Config);
  try
    AssertTrue('server config constructor failed', Server.Config.Port = 1999);
    AssertTrue('server initial buffer packet limit failed',
      Server.Buffer.GetStats.MaxPackets = 12);
    Buffer := TRtmpCircularBuffer.Create(4, 1024, 100);
    try
      Server.AttachBuffer(Buffer);
      Buffer := nil;
      AssertTrue('server attached buffer mismatch', Server.Buffer.GetStats.MaxPackets = 4);
    finally
      Buffer.Free;
    end;
  finally
    Server.Free;
  end;
end;

procedure TestClientConfigFluentApi;
var
  Client: TRtmpClient;
  Config: TRtmpClientConfig;
begin
  Config := TRtmpClientConfig.CreateDefault.
    WithTarget('rtmp://127.0.0.1:1935/live/fallback', 'live', 'override-key').
    WithConnectTimeout(1234).
    WithReconnect(250, 4000).
    WithOutChunkSize(2048).
    WithTimestampMode(tmRebased);

  AssertTrue('client target helper failed',
    Config.TargetURL = 'rtmp://127.0.0.1:1935/live/fallback');
  AssertTrue('client app helper failed', Config.App = 'live');
  AssertTrue('client stream helper failed', Config.StreamKey = 'override-key');
  AssertTrue('client connect timeout helper failed', Config.ConnectTimeoutMS = 1234);
  AssertTrue('client reconnect helper failed', Config.ReconnectDelayMS = 250);
  AssertTrue('client max reconnect helper failed', Config.MaxReconnectDelayMS = 4000);
  AssertTrue('client out chunk helper failed', Config.OutChunkSize = 2048);
  AssertTrue('client timestamp helper failed', Config.TimestampMode = tmRebased);

  Client := TRtmpClient.Create(Config);
  try
    AssertTrue('client config constructor failed', Client.Config.StreamKey = 'override-key');
    AssertTrue('client starts stopped', Client.State = csStopped);
  finally
    Client.Free;
  end;
end;

begin
  TestServerConfigFluentApi;
  TestClientConfigFluentApi;
  WriteLn('API ergonomics smoke passed.');
end.

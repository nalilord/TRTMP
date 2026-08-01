program RtmpApiErgonomicsSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  TRTMP.RTMP.Auth,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Client,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.Transport,
  TRTMP.Transport.Native,
  TRTMP.Transport.TLS,
  TRTMP.RTMP.Types;

procedure AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if NOT AValue then
    raise Exception.Create(AMessage);
end;

procedure TestServerConfigFluentApi;
var
  Buffer: TRtmpCircularBuffer;
  Config: TRtmpServerConfig;
  Server: TRtmpServer;
  TlsRejected: Boolean;
begin
  Config:=TRtmpServerConfig.CreateDefault.
    WithBind('127.0.0.1', 1999).
    WithBufferLimits(12, 4096, 250).
    WithProtocolLimits(2048, 65536, 8).
    WithTimeouts(1500, 2500).
    WithEnhancedCapabilities(RTMP_CAPS_EX_MULTITRACK).
    WithTls('server-cert.pem', 'server-key.pem', 'certificate-password');

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
  AssertTrue('server enhanced capabilities helper failed',
    Config.EnhancedCapabilities = RTMP_CAPS_EX_MULTITRACK);
  AssertTrue('server TLS helper failed', Config.Tls.Enabled AND
    (Config.Tls.CertificateFile = 'server-cert.pem') AND
    (Config.Tls.CertificatePassword = 'certificate-password') AND
    (Config.Tls.PrivateKeyFile = 'server-key.pem'));

  Server:=TRtmpServer.Create(Config);
  try
    AssertTrue('server config constructor failed', Server.Config.Port = 1999);
    AssertTrue('server initial buffer packet limit failed',
      Server.Buffer.GetStats.MaxPackets = 12);
    Buffer:=TRtmpCircularBuffer.Create(4, 1024, 100);
    try
      Server.AttachBuffer(Buffer);
      Buffer:=nil;
      AssertTrue('server attached buffer mismatch', Server.Buffer.GetStats.MaxPackets = 4);
    finally
      Buffer.Free;
    end;
  finally
    Server.Free;
  end;

  TlsRejected:=False;
  Server:=TRtmpServer.Create(Config);
  try
    Server.TransportFactory:=TRtmpNativeTransportFactory.Create;
    try
      Server.Start;
    except
      on E: ERtmpTransportError do
        TlsRejected:=Pos('has no TLS provider', E.Message) > 0;
    end;
  finally
    Server.Free;
  end;
  AssertTrue('native server transport did not reject TLS configuration',
    TlsRejected);
end;

procedure TestClientConfigFluentApi;
var
  Client: TRtmpClient;
  Config: TRtmpClientConfig;
  InvalidRejected: Boolean;
begin
  AssertTrue('authorization query parameter extraction failed',
    RtmpExtractQueryParameter(
      'rtmp://127.0.0.1/live?token=hello%20world&mode=push', 'token') =
      'hello world');
  AssertTrue('authorization query plus decoding failed',
    RtmpExtractQueryParameter('token=hello+world', 'token') = 'hello world');
  AssertTrue('missing authorization query parameter was not empty',
    RtmpExtractQueryParameter('rtmp://127.0.0.1/live', 'token') = '');

  Config:=TRtmpClientConfig.CreateDefault;
  AssertTrue('default enhanced codec list missing',
    Config.EnhancedCodecs = RTMP_DEFAULT_ENHANCED_CODECS);
  AssertTrue('default enhanced capabilities missing',
    Config.EnhancedCapabilities = RTMP_DEFAULT_ENHANCED_CAPABILITIES);
  AssertTrue('TLS verification must default to enabled', Config.Tls.VerifyPeer);
  AssertTrue('TLS minimum must default to 1.2',
    Config.Tls.MinimumVersion = tlsVersion12);
  AssertTrue('insecure redirects must default to disabled',
    NOT Config.AllowInsecureRedirect);
  Config:=TRtmpClientConfig.CreateDefault.
    WithTarget('rtmp://127.0.0.1:1935/live/fallback', 'live', 'override-key').
    WithConnectTimeout(1234).
    WithEnhancedCodecs('hvc1,av01,Opus').
    WithEnhancedCapabilities(RTMP_CAPS_EX_MULTITRACK OR RTMP_CAPS_EX_MODEX).
    WithRequiredAudioTrack(1).
    WithTlsVerification(False, 'custom-ca.pem').
    WithReconnect(250, 4000).
    WithReconnectBoundaryTimeout(1750).
    WithOutChunkSize(2048).
    WithTimestampMode(tmRebased);

  AssertTrue('client target helper failed',
    Config.TargetURL = 'rtmp://127.0.0.1:1935/live/fallback');
  AssertTrue('client app helper failed', Config.App = 'live');
  AssertTrue('client stream helper failed', Config.StreamKey = 'override-key');
  AssertTrue('client connect timeout helper failed', Config.ConnectTimeoutMS = 1234);
  AssertTrue('client enhanced codec helper failed',
    Config.EnhancedCodecs = 'hvc1,av01,Opus');
  AssertTrue('client enhanced capabilities helper failed',
    Config.EnhancedCapabilities =
      (RTMP_CAPS_EX_MULTITRACK OR RTMP_CAPS_EX_MODEX));
  AssertTrue('client required audio track helper failed',
    Config.RequiredAudioTrackID = 1);
  AssertTrue('client TLS verification helper failed',
    (NOT Config.Tls.VerifyPeer) AND (Config.Tls.CAFile = 'custom-ca.pem'));
  AssertTrue('client reconnect helper failed', Config.ReconnectDelayMS = 250);
  AssertTrue('client max reconnect helper failed', Config.MaxReconnectDelayMS = 4000);
  AssertTrue('client reconnect boundary helper failed',
    Config.ReconnectBoundaryTimeoutMS = 1750);
  AssertTrue('client out chunk helper failed', Config.OutChunkSize = 2048);
  AssertTrue('client timestamp helper failed', Config.TimestampMode = tmRebased);

  Client:=TRtmpClient.Create(Config);
  try
    AssertTrue('client config constructor failed', Client.Config.StreamKey = 'override-key');
    AssertTrue('client starts stopped', Client.State = csStopped);
  finally
    Client.Free;
  end;

  Config.EnhancedCodecs:='invalid';
  Client:=TRtmpClient.Create(Config);
  InvalidRejected:=False;
  try
    try
      Client.Start;
    except
      on E: Exception do
        InvalidRejected:=Pos('exactly four ASCII characters', E.Message) > 0;
    end;
  finally
    Client.Free;
  end;
  AssertTrue('invalid enhanced FourCC was not rejected synchronously',
    InvalidRejected);

  Config.EnhancedCodecs:=RTMP_DEFAULT_ENHANCED_CODECS;
  Config.RequiredAudioTrackID:=256;
  Client:=TRtmpClient.Create(Config);
  InvalidRejected:=False;
  try
    try
      Client.Start;
    except
      on E: ERangeError do
        InvalidRejected:=Pos('outside -1..255', E.Message) > 0;
    end;
  finally
    Client.Free;
  end;
  AssertTrue('invalid required audio track was not rejected synchronously',
    InvalidRejected);

  Config.RequiredAudioTrackID:=-1;
  Config.ReconnectBoundaryTimeoutMS:=-1;
  Client:=TRtmpClient.Create(Config);
  InvalidRejected:=False;
  try
    try
      Client.Start;
    except
      on E: ERangeError do
        InvalidRejected:=Pos('must not be negative', E.Message) > 0;
    end;
  finally
    Client.Free;
  end;
  AssertTrue('negative reconnect boundary timeout was not rejected synchronously',
    InvalidRejected);
end;

begin
  TestServerConfigFluentApi;
  TestClientConfigFluentApi;
  WriteLn('API ergonomics smoke passed.');
end.

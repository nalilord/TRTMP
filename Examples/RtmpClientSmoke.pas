program RtmpClientSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  {$IFDEF UNIX}
  {$IFDEF FPC}
  cthreads,
  {$ENDIF}
  {$ENDIF}
  SysUtils,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Client,
  TRTMP.RTMP.Protocol.FLV,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Server.Session,
  TRTMP.Transport,
  TRTMP.Transport.Native,
  TRTMP.Transport.TLS,
  TRTMP.RTMP.Types;

type
  TTestTlsTransportFactory = class(TInterfacedObject, IRtmpTransportFactory,
    IRtmpTlsTransportFactory)
  private
    FInner: IRtmpTransportFactory;
    FLastClientOptions: TRtmpTlsClientOptions;
    FLastServerOptions: TRtmpTlsServerOptions;
    FTlsClientCalls: Integer;
    FTlsListenerCalls: Integer;
  public
    constructor Create;
    function CreateClientConnection(const ARemoteEndpoint: TRtmpSocketEndpoint;
      AConnectTimeoutMS: Integer): IRtmpConnection;
    function CreateListener(const ABindEndpoint: TRtmpSocketEndpoint;
      ABacklog: Integer): IRtmpListener;
    function CreateTlsClientConnection(
      const ARemoteEndpoint: TRtmpSocketEndpoint;
      const AOptions: TRtmpTlsClientOptions;
      AConnectTimeoutMS: Integer): IRtmpConnection;
    function CreateTlsListener(const ABindEndpoint: TRtmpSocketEndpoint;
      ABacklog: Integer; const AOptions: TRtmpTlsServerOptions): IRtmpListener;
    function Description: string;
    function TlsDescription: string;
    property LastClientOptions: TRtmpTlsClientOptions read FLastClientOptions;
    property LastServerOptions: TRtmpTlsServerOptions read FLastServerOptions;
    property TlsClientCalls: Integer read FTlsClientCalls;
    property TlsListenerCalls: Integer read FTlsListenerCalls;
  end;

  TSmokeApp = class
  private
    FClient: TRtmpClient;
    FEnhancedCodecs: string;
    FEnhancedCapabilities: UInt32;
    FPacketsReceived: Integer;
    FPublishStarted: Boolean;
    FSawModEx: Boolean;
    FSawMultitrack: Boolean;
    FSawVodAudioConfig: Boolean;
    FServer: TRtmpServer;
    FSourceBuffer: TRtmpCircularBuffer;
    FTlsFactory: TTestTlsTransportFactory;
    procedure HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure SeedSourceBuffer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TTestTlsTransportFactory.Create;
begin
  inherited Create;
  FInner:=TRtmpNativeTransportFactory.Create;
  FLastClientOptions:=TRtmpTlsClientOptions.CreateDefault;
  FLastServerOptions:=TRtmpTlsServerOptions.CreateDefault;
  FTlsClientCalls:=0;
  FTlsListenerCalls:=0;
end;

function TTestTlsTransportFactory.CreateClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Result:=FInner.CreateClientConnection(ARemoteEndpoint, AConnectTimeoutMS);
end;

function TTestTlsTransportFactory.CreateListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer): IRtmpListener;
begin
  Result:=FInner.CreateListener(ABindEndpoint, ABacklog);
end;

function TTestTlsTransportFactory.CreateTlsClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  const AOptions: TRtmpTlsClientOptions;
  AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Inc(FTlsClientCalls);
  FLastClientOptions:=AOptions;
  Result:=FInner.CreateClientConnection(ARemoteEndpoint, AConnectTimeoutMS);
end;

function TTestTlsTransportFactory.CreateTlsListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer;
  const AOptions: TRtmpTlsServerOptions): IRtmpListener;
begin
  Inc(FTlsListenerCalls);
  FLastServerOptions:=AOptions;
  Result:=FInner.CreateListener(ABindEndpoint, ABacklog);
end;

function TTestTlsTransportFactory.Description: string;
begin
  Result:='test delegating transport';
end;

function TTestTlsTransportFactory.TlsDescription: string;
begin
  Result:='test TLS dispatch provider';
end;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result:=nil;
  SetLength(Result, Length(AValues));
  for I:=0 to High(AValues) do
    Result[I]:=AValues[I];
end;

function BytesEqual(const ALeft, ARight: TBytes): Boolean;
var
  I: Integer;
begin
  Result:=Length(ALeft) = Length(ARight);
  if NOT Result then
    Exit;
  for I:=0 to High(ALeft) do
    if ALeft[I] <> ARight[I] then
      Exit(False);
end;

constructor TSmokeApp.Create;
var
  ClientConfig: TRtmpClientConfig;
  Config: TRtmpServerConfig;
begin
  inherited Create;
  FSourceBuffer:=TRtmpCircularBuffer.Create(64, 2 * 1024 * 1024);
  FServer:=TRtmpServer.Create;
  FClient:=TRtmpClient.Create;
  FTlsFactory:=TTestTlsTransportFactory.Create;
  FClient.TransportFactory:=FTlsFactory;
  FServer.TransportFactory:=FTlsFactory;
  FPacketsReceived:=0;
  FEnhancedCodecs:='';
  FEnhancedCapabilities:=0;
  FPublishStarted:=False;
  FSawModEx:=False;
  FSawMultitrack:=False;
  FSawVodAudioConfig:=False;

  Config:=DefaultRtmpServerConfig;
  Config.BindAddress:='127.0.0.1';
  Config.Port:=1940;
  Config.BufferMaxPackets:=128;
  Config.BufferMaxBytes:=4 * 1024 * 1024;
  Config.EnhancedCapabilities:=RTMP_DEFAULT_ENHANCED_CAPABILITIES;
  Config.Tls.Enabled:=True;
  Config.Tls.CertificateFile:='test-server-cert.pem';
  Config.Tls.CertificatePassword:='test-server-password';
  Config.Tls.PrivateKeyFile:='test-server-key.pem';
  FServer.Config:=Config;
  FServer.OnData:=HandleData;
  FServer.OnPublishStarted:=HandlePublishStarted;
  FServer.LogSink.OnLog:=HandleServerLog;

  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig:=DefaultRtmpClientConfig;
  ClientConfig.TargetURL:='rtmps://127.0.0.1:1940/live/test';
  ClientConfig.OutChunkSize:=4096;
  ClientConfig.EnhancedCodecs:='hvc1,Opus';
  ClientConfig.EnhancedCapabilities:=RTMP_DEFAULT_ENHANCED_CAPABILITIES;
  ClientConfig.RequiredAudioTrackID:=1;
  ClientConfig.Tls.CAFile:='test-ca.pem';
  ClientConfig.Tls.CertificateFile:='test-client-cert.pem';
  ClientConfig.Tls.CertificatePassword:='test-client-password';
  ClientConfig.Tls.PrivateKeyFile:='test-client-key.pem';
  FClient.Config:=ClientConfig;
  FClient.LogSink.OnLog:=HandleClientLog;
end;

destructor TSmokeApp.Destroy;
begin
  FClient.Free;
  FServer.Free;
  FSourceBuffer.Free;
  inherited Destroy;
end;

procedure TSmokeApp.HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  WriteLn(Format('[CLIENT] %s: %s', [ACategory, AMessage]));
end;

procedure TSmokeApp.HandleData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
var
  Actual: TBytes;
  Expected: TBytes;
  Info: TRtmpFlvTagInfo;
begin
  Inc(FPacketsReceived);
  Info:=Default(TRtmpFlvTagInfo);
  if NOT RtmpInspectFlvTag(Packet.MessageType, Packet.Payload.Bytes, Info) then
    Exit;
  Actual:=Packet.Payload.Bytes;
  if Info.IsMultitrack AND Packet.HasFlag(pfIsVideo) then
  begin
    Expected:=Bytes([$96, $11, Ord('v'), Ord('p'), Ord('0'), Ord('9'),
      $00, $00, $00, $01, $82,
      $01, $00, $00, $01, $83]);
    if NOT BytesEqual(Actual, Expected) then
      raise Exception.Create('relayed multitrack payload changed');
    FSawMultitrack:=True;
  end;
  if Packet.HasFlag(pfIsAudio) AND Packet.HasFlag(pfIsCodecConfig) AND
    Info.IsMultitrack AND (Info.TrackCount = 1) AND
    (Info.Tracks[0].TrackID = 1) then
    FSawVodAudioConfig:=True;
  if Info.IsModEx then
  begin
    Expected:=Bytes([$97, $02, $00, $00, $05, $01,
      Ord('O'), Ord('p'), Ord('u'), Ord('s'), $AA]);
    if NOT BytesEqual(Actual, Expected) then
      raise Exception.Create('relayed ModEx payload changed');
    FSawModEx:=True;
  end;
end;

procedure TSmokeApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  FPublishStarted:=True;
  FEnhancedCodecs:=Session.EnhancedCodecs;
  FEnhancedCapabilities:=Session.EnhancedCapabilities;
end;

procedure TSmokeApp.HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  WriteLn(Format('[SERVER] %s: %s', [ACategory, AMessage]));
end;

procedure TSmokeApp.SeedSourceBuffer;
var
  Packet: TRtmpPacket;
begin
  Packet:=TRtmpPacket.Create(mtDataAMF0, 0, 0, 1, 5,
    TRtmpSharedPayload.Create(Bytes([$12, 0, 1, 2])), [pfIsMetadata], 0);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtAudio, 0, 0, 1, 4,
    TRtmpSharedPayload.Create(Bytes([$AF, $00, $12, $10])),
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], 1);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtAudio, 0, 0, 1, 4,
    TRtmpSharedPayload.Create(Bytes([
      $95, $00, Ord('m'), Ord('p'), Ord('4'), Ord('a'), $01, $12, $10])),
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], 2);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $00, $00, $00, $00, $01, $64, $00, $1E])),
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], 3);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtVideo, 40, 40, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $01, $00, $00, $00, $09, $10, $11, $12, $13])),
    [pfIsVideo, pfIsKeyframe], 4);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtVideo, 80, 40, 1, 6,
    TRtmpSharedPayload.Create(Bytes([
      $96, $11, Ord('v'), Ord('p'), Ord('0'), Ord('9'),
      $00, $00, $00, $01, $82,
      $01, $00, $00, $01, $83])),
    [pfIsVideo, pfIsKeyframe], 5);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtAudio, 80, 0, 1, 4,
    TRtmpSharedPayload.Create(Bytes([
      $97, $02, $00, $00, $05, $01,
      Ord('O'), Ord('p'), Ord('u'), Ord('s'), $AA])),
    [pfIsAudio], 6);
  FSourceBuffer.Push(Packet);
end;

procedure TSmokeApp.Run;
var
  Deadline: UInt64;
begin
  SeedSourceBuffer;
  FServer.Start;
  try
    FClient.Start;
    try
      Deadline:=RtmpGetTickCount64 + 4000;
      while RtmpGetTickCount64 < Deadline do
      begin
        if FPublishStarted AND (FPacketsReceived >= 6) then
          Break;
        Sleep(50);
      end;
    finally
      FClient.Stop;
    end;
  finally
    FServer.Stop;
  end;

  if NOT FPublishStarted then
    raise Exception.Create('Smoke test failed: publish did not start');
  if FPacketsReceived < 6 then
    raise Exception.CreateFmt('Smoke test failed: expected >=6 packets, got %d',
      [FPacketsReceived]);
  if NOT FSawMultitrack then
    raise Exception.Create('Smoke test failed: multitrack packet was not relayed');
  if NOT FSawModEx then
    raise Exception.Create('Smoke test failed: ModEx packet was not relayed');
  if NOT FSawVodAudioConfig then
    raise Exception.Create('Smoke test failed: Twitch VOD audio config was not relayed');
  if FEnhancedCodecs <> 'hvc1,Opus' then
    raise Exception.CreateFmt(
      'Smoke test failed: enhanced codecs mismatch: expected "%s", got "%s"',
      ['hvc1,Opus', FEnhancedCodecs]);
  if FEnhancedCapabilities <> RTMP_DEFAULT_ENHANCED_CAPABILITIES then
    raise Exception.CreateFmt(
      'Smoke test failed: publisher capsEx mismatch: expected 0x%s, got 0x%s',
      [IntToHex(RTMP_DEFAULT_ENHANCED_CAPABILITIES, 8),
       IntToHex(FEnhancedCapabilities, 8)]);
  if FClient.PeerEnhancedCapabilities <> RTMP_DEFAULT_ENHANCED_CAPABILITIES then
    raise Exception.CreateFmt(
      'Smoke test failed: server capsEx mismatch: expected 0x%s, got 0x%s',
      [IntToHex(RTMP_DEFAULT_ENHANCED_CAPABILITIES, 8),
       IntToHex(FClient.PeerEnhancedCapabilities, 8)]);
  if FTlsFactory.TlsClientCalls <> 1 then
    raise Exception.CreateFmt(
      'Smoke test failed: expected one TLS client dispatch, got %d',
      [FTlsFactory.TlsClientCalls]);
  if FTlsFactory.TlsListenerCalls <> 1 then
    raise Exception.CreateFmt(
      'Smoke test failed: expected one TLS listener dispatch, got %d',
      [FTlsFactory.TlsListenerCalls]);
  if NOT FTlsFactory.LastClientOptions.VerifyPeer then
    raise Exception.Create('Smoke test failed: TLS peer verification was disabled');
  if FTlsFactory.LastClientOptions.ServerName <> '127.0.0.1' then
    raise Exception.CreateFmt(
      'Smoke test failed: TLS server name mismatch: %s',
      [FTlsFactory.LastClientOptions.ServerName]);
  if FTlsFactory.LastClientOptions.CAFile <> 'test-ca.pem' then
    raise Exception.Create('Smoke test failed: TLS CA file was not forwarded');
  if (FTlsFactory.LastClientOptions.CertificateFile <>
      'test-client-cert.pem') OR
     (FTlsFactory.LastClientOptions.CertificatePassword <>
      'test-client-password') OR
     (FTlsFactory.LastClientOptions.PrivateKeyFile <>
      'test-client-key.pem') then
    raise Exception.Create(
      'Smoke test failed: TLS client credentials were not forwarded');
  if (FTlsFactory.LastServerOptions.CertificateFile <> 'test-server-cert.pem') OR
    (FTlsFactory.LastServerOptions.CertificatePassword <>
      'test-server-password') OR
    (FTlsFactory.LastServerOptions.PrivateKeyFile <> 'test-server-key.pem') then
    raise Exception.Create('Smoke test failed: TLS server credentials were not forwarded');

  WriteLn(Format(
    'Smoke test passed: publishStarted=%s packetsReceived=%d enhancedCodecs=%s capsEx=0x%s tlsClient=%d tlsListener=%d',
    [BoolToStr(FPublishStarted, True), FPacketsReceived, FEnhancedCodecs,
     IntToHex(FEnhancedCapabilities, 8), FTlsFactory.TlsClientCalls,
     FTlsFactory.TlsListenerCalls]));
end;

var
  App: TSmokeApp;

begin
  App:=TSmokeApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

program RtmpCodecRelayProbe;

{$IFDEF MSWINDOWS}
  {$APPTYPE CONSOLE}
{$ENDIF}

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
  TRTMP.RTMP.Client,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Protocol.FLV,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Server.Session,
  TRTMP.RTMP.Types;

type
  TRelayProbe = class
  private
    FClient: TRtmpClient;
    FClientConnected: Boolean;
    FDownstream: TRtmpServer;
    FIngest: TRtmpServer;
    FRelayBytes: UInt64;
    FRelayDigest: UInt64;
    FRelayPackets: UInt64;
    FRelaySeenAudio: Boolean;
    FRelaySeenVideo: Boolean;
    FSourceBytes: UInt64;
    FSourceDigest: UInt64;
    FSourcePackets: UInt64;
    FSourceSeenAudio: Boolean;
    FSourceSeenVideo: Boolean;
    procedure DigestByte(var ADigest: UInt64; AValue: Byte);
    procedure DigestPacket(var ADigest: UInt64; const APacket: TRtmpPacket);
    function PayloadHash(const APacket: TRtmpPacket): UInt64;
    function FourCCOrLegacy(const AInfo: TRtmpFlvTagInfo;
      AMessageType: TRtmpMessageType): string;
    procedure HandleClientConnected(Sender: TObject);
    procedure HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleDownstreamLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleRelayData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleRelayPublishStarted(Sender: TObject;
      Session: TRtmpServerSession);
    procedure HandleSourceData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleSourceLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure LogMedia(const APrefix: string; Session: TRtmpServerSession;
      Packet: TRtmpPacket; var ASeenAudio, ASeenVideo: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(AIngestPort, ADownstreamPort: Word;
      const AStreamName, ACertificateFile, APrivateKeyFile, ACAFile,
      ACertificatePassword: string);
  end;

const
  FNV_OFFSET_BASIS: UInt64 = 14695981039346656037;
  FNV_PRIME: UInt64 = 1099511628211;

constructor TRelayProbe.Create;
begin
  inherited Create;
  FIngest:=TRtmpServer.Create;
  FDownstream:=TRtmpServer.Create;
  FClient:=TRtmpClient.Create;
  FSourceDigest:=FNV_OFFSET_BASIS;
  FRelayDigest:=FNV_OFFSET_BASIS;
  FIngest.OnData:=HandleSourceData;
  FIngest.LogSink.OnLog:=HandleSourceLog;
  FDownstream.OnData:=HandleRelayData;
  FDownstream.OnPublishStarted:=HandleRelayPublishStarted;
  FDownstream.LogSink.OnLog:=HandleDownstreamLog;
  FClient.OnConnected:=HandleClientConnected;
  FClient.LogSink.OnLog:=HandleClientLog;
end;

function TRelayProbe.PayloadHash(const APacket: TRtmpPacket): UInt64;
var
  Bytes: TBytes;
  I: Integer;
begin
  Result:=FNV_OFFSET_BASIS;
  if NOT Assigned(APacket.Payload) then
    Exit;
  Bytes:=APacket.Payload.Bytes;
  for I:=0 to High(Bytes) do
    DigestByte(Result, Bytes[I]);
end;

destructor TRelayProbe.Destroy;
begin
  FClient.Free;
  FIngest.Free;
  FDownstream.Free;
  inherited Destroy;
end;

procedure TRelayProbe.DigestByte(var ADigest: UInt64; AValue: Byte);
begin
  ADigest:=(ADigest XOR UInt64(AValue)) * FNV_PRIME;
end;

procedure TRelayProbe.DigestPacket(var ADigest: UInt64;
  const APacket: TRtmpPacket);
var
  Bytes: TBytes;
  I: Integer;
  Value: UInt32;
begin
  DigestByte(ADigest, Byte(Ord(APacket.MessageType)));
  Value:=APacket.Timestamp;
  DigestByte(ADigest, Byte(Value SHR 24));
  DigestByte(ADigest, Byte(Value SHR 16));
  DigestByte(ADigest, Byte(Value SHR 8));
  DigestByte(ADigest, Byte(Value));
  Value:=UInt32(APacket.PayloadSize);
  DigestByte(ADigest, Byte(Value SHR 24));
  DigestByte(ADigest, Byte(Value SHR 16));
  DigestByte(ADigest, Byte(Value SHR 8));
  DigestByte(ADigest, Byte(Value));
  if Assigned(APacket.Payload) then
  begin
    Bytes:=APacket.Payload.Bytes;
    for I:=0 to High(Bytes) do
      DigestByte(ADigest, Bytes[I]);
  end;
end;

function TRelayProbe.FourCCOrLegacy(const AInfo: TRtmpFlvTagInfo;
  AMessageType: TRtmpMessageType): string;
begin
  if AInfo.IsEnhanced then
    Exit(AInfo.CodecFourCC);
  if AMessageType = mtAudio then
    case AInfo.AudioCodecID of
      2: Result:='mp3';
      10: Result:='aac';
    else
      Result:='unknown';
    end
  else
    case AInfo.VideoCodecID of
      7: Result:='avc1';
    else
      Result:='unknown';
    end;
end;

procedure TRelayProbe.HandleClientConnected(Sender: TObject);
begin
  FClientConnected:=True;
end;

procedure TRelayProbe.HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  if ALevel >= llWarning then
  begin
    WriteLn(Format('CLIENT_LOG level=%d category=%s message=%s',
      [Ord(ALevel), ACategory, AMessage]));
    Flush(Output);
  end;
end;

procedure TRelayProbe.HandleDownstreamLog(Sender: TObject;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
begin
  if ALevel >= llWarning then
  begin
    WriteLn(Format('DOWNSTREAM_LOG level=%d category=%s message=%s',
      [Ord(ALevel), ACategory, AMessage]));
    Flush(Output);
  end;
end;

procedure TRelayProbe.HandleRelayData(Sender: TObject;
  Session: TRtmpServerSession; Packet: TRtmpPacket);
begin
  Inc(FRelayPackets);
  Inc(FRelayBytes, UInt64(Packet.PayloadSize));
  DigestPacket(FRelayDigest, Packet);
  LogMedia('RELAY_MEDIA', Session, Packet, FRelaySeenAudio, FRelaySeenVideo);
end;

procedure TRelayProbe.HandleRelayPublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('RELAY_CONNECT stream=%s enhancedCodecs=%s',
    [Session.StreamName, Session.EnhancedCodecs]));
  Flush(Output);
end;

procedure TRelayProbe.HandleSourceData(Sender: TObject;
  Session: TRtmpServerSession; Packet: TRtmpPacket);
begin
  Inc(FSourcePackets);
  Inc(FSourceBytes, UInt64(Packet.PayloadSize));
  DigestPacket(FSourceDigest, Packet);
  LogMedia('SOURCE_MEDIA', Session, Packet, FSourceSeenAudio, FSourceSeenVideo);
end;

procedure TRelayProbe.HandleSourceLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  if ALevel >= llWarning then
  begin
    WriteLn(Format('SOURCE_LOG level=%d category=%s message=%s',
      [Ord(ALevel), ACategory, AMessage]));
    Flush(Output);
  end;
end;

procedure TRelayProbe.LogMedia(const APrefix: string;
  Session: TRtmpServerSession; Packet: TRtmpPacket;
  var ASeenAudio, ASeenVideo: Boolean);
var
  Codec: string;
  Info: TRtmpFlvTagInfo;
  Media: string;
  PacketType: Integer;
  ShouldLog: Boolean;
  Signaling: string;
begin
  if NOT (Packet.MessageType IN [mtAudio, mtVideo]) OR
    NOT Assigned(Packet.Payload) OR (Packet.Payload.Size = 0) then
    Exit;

  Info:=Default(TRtmpFlvTagInfo);
  RtmpInspectFlvTag(Packet.MessageType, Packet.Payload.Bytes, Info);
  Codec:=FourCCOrLegacy(Info, Packet.MessageType);
  if Info.IsEnhanced then
    Signaling:='enhanced'
  else
    Signaling:='legacy';

  if Packet.MessageType = mtAudio then
  begin
    Media:='audio';
    ShouldLog:=(NOT ASeenAudio) OR Packet.HasFlag(pfIsCodecConfig);
    ASeenAudio:=True;
    PacketType:=Info.AudioPacketType;
  end
  else
  begin
    Media:='video';
    ShouldLog:=(NOT ASeenVideo) OR Packet.HasFlag(pfIsCodecConfig) OR
      Packet.HasFlag(pfIsKeyframe);
    ASeenVideo:=True;
    PacketType:=Info.VideoPacketType;
  end;
  if NOT ShouldLog then
    Exit;

  WriteLn(Format(
    '%s stream=%s media=%s signaling=%s codec=%s packetType=%d frameType=%d ts=%d size=%d payloadHash=%s libEnhanced=%s libConfig=%s libSequence=%s libKeyframe=%s',
    [APrefix, Session.StreamName, Media,
     Signaling, Codec, PacketType, Info.VideoFrameType, Packet.Timestamp,
     Packet.PayloadSize, IntToHex(PayloadHash(Packet), 16),
     BoolToStr(Info.IsEnhanced, True),
     BoolToStr(Packet.HasFlag(pfIsCodecConfig), True),
     BoolToStr(Packet.HasFlag(pfIsSequenceHeader), True),
     BoolToStr(Packet.HasFlag(pfIsKeyframe), True)]));
  Flush(Output);
end;

procedure TRelayProbe.Run(AIngestPort, ADownstreamPort: Word;
  const AStreamName, ACertificateFile, APrivateKeyFile, ACAFile,
  ACertificatePassword: string);
var
  ClientConfig: TRtmpClientConfig;
  Deadline: UInt64;
  DownstreamConfig: TRtmpServerConfig;
  IngestConfig: TRtmpServerConfig;
begin
  DownstreamConfig:=DefaultRtmpServerConfig;
  DownstreamConfig.BindAddress:='127.0.0.1';
  DownstreamConfig.Port:=ADownstreamPort;
  DownstreamConfig.BufferMaxPackets:=8192;
  DownstreamConfig.BufferMaxBytes:=64 * 1024 * 1024;
  if ACertificateFile <> '' then
  begin
    DownstreamConfig.Tls.Enabled:=True;
    DownstreamConfig.Tls.CertificateFile:=ACertificateFile;
    DownstreamConfig.Tls.CertificatePassword:=ACertificatePassword;
    DownstreamConfig.Tls.PrivateKeyFile:=APrivateKeyFile;
  end;
  FDownstream.Config:=DownstreamConfig;

  IngestConfig:=DefaultRtmpServerConfig;
  IngestConfig.BindAddress:='127.0.0.1';
  IngestConfig.Port:=AIngestPort;
  IngestConfig.BufferMaxPackets:=8192;
  IngestConfig.BufferMaxBytes:=64 * 1024 * 1024;
  IngestConfig.Tls:=DownstreamConfig.Tls;
  FIngest.Config:=IngestConfig;

  FClient.AttachBuffer(FIngest.Buffer);
  ClientConfig:=DefaultRtmpClientConfig;
  if DownstreamConfig.Tls.Enabled then
  begin
    ClientConfig.TargetURL:=Format('rtmps://127.0.0.1:%d/live/%s',
      [ADownstreamPort, AStreamName]);
    ClientConfig.Tls.CAFile:=ACAFile;
  end
  else
    ClientConfig.TargetURL:=Format('rtmp://127.0.0.1:%d/live/%s',
      [ADownstreamPort, AStreamName]);
  ClientConfig.TimestampMode:=tmPassThrough;
  ClientConfig.ReconnectDelayMS:=100;
  ClientConfig.MaxReconnectDelayMS:=500;
  FClient.Config:=ClientConfig;

  FDownstream.Start;
  try
    FIngest.Start;
    try
      FClient.Start;
      Deadline:=RtmpGetTickCount64 + 5000;
      while (NOT FClientConnected) AND (RtmpGetTickCount64 < Deadline) do
        RtmpSleepMS(10);
      if NOT FClientConnected then
        raise Exception.Create('Relay client did not establish downstream publish');

      WriteLn(Format(
        'RELAY_READY ingestPort=%d downstreamPort=%d stream=%s enhancedCodecs=%s tls=%s',
        [AIngestPort, ADownstreamPort, AStreamName,
         ClientConfig.EnhancedCodecs,
         BoolToStr(DownstreamConfig.Tls.Enabled, True)]));
      Flush(Output);
      ReadLn;
      RtmpSleepMS(250);
      FClient.Stop;
    finally
      FIngest.Stop;
    end;
  finally
    FDownstream.Stop;
  end;

  WriteLn(Format(
    'RELAY_SUMMARY sourcePackets=%d relayPackets=%d sourceBytes=%d relayBytes=%d sourceDigest=%s relayDigest=%s',
    [FSourcePackets, FRelayPackets, FSourceBytes, FRelayBytes,
     IntToHex(FSourceDigest, 16), IntToHex(FRelayDigest, 16)]));
end;

var
  CAFile: string;
  CertificateFile: string;
  CertificatePassword: string;
  DownstreamPort: Integer;
  IngestPort: Integer;
  PrivateKeyFile: string;
  Probe: TRelayProbe;
  StreamName: string;
begin
  IngestPort:=1940;
  DownstreamPort:=1950;
  StreamName:='relay';
  if ParamCount >= 1 then
    IngestPort:=StrToIntDef(ParamStr(1), IngestPort);
  if ParamCount >= 2 then
    DownstreamPort:=StrToIntDef(ParamStr(2), DownstreamPort);
  if ParamCount >= 3 then
    StreamName:=Trim(ParamStr(3));
  CertificateFile:=ParamStr(4);
  PrivateKeyFile:=ParamStr(5);
  CAFile:=ParamStr(6);
  CertificatePassword:=ParamStr(7);
  if CertificateFile = '-' then
    CertificateFile:='';
  if PrivateKeyFile = '-' then
    PrivateKeyFile:='';
  if CAFile = '-' then
    CAFile:='';
  if (IngestPort < 1) OR (IngestPort > 65535) OR
    (DownstreamPort < 1) OR (DownstreamPort > 65535) OR
    (IngestPort = DownstreamPort) then
    raise Exception.Create('Invalid or conflicting relay probe ports');
  if StreamName = '' then
    raise Exception.Create('Relay stream name must not be empty');

  Probe:=TRelayProbe.Create;
  try
    Probe.Run(Word(IngestPort), Word(DownstreamPort), StreamName,
      CertificateFile, PrivateKeyFile, CAFile, CertificatePassword);
  finally
    Probe.Free;
  end;
end.

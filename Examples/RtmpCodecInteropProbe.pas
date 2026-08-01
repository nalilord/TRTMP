program RtmpCodecInteropProbe;

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
  Classes,
  SysUtils,
  TRTMP.RTMP.Protocol.FLV,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Server.Session,
  TRTMP.RTMP.Types;

type
  TCodecProbe = class
  private
    FAudioPackets: UInt64;
    FSeenStreams: TStringList;
    FServer: TRtmpServer;
    FVideoPackets: UInt64;
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    function FourCC(const ABytes: TBytes; AOffset: Integer): string;
    function LegacyAudioCodec(AID: Byte): string;
    function LegacyVideoCodec(AID: Byte): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(APort: Word; const ACertificateFile,
      APrivateKeyFile, ACertificatePassword: string);
  end;

constructor TCodecProbe.Create;
begin
  inherited Create;
  FServer:=TRtmpServer.Create;
  FSeenStreams:=TStringList.Create;
  FServer.MinLogLevel:=llWarning;
  FServer.LogSink.OnLog:=HandleLog;
  FServer.OnData:=HandleData;
end;

destructor TCodecProbe.Destroy;
begin
  FServer.Free;
  FSeenStreams.Free;
  inherited Destroy;
end;

function TCodecProbe.FourCC(const ABytes: TBytes; AOffset: Integer): string;
var
  I: Integer;
begin
  Result:='';
  if (AOffset < 0) OR (AOffset + 4 > Length(ABytes)) then
    Exit;
  for I:=AOffset to AOffset + 3 do
    if (ABytes[I] >= 32) AND (ABytes[I] <= 126) then
      Result:=Result + Chr(ABytes[I])
    else
      Result:=Result + '?';
end;

function TCodecProbe.LegacyAudioCodec(AID: Byte): string;
begin
  case AID of
    2: Result:='mp3';
    10: Result:='aac';
  else
    Result:='unknown';
  end;
end;

function TCodecProbe.LegacyVideoCodec(AID: Byte): string;
begin
  case AID of
    2: Result:='flv1';
    4: Result:='vp6f';
    5: Result:='vp6a';
    7: Result:='avc1';
  else
    Result:='unknown';
  end;
end;

procedure TCodecProbe.HandleData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
var
  Bytes: TBytes;
  Codec: string;
  FrameType: Integer;
  Info: TRtmpFlvTagInfo;
  PacketType: Integer;
  ShouldLog: Boolean;
  Signaling: string;
  StreamMediaKey: string;
begin
  if (Packet = nil) OR NOT (Packet.MessageType IN [mtAudio, mtVideo]) OR
    NOT Assigned(Packet.Payload) OR (Packet.Payload.Size = 0) then
    Exit;

  Bytes:=Packet.Payload.Bytes;
  Codec:='unknown';
  FrameType:=-1;
  PacketType:=-1;
  Signaling:='legacy';
  Info:=Default(TRtmpFlvTagInfo);
  RtmpInspectFlvTag(Packet.MessageType, Bytes, Info);

  if Packet.MessageType = mtAudio then
  begin
    Inc(FAudioPackets);
    if ((Bytes[0] SHR 4) AND $0F) = 9 then
    begin
      Signaling:='enhanced';
      PacketType:=Bytes[0] AND $0F;
      Codec:=FourCC(Bytes, 1);
    end
    else
    begin
      Codec:=LegacyAudioCodec(Info.AudioCodecID);
      PacketType:=Info.AACPacketType;
    end;
    StreamMediaKey:=Session.StreamName + '|audio';
    ShouldLog:=(FSeenStreams.IndexOf(StreamMediaKey) < 0) OR
      Packet.HasFlag(pfIsCodecConfig) OR Packet.HasFlag(pfIsSequenceHeader);
    if NOT ShouldLog then
      Exit;
    if FSeenStreams.IndexOf(StreamMediaKey) < 0 then
      FSeenStreams.Add(StreamMediaKey);
    WriteLn(Format(
      'MEDIA stream=%s media=audio signaling=%s codec=%s packetType=%d header=%s libCodecId=%d libEnhanced=%s libFourCC=%s libPacketType=%d libConfig=%s libSequence=%s',
      [Session.StreamName, Signaling, Codec, PacketType, IntToHex(Bytes[0], 2),
       Info.AudioCodecID, BoolToStr(Info.IsEnhanced, True), Info.CodecFourCC,
       Info.AudioPacketType, BoolToStr(Packet.HasFlag(pfIsCodecConfig), True),
       BoolToStr(Packet.HasFlag(pfIsSequenceHeader), True)]));
    Flush(Output);
  end
  else
  begin
    Inc(FVideoPackets);
    if (Bytes[0] AND $80) <> 0 then
    begin
      Signaling:='enhanced';
      FrameType:=(Bytes[0] SHR 4) AND $07;
      PacketType:=Bytes[0] AND $0F;
      Codec:=FourCC(Bytes, 1);
    end
    else
    begin
      Codec:=LegacyVideoCodec(Info.VideoCodecID);
      FrameType:=Info.VideoFrameType;
      PacketType:=Info.AVCPacketType;
    end;
    StreamMediaKey:=Session.StreamName + '|video';
    ShouldLog:=(FSeenStreams.IndexOf(StreamMediaKey) < 0) OR
      Packet.HasFlag(pfIsCodecConfig) OR Packet.HasFlag(pfIsSequenceHeader);
    if NOT ShouldLog then
      Exit;
    if FSeenStreams.IndexOf(StreamMediaKey) < 0 then
      FSeenStreams.Add(StreamMediaKey);
    WriteLn(Format(
      'MEDIA stream=%s media=video signaling=%s codec=%s packetType=%d frameType=%d header=%s libCodecId=%d libEnhanced=%s libFourCC=%s libPacketType=%d libConfig=%s libSequence=%s libKeyframe=%s',
      [Session.StreamName, Signaling, Codec, PacketType, FrameType,
       IntToHex(Bytes[0], 2), Info.VideoCodecID, BoolToStr(Info.IsEnhanced, True),
       Info.CodecFourCC, Info.VideoPacketType,
       BoolToStr(Packet.HasFlag(pfIsCodecConfig), True),
       BoolToStr(Packet.HasFlag(pfIsSequenceHeader), True),
       BoolToStr(Packet.HasFlag(pfIsKeyframe), True)]));
    Flush(Output);
  end;
end;

procedure TCodecProbe.HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  if ALevel >= llWarning then
    WriteLn(Format('LOG level=%d category=%s message=%s',
      [Ord(ALevel), ACategory, AMessage]));
end;

procedure TCodecProbe.Run(APort: Word; const ACertificateFile,
  APrivateKeyFile, ACertificatePassword: string);
var
  Config: TRtmpServerConfig;
begin
  Config:=DefaultRtmpServerConfig;
  Config.BindAddress:='127.0.0.1';
  Config.Port:=APort;
  Config.BufferMaxPackets:=4096;
  Config.BufferMaxBytes:=32 * 1024 * 1024;
  Config.BufferMaxDurationMS:=5000;
  if ACertificateFile <> '' then
  begin
    Config.Tls.Enabled:=True;
    Config.Tls.CertificateFile:=ACertificateFile;
    Config.Tls.CertificatePassword:=ACertificatePassword;
    Config.Tls.PrivateKeyFile:=APrivateKeyFile;
  end;
  FServer.Config:=Config;
  FServer.Start;
  WriteLn(Format('PROBE_READY port=%d tls=%s',
    [APort, BoolToStr(Config.Tls.Enabled, True)]));
  Flush(Output);
  ReadLn;
  FServer.Stop;
  WriteLn(Format('PROBE_SUMMARY audioPackets=%d videoPackets=%d',
    [FAudioPackets, FVideoPackets]));
end;

var
  CertificateFile: string;
  CertificatePassword: string;
  Port: Integer;
  PrivateKeyFile: string;
  Probe: TCodecProbe;
begin
  Port:=1940;
  if ParamCount > 0 then
    Port:=StrToIntDef(ParamStr(1), Port);
  if (Port < 1) OR (Port > 65535) then
    raise Exception.CreateFmt('Invalid TCP port: %d', [Port]);
  CertificateFile:=ParamStr(2);
  PrivateKeyFile:=ParamStr(3);
  CertificatePassword:=ParamStr(4);
  if CertificateFile = '-' then
    CertificateFile:='';
  if PrivateKeyFile = '-' then
    PrivateKeyFile:='';

  Probe:=TCodecProbe.Create;
  try
    Probe.Run(Word(Port), CertificateFile, PrivateKeyFile,
      CertificatePassword);
  finally
    Probe.Free;
  end;
end.

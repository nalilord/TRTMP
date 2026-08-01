program RtmpEnhancedDecoderProbe;

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
  libavutil_error,
  TRTMP.RTMP.Decode,
  TRTMP.RTMP.Decode.FFmpeg,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Server.Session,
  TRTMP.RTMP.Types;

type
  TEnhancedDecoderProbe = class
  private
    FAC3Frames: UInt64;
    FAV1Frames: UInt64;
    FAudioDecoder: TRtmpFFmpegPacketDecoder;
    FAudioFrames: UInt64;
    FEAC3Frames: UInt64;
    FFLACFrames: UInt64;
    FHEVCFrames: UInt64;
    FLastError: string;
    FOpusFrames: UInt64;
    FServer: TRtmpServer;
    FVideoDecoder: TRtmpFFmpegPacketDecoder;
    FVideoFrames: UInt64;
    FVP9Frames: UInt64;
    procedure DrainDecoder(ADecoder: TRtmpFFmpegPacketDecoder);
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure SubmitPacket(ADecoder: TRtmpFFmpegPacketDecoder;
      Packet: TRtmpPacket);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(APort: Word);
  end;

constructor TEnhancedDecoderProbe.Create;
begin
  inherited Create;
  FAudioDecoder:=TRtmpFFmpegPacketDecoder.Create;
  FVideoDecoder:=TRtmpFFmpegPacketDecoder.Create;
  FAudioDecoder.HardwareMode:=dhmOff;
  FVideoDecoder.HardwareMode:=dhmOff;
  FServer:=TRtmpServer.Create;
  FServer.OnData:=HandleData;
  FServer.LogSink.OnLog:=HandleLog;
end;

destructor TEnhancedDecoderProbe.Destroy;
begin
  FServer.Free;
  FVideoDecoder.Free;
  FAudioDecoder.Free;
  inherited Destroy;
end;

procedure TEnhancedDecoderProbe.DrainDecoder(
  ADecoder: TRtmpFFmpegPacketDecoder);
var
  FrameInfo: TRtmpDecodedFrameInfo;
  ResultCode: Integer;
begin
  while ADecoder.IsOpen do
  begin
    ResultCode:=ADecoder.ReceiveFrame(FrameInfo);
    if ResultCode = AVERROR_EAGAIN then
      Exit;
    if ResultCode = AVERROR_EOF then
      Exit;
    if ResultCode < 0 then
    begin
      FLastError:=ADecoder.LastErrorText;
      WriteLn('DECODE_ERROR message=' + FLastError);
      Flush(Output);
      Exit;
    end;

    if FrameInfo.MediaKind = dmVideo then
      Inc(FVideoFrames)
    else if FrameInfo.MediaKind = dmAudio then
      Inc(FAudioFrames);
    case FrameInfo.Codec of
      dcHEVC: Inc(FHEVCFrames);
      dcAV1: Inc(FAV1Frames);
      dcVP9: Inc(FVP9Frames);
      dcOpus: Inc(FOpusFrames);
      dcFLAC: Inc(FFLACFrames);
      dcAC3: Inc(FAC3Frames);
      dcEAC3: Inc(FEAC3Frames);
    end;
    WriteLn(Format(
      'DECODE_FRAME media=%s codec=%s ts=%d tsNs=%d nano=%d width=%d height=%d rate=%d channels=%d samples=%d keyframe=%s',
      [RtmpDecoderMediaKindName(FrameInfo.MediaKind),
       RtmpDecoderCodecName(FrameInfo.Codec), FrameInfo.TimestampMS,
       FrameInfo.TimestampNS, FrameInfo.TimestampNanoOffset,
       FrameInfo.Width, FrameInfo.Height, FrameInfo.SampleRate,
       FrameInfo.Channels, FrameInfo.SampleCount,
       BoolToStr(FrameInfo.IsKeyframe, True)]));
    Flush(Output);
    ADecoder.UnrefFrame;
  end;
end;

procedure TEnhancedDecoderProbe.HandleData(Sender: TObject;
  Session: TRtmpServerSession; Packet: TRtmpPacket);
begin
  if Packet.MessageType = mtVideo then
    SubmitPacket(FVideoDecoder, Packet)
  else if Packet.MessageType = mtAudio then
    SubmitPacket(FAudioDecoder, Packet);
end;

procedure TEnhancedDecoderProbe.HandleLog(Sender: TObject;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
begin
  if ALevel >= llWarning then
  begin
    WriteLn(Format('SERVER_LOG level=%d category=%s message=%s',
      [Ord(ALevel), ACategory, AMessage]));
    Flush(Output);
  end;
end;

procedure TEnhancedDecoderProbe.SubmitPacket(
  ADecoder: TRtmpFFmpegPacketDecoder; Packet: TRtmpPacket);
var
  HeaderText: string;
  ResultCode: Integer;
begin
  ResultCode:=ADecoder.SubmitPacket(Packet);
  if ResultCode = AVERROR_EAGAIN then
  begin
    DrainDecoder(ADecoder);
    ResultCode:=ADecoder.SubmitPacket(Packet);
  end;
  if ResultCode < 0 then
  begin
    { Sequence-end packets are not decoder input. }
    if NOT Packet.HasFlag(pfIsCodecConfig) AND
      (Packet.PayloadSize > 0) then
    begin
      FLastError:=ADecoder.LastErrorText;
      HeaderText:=IntToHex(Packet.Payload.Bytes[0], 2);
      WriteLn(Format(
        'DECODE_ERROR messageType=%d payloadSize=%d header=%s message=%s',
        [Ord(Packet.MessageType), Packet.PayloadSize, HeaderText, FLastError]));
      Flush(Output);
    end;
    Exit;
  end;
  DrainDecoder(ADecoder);
end;

procedure TEnhancedDecoderProbe.Run(APort: Word);
var
  Config: TRtmpServerConfig;
begin
  Config:=DefaultRtmpServerConfig;
  Config.BindAddress:='127.0.0.1';
  Config.Port:=APort;
  Config.BufferMaxPackets:=4096;
  Config.BufferMaxBytes:=64 * 1024 * 1024;
  FServer.Config:=Config;
  FServer.Start;
  WriteLn(Format('DECODE_READY port=%d', [APort]));
  Flush(Output);
  ReadLn;
  FServer.Stop;
  WriteLn(Format(
    'DECODE_SUMMARY videoFrames=%d audioFrames=%d hevcFrames=%d av1Frames=%d vp9Frames=%d opusFrames=%d flacFrames=%d ac3Frames=%d eac3Frames=%d videoCodec=%s audioCodec=%s lastError=%s',
    [FVideoFrames, FAudioFrames, FHEVCFrames, FAV1Frames, FVP9Frames,
     FOpusFrames, FFLACFrames, FAC3Frames, FEAC3Frames,
     RtmpDecoderCodecName(FVideoDecoder.CodecKind),
     RtmpDecoderCodecName(FAudioDecoder.CodecKind), FLastError]));
end;

var
  Port: Integer;
  Probe: TEnhancedDecoderProbe;
begin
  Port:=1960;
  if ParamCount >= 1 then
    Port:=StrToIntDef(ParamStr(1), Port);
  if (Port < 1) OR (Port > 65535) then
    raise Exception.CreateFmt('Invalid TCP port: %d', [Port]);
  Probe:=TEnhancedDecoderProbe.Create;
  try
    Probe.Run(Word(Port));
  finally
    Probe.Free;
  end;
end.

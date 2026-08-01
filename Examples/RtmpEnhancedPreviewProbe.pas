program RtmpEnhancedPreviewProbe;

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
  TRTMP.RTMP.Decode,
  TRTMP.RTMP.Decode.FFmpeg,
  TRTMP.RTMP.Preview,
  TRTMP.RTMP.Types;

type
  TEnhancedPreviewProbe = class
  private
    FAV1Frames: UInt64;
    FErrors: UInt64;
    FFrameCount: UInt64;
    FHEVCFrames: UInt64;
    FLastCodec: TRtmpDecoderCodec;
    FLastHeight: Integer;
    FLastWidth: Integer;
    FPreview: TRtmpPreview;
    FVP9Frames: UInt64;
    procedure HandleFrame(Sender: TObject; const AFrame: TRtmpPreviewFrame);
    procedure HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
  public
    constructor Create(APort: Word);
    destructor Destroy; override;
    procedure Run(ADurationMS: Cardinal; const AStopFile: string);
  end;

constructor TEnhancedPreviewProbe.Create(APort: Word);
var
  Config: TRtmpPreviewConfig;
begin
  inherited Create;
  FLastCodec:=dcUnknown;
  FPreview:=TRtmpPreview.Create;
  Config:=DefaultRtmpPreviewConfig;
  Config.Server.BindAddress:='127.0.0.1';
  Config.Server.Port:=APort;
  Config.LogLevel:=llWarning;
  Config.DecoderHardwareMode:=dhmOff;
  Config.SelectionMode:=psmLatestActive;
  Config.PacketQueueMax:=512;
  Config.PacketQueueMaxDurationMS:=1000;
  FPreview.Config:=Config;
  FPreview.OnFrame:=HandleFrame;
  FPreview.OnLog:=HandleLog;
end;

destructor TEnhancedPreviewProbe.Destroy;
begin
  FPreview.Free;
  inherited Destroy;
end;

procedure TEnhancedPreviewProbe.HandleFrame(Sender: TObject;
  const AFrame: TRtmpPreviewFrame);
begin
  Inc(FFrameCount);
  FLastCodec:=AFrame.Codec;
  FLastWidth:=AFrame.Width;
  FLastHeight:=AFrame.Height;
  case AFrame.Codec of
    dcHEVC: Inc(FHEVCFrames);
    dcAV1: Inc(FAV1Frames);
    dcVP9: Inc(FVP9Frames);
  end;
  if ((AFrame.Codec = dcHEVC) AND (FHEVCFrames = 1)) OR
    ((AFrame.Codec = dcAV1) AND (FAV1Frames = 1)) OR
    ((AFrame.Codec = dcVP9) AND (FVP9Frames = 1)) then
  begin
    WriteLn(Format(
      'PREVIEW_FRAME codec=%s width=%d height=%d pixelFormat=%s pixels=%d keyframe=%s',
      [RtmpDecoderCodecName(AFrame.Codec), AFrame.Width, AFrame.Height,
       RtmpPreviewPixelFormatName(AFrame.PixelFormat), Length(AFrame.Pixels),
       BoolToStr(AFrame.IsKeyframe, True)]));
    Flush(Output);
  end;
end;

procedure TEnhancedPreviewProbe.HandleLog(Sender: TObject;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
begin
  if ALevel >= llWarning then
  begin
    Inc(FErrors);
    WriteLn(Format('PREVIEW_ERROR category=%s message=%s',
      [ACategory, AMessage]));
    Flush(Output);
  end;
end;

procedure TEnhancedPreviewProbe.Run(ADurationMS: Cardinal;
  const AStopFile: string);
var
  Deadline: UInt64;
begin
  FPreview.Start;
  WriteLn(Format('PREVIEW_READY port=%d stream=latest-active',
    [FPreview.Config.Server.Port]));
  Flush(Output);
  Deadline:=RtmpGetTickCount64 + ADurationMS;
  while (RtmpGetTickCount64 < Deadline) AND
    ((AStopFile = '') OR (NOT FileExists(AStopFile))) do
  begin
    FPreview.Poll;
    RtmpSleepMS(5);
  end;
  FPreview.Stop;
  WriteLn(Format(
    'PREVIEW_SUMMARY frames=%d hevcFrames=%d av1Frames=%d vp9Frames=%d codec=%s width=%d height=%d errors=%d',
    [FFrameCount, FHEVCFrames, FAV1Frames, FVP9Frames,
     RtmpDecoderCodecName(FLastCodec), FLastWidth, FLastHeight, FErrors]));
end;

var
  DurationMS: Integer;
  Port: Integer;
  Probe: TEnhancedPreviewProbe;
  StopFile: string;
begin
  Port:=1961;
  DurationMS:=8000;
  StopFile:='';
  if ParamCount >= 1 then
    Port:=StrToIntDef(ParamStr(1), Port);
  if ParamCount >= 2 then
    DurationMS:=StrToIntDef(ParamStr(2), DurationMS);
  if ParamCount >= 3 then
    StopFile:=ParamStr(3);
  if (Port < 1) OR (Port > 65535) then
    raise Exception.CreateFmt('Invalid TCP port: %d', [Port]);
  if DurationMS < 500 then
    raise Exception.CreateFmt('Invalid duration: %dms', [DurationMS]);
  Probe:=TEnhancedPreviewProbe.Create(Word(Port));
  try
    Probe.Run(Cardinal(DurationMS), StopFile);
  finally
    Probe.Free;
  end;
end.

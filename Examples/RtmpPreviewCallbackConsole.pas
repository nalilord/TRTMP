program RtmpPreviewCallbackConsole;

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
  TRTMP.Core.Compat,
  TRTMP.RTMP.Preview,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Types;

type
  TPreviewCallbackApp = class
  private
    FFrameCount: UInt64;
    FLastStatsTick: UInt64;
    FPreview: TRtmpPreview;
    procedure HandleFrame(Sender: TObject; const AFrame: TRtmpPreviewFrame);
    procedure HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleStreamStarted(Sender: TObject; const AStreamName,
      ARemoteAddress: string; ARemotePort: Word);
    procedure HandleStreamStopped(Sender: TObject; const AStreamName,
      ARemoteAddress: string; ARemotePort: Word);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TPreviewCallbackApp.Create;
var
  Config: TRtmpPreviewConfig;
begin
  inherited Create;
  FFrameCount:=0;
  FLastStatsTick:=0;

  Config:=DefaultRtmpPreviewConfig;
  Config.Server.BindAddress:='0.0.0.0';
  Config.Server.Port:=1935;
  Config.Server.BufferMaxPackets:=1024;
  Config.Server.BufferMaxBytes:=16 * 1024 * 1024;
  Config.Server.BufferMaxDurationMS:=3000;
  Config.Server.EnableAnalyzer:=True;
  Config.LogLevel:=llInfo;
  Config.SelectionMode:=psmLatestActive;
  Config.PacketQueueMax:=256;
  Config.DropPolicy:=pdpDropToLatestKeyframe;

  if ParamCount >= 1 then
  begin
    Config.SelectionMode:=psmExact;
    Config.TargetStreamName:=ParamStr(1);
  end;

  FPreview:=TRtmpPreview.Create;
  FPreview.Config:=Config;
  FPreview.OnFrame:=HandleFrame;
  FPreview.OnLog:=HandleLog;
  FPreview.OnStreamStarted:=HandleStreamStarted;
  FPreview.OnStreamStopped:=HandleStreamStopped;
end;

destructor TPreviewCallbackApp.Destroy;
begin
  FPreview.Free;
  inherited Destroy;
end;

procedure TPreviewCallbackApp.HandleFrame(Sender: TObject;
  const AFrame: TRtmpPreviewFrame);
begin
  Inc(FFrameCount);
  if (FFrameCount <= 5) OR ((FFrameCount MOD 30) = 0) then
    WriteLn(Format(
      '[FRAME] #%d stream=%s publisher=%s ts=%dms age=%dms interval=%dms size=%dx%d seq=%d q=%d/%dKB key=%s',
      [FFrameCount, AFrame.StreamName, AFrame.StreamPublisher,
       AFrame.TimestampMS, AFrame.DecodeLatencyMS, AFrame.FrameIntervalMS,
       AFrame.Width, AFrame.Height, AFrame.SequenceNo,
       AFrame.QueuePacketsAtEmit, AFrame.QueueBytesAtEmit DIV 1024,
       BoolToStr(AFrame.IsKeyframe, True)]));
end;

procedure TPreviewCallbackApp.HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  WriteLn(Format('[%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TPreviewCallbackApp.HandleStreamStarted(Sender: TObject;
  const AStreamName, ARemoteAddress: string; ARemotePort: Word);
begin
  WriteLn(Format('Preview stream started: %s from %s:%d',
    [AStreamName, ARemoteAddress, ARemotePort]));
end;

procedure TPreviewCallbackApp.HandleStreamStopped(Sender: TObject;
  const AStreamName, ARemoteAddress: string; ARemotePort: Word);
begin
  WriteLn(Format('Preview stream stopped: %s from %s:%d',
    [AStreamName, ARemoteAddress, ARemotePort]));
end;

procedure TPreviewCallbackApp.Run;
var
  PreviewStats: TRtmpPreviewStats;
  ServerStats: TRtmpServerStats;
begin
  FPreview.Start;
  WriteLn(Format('Callback preview listening on rtmp://127.0.0.1:%d/live/test',
    [FPreview.Config.Server.Port]));
  if FPreview.Config.SelectionMode = psmExact then
    WriteLn('Selection mode: exact stream "' + FPreview.Config.TargetStreamName + '"')
  else
    WriteLn('Selection mode: latest active');

  while True do
  begin
    FPreview.Poll;

    if (RtmpGetTickCount64 - FLastStatsTick) >= 1000 then
    begin
      FLastStatsTick:=RtmpGetTickCount64;
      ServerStats:=FPreview.Server.GetStats;
      PreviewStats:=FPreview.Stats;
      WriteLn(Format(
        '[STATS] active=%d publishes=%d bitrate=%.0f sfps=%.2f pfps=%.2f avg=%.2f q=%d/%dKB hw=%d/%dKB drop=%d selReject=%d switches=%d frames=%d age=%dms',
        [ServerStats.ActiveSessions, ServerStats.ActivePublishes,
         ServerStats.CurrentBitrate, ServerStats.Analysis.VideoFPS,
         PreviewStats.CurrentFPS, PreviewStats.AverageFPS,
         PreviewStats.QueuePackets, PreviewStats.QueueBytes DIV 1024,
         PreviewStats.QueuePacketsHighWater, PreviewStats.QueueBytesHighWater DIV 1024,
         PreviewStats.DroppedPackets, PreviewStats.SelectionRejects,
         PreviewStats.SwitchCount, PreviewStats.FramesDecoded,
         PreviewStats.LastFrameAgeMS]));
    end;

    RtmpSleepMS(10);
  end;
end;

var
  App: TPreviewCallbackApp;

begin
  RtmpMaskFloatingPointExceptions;
  App:=TPreviewCallbackApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

program RtmpLivePreview;

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
  TRTMP.RTMP.Preview.SFML,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Types,
  SfmlSystem;

type
  TPreviewApp = class
  private
    FLastStatsTick: UInt64;
    FPreview: TRtmpPreview;
    FRenderer: TRtmpSfmlPreviewRenderer;
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

constructor TPreviewApp.Create;
var
  Config: TRtmpPreviewConfig;
begin
  inherited Create;
  FLastStatsTick:=0;

  Config:=DefaultRtmpPreviewConfig;
  Config.Server.BindAddress:='0.0.0.0';
  Config.Server.Port:=1935;
  Config.Server.BufferMaxPackets:=1024;
  Config.Server.BufferMaxBytes:=16 * 1024 * 1024;
  Config.Server.BufferMaxDurationMS:=3000;
  Config.Server.EnableAnalyzer:=True;
  Config.LogLevel:=llInfo;
  Config.SelectionMode:=psmFirstActive;
  Config.PacketQueueMax:=256;
  Config.DropPolicy:=pdpDropToLatestKeyframe;

  FPreview:=TRtmpPreview.Create;
  FPreview.Config:=Config;
  FPreview.OnLog:=HandleLog;
  FPreview.OnStreamStarted:=HandleStreamStarted;
  FPreview.OnStreamStopped:=HandleStreamStopped;

  FRenderer:=TRtmpSfmlPreviewRenderer.Create(960, 540,
    'TRTMP Live Preview - waiting for publisher');
  FRenderer.ScaleMode:=ssmFit;
  FPreview.OnFrame:=FRenderer.HandleFrame;
end;

destructor TPreviewApp.Destroy;
begin
  FPreview.Free;
  FRenderer.Free;
  inherited Destroy;
end;

procedure TPreviewApp.HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  WriteLn(Format('[%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TPreviewApp.HandleStreamStarted(Sender: TObject; const AStreamName,
  ARemoteAddress: string; ARemotePort: Word);
begin
  WriteLn(Format('Publish started: stream=%s from %s:%d',
    [AStreamName, ARemoteAddress, ARemotePort]));
end;

procedure TPreviewApp.HandleStreamStopped(Sender: TObject; const AStreamName,
  ARemoteAddress: string; ARemotePort: Word);
begin
  WriteLn(Format('Publish stopped: stream=%s from %s:%d',
    [AStreamName, ARemoteAddress, ARemotePort]));
end;

procedure TPreviewApp.Run;
var
  PreviewStats: TRtmpPreviewStats;
  ServerStats: TRtmpServerStats;
begin
  FPreview.Start;
  WriteLn(Format('Preview listening on rtmp://127.0.0.1:%d/live/test',
    [FPreview.Config.Server.Port]));
  WriteLn('Window closes the app.');

  while FRenderer.IsOpen do
  begin
    FRenderer.ProcessEvents;
    FPreview.Poll;
    FRenderer.Render;

    if (RtmpGetTickCount64 - FLastStatsTick) >= 1000 then
    begin
      FLastStatsTick:=RtmpGetTickCount64;
      ServerStats:=FPreview.Server.GetStats;
      PreviewStats:=FPreview.Stats;
      WriteLn(Format(
        '[STATS] active=%d publishes=%d bytes=%d packets=%d bitrate=%.0f fps=%.2f lagMS=%d pq=%d/%dKB drop=%d(%dKB) frames=%d pfps=%.2f avg=%.2f age=%dms switch=%d decOpen=%d submitErr=%d recvErr=%d convErr=%d',
        [ServerStats.ActiveSessions, ServerStats.ActivePublishes,
         ServerStats.BytesReceived, ServerStats.PacketsReceived,
         ServerStats.CurrentBitrate, ServerStats.Analysis.VideoFPS,
         ServerStats.TimelineLagMS, PreviewStats.QueuePackets,
         PreviewStats.QueueBytes DIV 1024, PreviewStats.DroppedPackets,
         PreviewStats.DroppedBytes DIV 1024, PreviewStats.FramesDecoded,
         PreviewStats.CurrentFPS, PreviewStats.AverageFPS,
         PreviewStats.LastFrameAgeMS, PreviewStats.SwitchCount,
         PreviewStats.DecoderOpenCount, PreviewStats.DecoderSubmitErrors,
         PreviewStats.DecoderReceiveErrors, PreviewStats.ConvertErrors]));
    end;

    SfmlSleep(SfmlMilliseconds(2));
  end;

  FPreview.Stop;
end;

var
  App: TPreviewApp;

begin
  RtmpMaskFloatingPointExceptions;
  App:=TPreviewApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

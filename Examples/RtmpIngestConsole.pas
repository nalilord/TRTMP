program RtmpIngestConsole;

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
  TRTMP.Core.Compat,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Server.Session,
  TRTMP.RTMP.Types;

type
  TStatsThread = class(TThread)
  private
    FLastErrorCategory: string;
    FLastErrorMessage: string;
    FLastWarningCategory: string;
    FLastWarningMessage: string;
    FServer: TRtmpServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TRtmpServer);
  end;

  TConsoleApp = class
  private
    FLogLevel: TRtmpLogLevel;
    FPacketLogEvery: Integer;
    FPacketCount: UInt64;
    FServer: TRtmpServer;
    FStatsThread: TStatsThread;
    procedure HandleClientConnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleClientDisconnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession; Packet: TRtmpPacket);
    procedure HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure HandlePublishStopped(Sender: TObject; Session: TRtmpServerSession);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TStatsThread.Create(AServer: TRtmpServer);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FServer:=AServer;
end;

procedure TStatsThread.Execute;
var
  Stats: TRtmpServerStats;
begin
  while NOT Terminated do
  begin
    RtmpSleepMS(1000);
    if Terminated OR (FServer = nil) then
      Break;

    Stats:=FServer.GetStats;
    WriteLn(Format(
      '[STATS] active=%d peakActive=%d publishes=%d peakPublishes=%d totalSessions=%d bytes=%d packets=%d bitrate=%.0f avg=%.0f idleMS=%d lagMS=%d maxLagMS=%d dropped=%d warns=%d errors=%d protoErr=%d transportErr=%d sessionErr=%d bufferPackets=%d bufferBytes=%d bufferWindowMS=%d evicted=%d evictPkt=%d evictByte=%d evictAge=%d retained=%d retainedBytes=%d',
      [Stats.ActiveSessions, Stats.PeakActiveSessions, Stats.ActivePublishes,
       Stats.PeakActivePublishes, Stats.TotalSessions, Stats.BytesReceived,
       Stats.PacketsReceived, Stats.CurrentBitrate, Stats.AverageBitrate,
       Stats.LastPacketIdleMS, Stats.TimelineLagMS, Stats.MaxTimelineLagMS,
       Stats.DroppedPackets, Stats.Warnings, Stats.Errors,
       Stats.ProtocolErrors, Stats.TransportErrors, Stats.SessionErrors,
       Stats.Buffer.PacketCount, Stats.Buffer.ByteCount,
       Stats.Buffer.WindowDurationMS, Stats.Buffer.EvictedPackets,
       Stats.Buffer.EvictedByPacketLimit, Stats.Buffer.EvictedByByteLimit,
       Stats.Buffer.EvictedByAgeLimit, Stats.Buffer.RetainedPackets,
       Stats.Buffer.RetainedBytes]));

    if (Stats.LastWarningCategory <> '') AND
      ((Stats.LastWarningCategory <> FLastWarningCategory) OR
       (Stats.LastWarningMessage <> FLastWarningMessage)) then
    begin
      WriteLn(Format('[LASTWARN] %s: %s',
        [Stats.LastWarningCategory, Stats.LastWarningMessage]));
      FLastWarningCategory:=Stats.LastWarningCategory;
      FLastWarningMessage:=Stats.LastWarningMessage;
    end;

    if (Stats.LastErrorCategory <> '') AND
      ((Stats.LastErrorCategory <> FLastErrorCategory) OR
       (Stats.LastErrorMessage <> FLastErrorMessage)) then
    begin
      WriteLn(Format('[LASTERR] %s: %s',
        [Stats.LastErrorCategory, Stats.LastErrorMessage]));
      FLastErrorCategory:=Stats.LastErrorCategory;
      FLastErrorMessage:=Stats.LastErrorMessage;
    end;
  end;
end;

constructor TConsoleApp.Create;
begin
  inherited Create;
  FLogLevel:=llInfo;
  FPacketLogEvery:=0;
  FPacketCount:=0;
  FServer:=TRtmpServer.Create;
  FStatsThread:=nil;
  FServer.LogSink.OnLog:=HandleLog;
  FServer.OnClientConnected:=HandleClientConnected;
  FServer.OnClientDisconnected:=HandleClientDisconnected;
  FServer.OnPublishStarted:=HandlePublishStarted;
  FServer.OnPublishStopped:=HandlePublishStopped;
  FServer.OnData:=HandleData;
end;

destructor TConsoleApp.Destroy;
begin
  if FStatsThread <> nil then
  begin
    FStatsThread.Terminate;
    FStatsThread.WaitFor;
    FStatsThread.Free;
  end;
  FServer.Free;
  inherited Destroy;
end;

procedure TConsoleApp.HandleClientConnected(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Client connected: %s:%d', [Session.RemoteAddress, Session.RemotePort]));
end;

procedure TConsoleApp.HandleClientDisconnected(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Client disconnected: %s:%d', [Session.RemoteAddress, Session.RemotePort]));
end;

procedure TConsoleApp.HandleData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
begin
  Inc(FPacketCount);

  if (FLogLevel <= llInfo) AND
    ((FLogLevel = llDebug) OR Packet.HasFlag(pfIsCodecConfig) OR
    Packet.HasFlag(pfIsKeyframe) OR ((FPacketLogEvery > 0) AND
    ((FPacketCount MOD UInt64(FPacketLogEvery)) = 0))) then
    WriteLn(Format('Packet stream=%s type=%d ts=%d size=%d keyframe=%s config=%s',
      [Session.StreamName, Ord(Packet.MessageType), Packet.Timestamp,
       Packet.PayloadSize, BoolToStr(Packet.HasFlag(pfIsKeyframe), True),
       BoolToStr(Packet.HasFlag(pfIsCodecConfig), True)]));
end;

procedure TConsoleApp.HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  if ALevel < FLogLevel then
    Exit;
  WriteLn(Format('[%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TConsoleApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Publish started: stream=%s from %s:%d',
    [Session.StreamName, Session.RemoteAddress, Session.RemotePort]));
end;

procedure TConsoleApp.HandlePublishStopped(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Publish stopped: stream=%s from %s:%d',
    [Session.StreamName, Session.RemoteAddress, Session.RemotePort]));
end;

procedure TConsoleApp.Run;
var
  Config: TRtmpServerConfig;
  LogMode: string;
  Port: Word;
  SampleArg: string;
begin
  Port:=1935;
  LogMode:='info';
  if ParamCount >= 1 then
    Port:=StrToIntDef(ParamStr(1), Port);
  if ParamCount >= 2 then
    LogMode:=LowerCase(Trim(ParamStr(2)));
  if ParamCount >= 3 then
    SampleArg:=Trim(ParamStr(3))
  else
    SampleArg:='';

  if LogMode = 'debug' then
  begin
    FLogLevel:=llDebug;
    FPacketLogEvery:=1;
  end
  else if LogMode = 'info' then
    FLogLevel:=llInfo
  else if LogMode = 'warn' then
    FLogLevel:=llWarning
  else if LogMode = 'error' then
    FLogLevel:=llError
  else
    raise Exception.CreateFmt(
      'Unknown log mode "%s". Use debug, info, warn, or error.',
      [LogMode]);

  if SampleArg <> '' then
    FPacketLogEvery:=StrToIntDef(SampleArg, FPacketLogEvery);

  Config:=DefaultRtmpServerConfig;
  Config.BindAddress:='0.0.0.0';
  Config.Port:=Port;
  Config.BufferMaxPackets:=1024;
  Config.BufferMaxBytes:=16 * 1024 * 1024;
  Config.BufferMaxDurationMS:=3000;
  FServer.Config:=Config;
  FServer.MinLogLevel:=FLogLevel;
  FServer.Start;
  FStatsThread:=TStatsThread.Create(FServer);
  FStatsThread.Start;

  WriteLn(Format('Listening on rtmp://127.0.0.1:%d/live/test', [Port]));
  WriteLn(Format('Log mode: %s', [LogMode]));
  WriteLn(Format('Packet sample every: %d', [FPacketLogEvery]));
  WriteLn('Press Enter to stop.');
  ReadLn;

  FStatsThread.Terminate;
  FStatsThread.WaitFor;
  FreeAndNil(FStatsThread);
  FServer.Stop;
end;

var
  App: TConsoleApp;

begin
  App:=TConsoleApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

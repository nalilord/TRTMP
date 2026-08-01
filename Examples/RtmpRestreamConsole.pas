program RtmpRestreamConsole;

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
  TRTMP.RTMP.Client,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Server.Session,
  TRTMP.RTMP.Types;

type
  TStatsThread = class(TThread)
  private
    FClient: TRtmpClient;
    FServer: TRtmpServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TRtmpServer; AClient: TRtmpClient);
  end;

  TRestreamConsoleApp = class
  private
    FClient: TRtmpClient;
    FClientLogLevel: TRtmpLogLevel;
    FDebugMode: Boolean;
    FPacketCount: UInt64;
    FServer: TRtmpServer;
    FStatsThread: TStatsThread;
    FTargetURL: string;
    FTimestampMode: TRtmpTimestampMode;
    procedure HandleClientConnected(Sender: TObject);
    procedure HandleClientDisconnected(Sender: TObject);
    procedure HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleClientReconnect(Sender: TObject);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure HandlePublishStopped(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerClientConnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerClientDisconnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TStatsThread.Create(AServer: TRtmpServer; AClient: TRtmpClient);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FClient:=AClient;
  FServer:=AServer;
end;

procedure TStatsThread.Execute;
var
  ClientStats: TRtmpClientStats;
  ServerStats: TRtmpServerStats;
begin
  while NOT Terminated do
  begin
    RtmpSleepMS(1000);
    if Terminated OR (FServer = nil) OR (FClient = nil) then
      Break;

    ServerStats:=FServer.GetStats;
    ClientStats:=FClient.GetStats;
    WriteLn(Format(
      '[STATS] ingestActive=%d ingestBytes=%d ingestPackets=%d ingestBitrate=%.0f ingestAvg=%.0f relayState=%d relayBytes=%d relayPackets=%d relayBitrate=%.0f relayAvg=%.0f reconnects=%d bufferPackets=%d bufferBytes=%d evicted=%d evictPkt=%d evictByte=%d retained=%d retainedBytes=%d',
      [ServerStats.ActiveSessions, ServerStats.BytesReceived,
       ServerStats.PacketsReceived, ServerStats.CurrentBitrate,
       ServerStats.AverageBitrate, Ord(FClient.State), ClientStats.BytesSent,
       ClientStats.PacketsSent, ClientStats.CurrentBitrate,
       ClientStats.AverageBitrate, ClientStats.Reconnects,
       ServerStats.Buffer.PacketCount, ServerStats.Buffer.ByteCount,
       ServerStats.Buffer.EvictedPackets, ServerStats.Buffer.EvictedByPacketLimit,
       ServerStats.Buffer.EvictedByByteLimit, ServerStats.Buffer.RetainedPackets,
       ServerStats.Buffer.RetainedBytes]));
  end;
end;

constructor TRestreamConsoleApp.Create;
begin
  inherited Create;
  FClient:=TRtmpClient.Create;
  FClientLogLevel:=llInfo;
  FDebugMode:=False;
  FPacketCount:=0;
  FServer:=TRtmpServer.Create;
  FStatsThread:=nil;
  FTimestampMode:=tmPassThrough;

  FServer.LogSink.OnLog:=HandleServerLog;
  FServer.OnClientConnected:=HandleServerClientConnected;
  FServer.OnClientDisconnected:=HandleServerClientDisconnected;
  FServer.OnPublishStarted:=HandlePublishStarted;
  FServer.OnPublishStopped:=HandlePublishStopped;
  FServer.OnData:=HandleServerData;

  FClient.LogSink.OnLog:=HandleClientLog;
  FClient.OnConnected:=HandleClientConnected;
  FClient.OnDisconnected:=HandleClientDisconnected;
  FClient.OnReconnect:=HandleClientReconnect;
end;

destructor TRestreamConsoleApp.Destroy;
begin
  if FStatsThread <> nil then
  begin
    FStatsThread.Terminate;
    FStatsThread.WaitFor;
    FStatsThread.Free;
  end;
  FClient.Free;
  FServer.Free;
  inherited Destroy;
end;

procedure TRestreamConsoleApp.HandleClientConnected(Sender: TObject);
begin
  WriteLn('Relay connected and publish established.');
  Flush(Output);
end;

procedure TRestreamConsoleApp.HandleClientDisconnected(Sender: TObject);
begin
  WriteLn('Relay disconnected.');
end;

procedure TRestreamConsoleApp.HandleClientReconnect(Sender: TObject);
begin
  WriteLn('Relay reconnecting.');
end;

procedure TRestreamConsoleApp.HandleClientLog(Sender: TObject;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  if ALevel < FClientLogLevel then
    Exit;
  WriteLn(Format('[CLIENT][%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TRestreamConsoleApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Ingest publish started: stream=%s from %s:%d',
    [Session.StreamName, Session.RemoteAddress, Session.RemotePort]));
end;

procedure TRestreamConsoleApp.HandlePublishStopped(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Ingest publish stopped: stream=%s from %s:%d',
    [Session.StreamName, Session.RemoteAddress, Session.RemotePort]));
end;

procedure TRestreamConsoleApp.HandleServerClientConnected(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Ingest client connected: %s:%d',
    [Session.RemoteAddress, Session.RemotePort]));
end;

procedure TRestreamConsoleApp.HandleServerClientDisconnected(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Ingest client disconnected: %s:%d',
    [Session.RemoteAddress, Session.RemotePort]));
end;

procedure TRestreamConsoleApp.HandleServerData(Sender: TObject;
  Session: TRtmpServerSession; Packet: TRtmpPacket);
begin
  Inc(FPacketCount);
  if FDebugMode OR Packet.HasFlag(pfIsCodecConfig) OR Packet.HasFlag(pfIsKeyframe) then
    WriteLn(Format('Ingest packet stream=%s type=%d ts=%d size=%d keyframe=%s config=%s',
      [Session.StreamName, Ord(Packet.MessageType), Packet.Timestamp,
       Packet.PayloadSize, BoolToStr(Packet.HasFlag(pfIsKeyframe), True),
       BoolToStr(Packet.HasFlag(pfIsCodecConfig), True)]));
end;

procedure TRestreamConsoleApp.HandleServerLog(Sender: TObject;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  if ALevel < FClientLogLevel then
    Exit;
  WriteLn(Format('[SERVER][%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TRestreamConsoleApp.Run;
var
  ClientConfig: TRtmpClientConfig;
  I: Integer;
  ListenPort: Word;
  ServerConfig: TRtmpServerConfig;
  Token: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: RtmpRestreamConsole <target-rtmp-url> [listen-port] [pass|rebase|smooth] [debug]');
    WriteLn('Example: ./Examples/RtmpRestreamConsole rtmp://127.0.0.1:1940/live/test 1935 rebase');
    Exit;
  end;

  FTargetURL:=ParamStr(1);
  ListenPort:=1935;
  if ParamCount >= 2 then
    ListenPort:=StrToIntDef(ParamStr(2), ListenPort);
  for I:=3 to ParamCount do
  begin
    Token:=LowerCase(Trim(ParamStr(I)));
    if Token = 'debug' then
      FDebugMode:=True
    else if (Token = 'pass') OR (Token = 'passthrough') OR (Token = 'pass-through') then
      FTimestampMode:=tmPassThrough
    else if (Token = 'rebase') OR (Token = 'rebased') then
      FTimestampMode:=tmRebased
    else if (Token = 'smooth') OR (Token = 'smoothed') then
      FTimestampMode:=tmSmoothed;
  end;

  if FDebugMode then
    FClientLogLevel:=llDebug
  else
    FClientLogLevel:=llInfo;

  ServerConfig:=DefaultRtmpServerConfig;
  ServerConfig.BindAddress:='0.0.0.0';
  ServerConfig.Port:=ListenPort;
  ServerConfig.BufferMaxPackets:=1024;
  ServerConfig.BufferMaxBytes:=16 * 1024 * 1024;
  FServer.Config:=ServerConfig;
  FServer.MinLogLevel:=FClientLogLevel;

  ClientConfig:=DefaultRtmpClientConfig;
  ClientConfig.TargetURL:=FTargetURL;
  ClientConfig.OutChunkSize:=4096;
  ClientConfig.TimestampMode:=FTimestampMode;
  FClient.Config:=ClientConfig;
  FClient.AttachBuffer(FServer.Buffer);

  FServer.Start;
  try
    FClient.Start;
    FStatsThread:=TStatsThread.Create(FServer, FClient);
    FStatsThread.Start;

    WriteLn(Format('Listening for ingest on rtmp://127.0.0.1:%d/live/test', [ListenPort]));
    WriteLn(Format('Restream target: %s', [FTargetURL]));
    case FTimestampMode of
      tmPassThrough: WriteLn('Timestamp mode: pass-through');
      tmRebased: WriteLn('Timestamp mode: rebased');
      tmSmoothed: WriteLn('Timestamp mode: smoothed');
    end;
    if FDebugMode then
      WriteLn('Log mode: debug')
    else
      WriteLn('Log mode: info');
    WriteLn('Press Enter to stop.');
    Flush(Output);
    ReadLn;

    FStatsThread.Terminate;
    FStatsThread.WaitFor;
    FreeAndNil(FStatsThread);
    FClient.Stop;
  finally
    FServer.Stop;
  end;
end;

var
  App: TRestreamConsoleApp;

begin
  App:=TRestreamConsoleApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

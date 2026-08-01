unit TRTMP.RTMP.Server;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  TRTMP.RTMP.Auth,
  TRTMP.RTMP.Media.Analyzer,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Log,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Pipeline,
  TRTMP.RTMP.Server.Session,
  TRTMP.RTMP.Media.Stats,
  TRTMP.Transport,
  TRTMP.Transport.TLS,
  TRTMP.RTMP.Types;

type
  TRtmpPacketEvent = procedure(Sender: TObject; Session: TRtmpServerSession;
    Packet: TRtmpPacket) of object;
  TRtmpSessionEvent = procedure(Sender: TObject; Session: TRtmpServerSession) of object;

  TRtmpServer = class;

  TRtmpServerAcceptThread = class(TThread)
  private
    FServer: TRtmpServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TRtmpServer);
  end;

  TRtmpServerSessionThread = class(TThread)
  private
    FConnection: IRtmpConnection;
    FServer: TRtmpServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TRtmpServer; const AConnection: IRtmpConnection);
  end;

  TRtmpServer = class
  private
    FAcceptThread: TRtmpServerAcceptThread;
    FActive: Boolean;
    FAnalyzer: TRtmpAnalyzer;
    FAuthorizer: IRtmpServerAuthorizer;
    FBuffer: TRtmpCircularBuffer;
    FPlaybackBuffer: TRtmpCircularBuffer;
    FConfig: TRtmpServerConfig;
    FListener: IRtmpListener;
    FLock: TCriticalSection;
    FLog: TRtmpLogSink;
    FOnClientConnected: TRtmpSessionEvent;
    FOnClientDisconnected: TRtmpSessionEvent;
    FOnPublishStarted: TRtmpSessionEvent;
    FOnPublishStopped: TRtmpSessionEvent;
    FOnData: TRtmpPacketEvent;
    FPacketSink: TRtmpPacketSink;
    FSessionSlots: Integer;
    FStats: TRtmpServerStatsTracker;
    FTransportFactory: IRtmpTransportFactory;
    FMinLogLevel: TRtmpLogLevel;
    function GetSessionSlotCount: Integer;
    procedure HandleSessionLog(Session: TRtmpServerSession; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleSessionPacket(Session: TRtmpServerSession; Packet: TRtmpPacket);
    procedure Log(ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
    procedure NoteBufferPressure(const ABefore, AAfter: TRtmpBufferStats);
    procedure NotifyClientConnected(Session: TRtmpServerSession);
    procedure NotifyClientDisconnected(Session: TRtmpServerSession);
    procedure ReleaseSessionSlot;
    procedure Initialize(const AConfig: TRtmpServerConfig);
    function SessionSourceID(Session: TRtmpServerSession): string;
    procedure StartSessionThread(const AConnection: IRtmpConnection);
    function TryAcquireSessionSlot: Boolean;
  public
    constructor Create; overload;
    constructor Create(const AConfig: TRtmpServerConfig); overload;
    destructor Destroy; override;

    procedure AttachBuffer(ABuffer: TRtmpCircularBuffer);
    procedure AttachPlaybackBuffer(ABuffer: TRtmpCircularBuffer);
    procedure DispatchPacket(ASession: TRtmpServerSession; APacket: TRtmpPacket);
    function GetStats: TRtmpServerStats;
    procedure Start;
    procedure Stop;

    property Active: Boolean read FActive;
    property Authorizer: IRtmpServerAuthorizer read FAuthorizer write FAuthorizer;
    property Buffer: TRtmpCircularBuffer read FBuffer;
    property PlaybackBuffer: TRtmpCircularBuffer read FPlaybackBuffer;
    property Config: TRtmpServerConfig read FConfig write FConfig;
    property Listener: IRtmpListener read FListener;
    property LogSink: TRtmpLogSink read FLog;
    property Stats: TRtmpServerStats read GetStats;
    property OnClientConnected: TRtmpSessionEvent read FOnClientConnected write FOnClientConnected;
    property OnClientDisconnected: TRtmpSessionEvent read FOnClientDisconnected write FOnClientDisconnected;
    property OnPublishStarted: TRtmpSessionEvent read FOnPublishStarted write FOnPublishStarted;
    property OnPublishStopped: TRtmpSessionEvent read FOnPublishStopped write FOnPublishStopped;
    property OnData: TRtmpPacketEvent read FOnData write FOnData;
    property PacketSink: TRtmpPacketSink read FPacketSink write FPacketSink;
    property MinLogLevel: TRtmpLogLevel read FMinLogLevel write FMinLogLevel;
    property TransportFactory: IRtmpTransportFactory read FTransportFactory write FTransportFactory;
  end;

implementation

uses
  TRTMP.Transport.Platform;

constructor TRtmpServerAcceptThread.Create(AServer: TRtmpServer);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FServer:=AServer;
end;

procedure TRtmpServerAcceptThread.Execute;
var
  Connection: IRtmpConnection;
begin
  while NOT Terminated do
  begin
    try
      if (FServer = nil) OR (NOT FServer.Active) OR (FServer.Listener = nil) then
        Break;

      Connection:=FServer.Listener.Accept(200);
      if Connection <> nil then
        FServer.StartSessionThread(Connection);
    except
      on E: Exception do
      begin
        if (FServer = nil) OR (NOT FServer.Active) OR (FServer.Listener = nil) then
          Break;
        FServer.Log(llError, 'accept', E.Message);
      end;
    end;
  end;
end;

constructor TRtmpServerSessionThread.Create(AServer: TRtmpServer;
  const AConnection: IRtmpConnection);
begin
  inherited Create(True);
  FreeOnTerminate:=True;
  FServer:=AServer;
  FConnection:=AConnection;
end;

procedure TRtmpServerSessionThread.Execute;
var
  Session: TRtmpServerSession;
begin
  Session:=TRtmpServerSession.Create(FConnection);
  try
    Session.MinLogLevel:=llDebug;
    Session.MaxInChunkSize:=FServer.Config.MaxChunkSize;
    Session.MaxInMessageSize:=FServer.Config.MaxMessageSize;
    Session.MaxInChunkStreams:=FServer.Config.MaxChunkStreams;
    Session.ReadTimeoutMS:=FServer.Config.ReadTimeoutMS;
    Session.WriteTimeoutMS:=FServer.Config.WriteTimeoutMS;
    Session.SupportedEnhancedCapabilities:=
      FServer.Config.EnhancedCapabilities;
    Session.Authorizer:=FServer.Authorizer;
    Session.AttachBuffer(FServer.PlaybackBuffer);
    FServer.NotifyClientConnected(Session);
    Session.Run(FServer.HandleSessionPacket, FServer.HandleSessionLog);
  except
    on E: Exception do
      FServer.HandleSessionLog(Session, llError, 'session', E.Message);
  end;

  try
    FServer.NotifyClientDisconnected(Session);
  finally
    Session.Free;
    FServer.ReleaseSessionSlot;
  end;
end;

constructor TRtmpServer.Create;
begin
  inherited Create;
  Initialize(DefaultRtmpServerConfig);
end;

constructor TRtmpServer.Create(const AConfig: TRtmpServerConfig);
begin
  inherited Create;
  Initialize(AConfig);
end;

procedure TRtmpServer.Initialize(const AConfig: TRtmpServerConfig);
begin
  FConfig:=AConfig;
  FAnalyzer:=TRtmpAnalyzer.Create;
  FBuffer:=TRtmpCircularBuffer.Create(FConfig.BufferMaxPackets, FConfig.BufferMaxBytes,
    FConfig.BufferMaxDurationMS);
  FPlaybackBuffer:=FBuffer;
  FLock:=TCriticalSection.Create;
  FLog:=TRtmpLogSink.Create;
  FStats:=TRtmpServerStatsTracker.Create;
  FTransportFactory:=TRtmpPlatformTransportFactory.Create;
  FMinLogLevel:=llInfo;
end;

destructor TRtmpServer.Destroy;
begin
  Stop;
  FAnalyzer.Free;
  FStats.Free;
  FLog.Free;
  FLock.Free;
  FBuffer.Free;
  inherited Destroy;
end;

procedure TRtmpServer.AttachBuffer(ABuffer: TRtmpCircularBuffer);
begin
  if ABuffer = nil then
    Exit;

  if FBuffer <> ABuffer then
  begin
    if FPlaybackBuffer = FBuffer then
      FPlaybackBuffer:=ABuffer;
    FBuffer.Free;
    FBuffer:=ABuffer;
  end;
end;

procedure TRtmpServer.AttachPlaybackBuffer(ABuffer: TRtmpCircularBuffer);
begin
  if ABuffer <> nil then
    FPlaybackBuffer:=ABuffer
  else
    FPlaybackBuffer:=FBuffer;
end;

procedure TRtmpServer.DispatchPacket(ASession: TRtmpServerSession; APacket: TRtmpPacket);
var
  BufferStatsAfter: TRtmpBufferStats;
  BufferStatsBefore: TRtmpBufferStats;
  SourceID: string;
begin
  if (ASession = nil) OR (APacket = nil) then
    Exit;

  ASession.NotePacket(APacket);
  FStats.NotePacket(APacket);
  if FConfig.EnableAnalyzer AND (FAnalyzer <> nil) then
    FAnalyzer.Feed(APacket);

  if FBuffer <> nil then
  begin
    if FBuffer.PushAndGetStats(APacket.CloneShallow, BufferStatsBefore,
      BufferStatsAfter) AND
      (BufferStatsAfter.EvictedPackets > BufferStatsBefore.EvictedPackets) then
      NoteBufferPressure(BufferStatsBefore, BufferStatsAfter);
  end;

  if Assigned(FOnData) then
    FOnData(Self, ASession, APacket);

  if FPacketSink <> nil then
  begin
    SourceID:=SessionSourceID(ASession);
    FPacketSink.HandlePacket(SourceID, APacket);
  end;
end;

function TRtmpServer.GetStats: TRtmpServerStats;
begin
  Result:=FStats.Snapshot;
  if FBuffer <> nil then
  begin
    Result.Buffer:=FBuffer.GetStats;
    Inc(Result.DroppedPackets, Result.Buffer.EvictedPackets);
  end;
  if FConfig.EnableAnalyzer AND (FAnalyzer <> nil) then
    Result.Analysis:=FAnalyzer.GetSnapshot;
end;

function TRtmpServer.GetSessionSlotCount: Integer;
begin
  FLock.Acquire;
  try
    Result:=FSessionSlots;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServer.HandleSessionLog(Session: TRtmpServerSession;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
var
  PublishStopped: Boolean;
  PublishStarted: Boolean;
  SourceID: string;
begin
  PublishStarted:=(ALevel = llInfo) AND
    (Pos('publish stream=', AMessage) = 1);
  PublishStopped:=(ALevel = llInfo) AND Session.HasActivePublish AND
    ((Pos('FCUnpublish stream=', AMessage) = 1) OR
     (Pos('deleteStream received for stream=', AMessage) = 1) OR
     (Pos('closeStream received for stream=', AMessage) = 1));

  if ALevel >= llWarning then
    FStats.NoteLog(ALevel, ACategory, AMessage);

  if ALevel >= FMinLogLevel then
    Log(ALevel, ACategory,
      Format('%s:%d %s', [Session.RemoteAddress, Session.RemotePort, AMessage]));

  if PublishStarted then
  begin
    FStats.NotePublishStarted;
    if FAnalyzer <> nil then
      FAnalyzer.Reset;
    SourceID:=SessionSourceID(Session);
    if FPacketSink <> nil then
      FPacketSink.HandleStreamStarted(SourceID, Session.StreamName);
    if Assigned(FOnPublishStarted) then
      FOnPublishStarted(Self, Session);
  end;

  if PublishStopped then
  begin
    FStats.NotePublishStopped;
    SourceID:=SessionSourceID(Session);
    if FPacketSink <> nil then
      FPacketSink.HandleStreamStopped(SourceID, Session.StreamName);
    if Assigned(FOnPublishStopped) then
      FOnPublishStopped(Self, Session);
  end;
end;

procedure TRtmpServer.HandleSessionPacket(Session: TRtmpServerSession;
  Packet: TRtmpPacket);
begin
  DispatchPacket(Session, Packet);
end;

procedure TRtmpServer.Log(ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
begin
  if ALevel < FMinLogLevel then
    Exit;
  FLog.Log(Self, ALevel, ACategory, AMessage);
end;

procedure TRtmpServer.NoteBufferPressure(const ABefore, AAfter: TRtmpBufferStats);
var
  DeltaAge: UInt64;
  DeltaBytes: UInt64;
  DeltaEvicted: UInt64;
  DeltaPacket: UInt64;
  MessageText: string;
begin
  DeltaEvicted:=AAfter.EvictedPackets - ABefore.EvictedPackets;
  DeltaPacket:=AAfter.EvictedByPacketLimit - ABefore.EvictedByPacketLimit;
  DeltaBytes:=AAfter.EvictedByByteLimit - ABefore.EvictedByByteLimit;
  DeltaAge:=AAfter.EvictedByAgeLimit - ABefore.EvictedByAgeLimit;

  MessageText:=Format(
    'Buffer pressure evicted=%d packetLimit=%d byteLimit=%d ageLimit=%d packets=%d/%d bytes=%d/%d windowMS=%d/%d retained=%d retainedBytes=%d',
    [DeltaEvicted, DeltaPacket, DeltaBytes, DeltaAge,
     AAfter.PacketCount, AAfter.MaxPackets, AAfter.ByteCount, AAfter.MaxBytes,
     AAfter.WindowDurationMS, AAfter.MaxDurationMS, AAfter.RetainedPackets,
     AAfter.RetainedBytes]);
  FStats.NoteLog(llWarning, 'buffer', MessageText);
  Log(llWarning, 'buffer', MessageText);
end;

procedure TRtmpServer.NotifyClientConnected(Session: TRtmpServerSession);
begin
  FStats.NoteSessionStarted;
  if Assigned(FOnClientConnected) then
    FOnClientConnected(Self, Session);
end;

procedure TRtmpServer.NotifyClientDisconnected(Session: TRtmpServerSession);
var
  SourceID: string;
begin
  FStats.NoteSessionStopped;
  if Session.HasActivePublish then
  begin
    FStats.NotePublishStopped;
    SourceID:=SessionSourceID(Session);
    if FPacketSink <> nil then
      FPacketSink.HandleStreamStopped(SourceID, Session.StreamName);
    if Assigned(FOnPublishStopped) then
      FOnPublishStopped(Self, Session);
  end;
  if Assigned(FOnClientDisconnected) then
    FOnClientDisconnected(Self, Session);
end;

function TRtmpServer.SessionSourceID(Session: TRtmpServerSession): string;
begin
  Result:='';
  if Session = nil then
    Exit;

  Result:=Trim(Session.StreamName);
  if (Trim(Session.AppName) <> '') AND (Result <> '') then
    Result:=Trim(Session.AppName) + '/' + Result;
  if Result = '' then
    Result:=Format('%s:%d', [Session.RemoteAddress, Session.RemotePort]);
end;

procedure TRtmpServer.Start;
var
  TlsTransportFactory: IRtmpTlsTransportFactory;
  TransportDescription: string;
begin
  if FActive then
    Exit;

  if FBuffer <> nil then
  begin
    FBuffer.MaxPackets:=FConfig.BufferMaxPackets;
    FBuffer.MaxBytes:=FConfig.BufferMaxBytes;
    FBuffer.MaxDurationMS:=FConfig.BufferMaxDurationMS;
  end;

  FStats.Reset;
  if FAnalyzer <> nil then
    FAnalyzer.Reset;
  FLock.Acquire;
  try
    FSessionSlots:=0;
  finally
    FLock.Release;
  end;

  if FConfig.Tls.Enabled then
  begin
    if NOT Supports(FTransportFactory, IRtmpTlsTransportFactory,
      TlsTransportFactory) then
      raise ERtmpTransportError.CreateFmt(
        'TLS listener requested, but transport %s has no TLS provider',
        [FTransportFactory.Description]);
    FListener:=TlsTransportFactory.CreateTlsListener(
      TRtmpSocketEndpoint.Create(FConfig.BindAddress, FConfig.Port), 16,
      FConfig.Tls);
    TransportDescription:=TlsTransportFactory.TlsDescription;
  end else
  begin
    FListener:=FTransportFactory.CreateListener(
      TRtmpSocketEndpoint.Create(FConfig.BindAddress, FConfig.Port), 16);
    TransportDescription:=FTransportFactory.Description;
  end;
  FActive:=True;
  FAcceptThread:=TRtmpServerAcceptThread.Create(Self);
  FAcceptThread.Start;

  Log(llInfo, 'server', Format('Server listening on %s:%d via %s tls=%s',
    [FConfig.BindAddress, FConfig.Port, TransportDescription,
     BoolToStr(FConfig.Tls.Enabled, True)]));
end;

procedure TRtmpServer.ReleaseSessionSlot;
begin
  FLock.Acquire;
  try
    if FSessionSlots > 0 then
      Dec(FSessionSlots);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServer.StartSessionThread(const AConnection: IRtmpConnection);
var
  ActiveSessions: Integer;
  RemoteEndpoint: TRtmpSocketEndpoint;
  SessionThread: TRtmpServerSessionThread;
begin
  if AConnection = nil then
    Exit;

  if NOT TryAcquireSessionSlot then
  begin
    ActiveSessions:=GetSessionSlotCount;
    RemoteEndpoint:=AConnection.RemoteEndpoint;
    FStats.NoteSessionRejected;
    Log(llWarning, 'admission',
      Format('Rejected connection %s:%d activeSessions=%d maxSessions=%d',
        [RemoteEndpoint.Address, RemoteEndpoint.Port, ActiveSessions, FConfig.MaxSessions]));
    AConnection.Close;
    Exit;
  end;

  SessionThread:=TRtmpServerSessionThread.Create(Self, AConnection);
  SessionThread.Start;
end;

procedure TRtmpServer.Stop;
begin
  if NOT FActive then
    Exit;

  FActive:=False;

  if FAcceptThread <> nil then
    FAcceptThread.Terminate;

  if FListener <> nil then
    FListener.Close;

  if FAcceptThread <> nil then
  begin
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;

  FListener:=nil;
  Log(llInfo, 'server', 'Server stopped');
end;

function TRtmpServer.TryAcquireSessionSlot: Boolean;
begin
  FLock.Acquire;
  try
    Result:=(FConfig.MaxSessions <= 0) OR (FSessionSlots < FConfig.MaxSessions);
    if Result then
      Inc(FSessionSlots);
  finally
    FLock.Release;
  end;
end;

end.

program RtmpGraphGatewayConsole;

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
  Contnrs,
  IniFiles,
  SysUtils,
  RtmpBuffer,
  RtmpCompat,
  RtmpClient,
  RtmpLiveSourceSwitcher,
  RtmpPacket,
  RtmpPipeline,
  RtmpServer,
  RtmpServerSession,
  RtmpTypes
  {$IFDEF USE_FFMPEG}
  ,
  RtmpMediaPipeline
  {$ENDIF};

type
  TGraphGatewayApp = class;

{$IFDEF USE_FFMPEG}
  TNamedCallbackPlayerSink = class(TRtmpCallbackPlayerSink)
  public
    Name: string;
    FrameCount: UInt64;
    LogEveryFrames: Integer;
  end;
{$ENDIF}

{$IFDEF USE_FFMPEG}
{$IFDEF USE_SFML}
  TNamedSfmlPlayerSink = class(TRtmpSfmlPlayerSink)
  public
    Name: string;
  end;

  TSfmlPlayerThread = class(TThread)
  private
    FPlayer: TNamedSfmlPlayerSink;
  protected
    procedure Execute; override;
  public
    constructor Create(APlayer: TNamedSfmlPlayerSink);
  end;
{$ENDIF}
{$ENDIF}

  TGraphGatewayStatsThread = class(TThread)
  private
    FApp: TGraphGatewayApp;
  protected
    procedure Execute; override;
  public
    constructor Create(AApp: TGraphGatewayApp);
  end;

  TGraphGatewayConfig = record
    ConfigPath: string;
    Server: TRtmpServerConfig;
    PipelineActiveSource: string;
    PipelineDefaultPriority: Integer;
    PipelineIdleTimeoutMS: Integer;
    PipelineSourcePriorities: string;
    LogLevel: TRtmpLogLevel;
    PacketLogEvery: Integer;
  end;

  TGraphGatewayApp = class
  private
    FConfig: TGraphGatewayConfig;
    FManagedObjects: TObjectList;
    FPacketCount: UInt64;
    FPacketParents: TStringList;
    FProgramBuffer: TRtmpCircularBuffer;
    FProgramBufferSink: TRtmpBufferSink;
    FProgramStats: TRtmpPacketStatsNode;
    FRelaySinks: TList;
    FServer: TRtmpServer;
    FSourceSwitcher: TRtmpLiveSourceSwitcherNode;
    FStatsThread: TGraphGatewayStatsThread;
    FTeeNode: TRtmpPacketTeeNode;
{$IFDEF USE_FFMPEG}
    FCallbackPlayers: TList;
{$IFDEF USE_SFML}
    FPlayerThreads: TObjectList;
    FSfmlPlayers: TList;
{$ENDIF}
    FVideoDecoders: TList;
    FVideoParents: TStringList;
{$ENDIF}
    procedure BuildConfiguredGraph;
    procedure BuildGraphSection(Ini: TIniFile; const ASection: string);
    function ExtractStreamNameFromSourceID(const ASourceID: string): string;
    function FindPacketParent(const AName: string): TRtmpPacketNode;
    function FindRelaySinkByClient(Sender: TObject): TRtmpRelaySinkNode;
{$IFDEF USE_FFMPEG}
    function FindVideoParent(const AName: string): TRtmpVideoDecoderNode;
{$ENDIF}
    function ParseGraphBool(Ini: TIniFile; const ASection, AIdent: string;
      ADefault: Boolean): Boolean;
    function ParseGraphKind(const AValue: string): string;
    function ParseLogLevel(const AValue: string): TRtmpLogLevel;
    function ParsePriorityMapValue(const ASourceID: string;
      const AMapValue: string; ADefault: Integer): Integer;
    function ParseTimestampMode(const AValue: string): TRtmpTimestampMode;
    function ResolveSourcePriority(const ASourceID: string): Integer;
{$IFDEF USE_FFMPEG}
    procedure HandleCallbackPlayerFrame(Sender: TObject;
      const AFrame: TRtmpDecodedVideoFrame);
{$ENDIF}
    procedure HandlePipelineSourceChanged(Sender: TObject;
      const APreviousSourceID, ANewSourceID, AReason: string);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure HandlePublishStopped(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleRelayConnected(Sender: TObject);
    procedure HandleRelayDisconnected(Sender: TObject);
    procedure HandleRelayLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleRelayReconnect(Sender: TObject);
    procedure HandleServerClientConnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerClientDisconnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure LoadConfig(const APath: string);
    procedure PrintStartupSummary;
    procedure RegisterPacketParent(const AName: string; ANode: TRtmpPacketNode);
{$IFDEF USE_FFMPEG}
    procedure RegisterVideoParent(const AName: string; ANode: TRtmpVideoDecoderNode);
{$ENDIF}
    function SessionSourceID(Session: TRtmpServerSession): string;
    procedure StartBranches;
    procedure StopBranches;
  public
    constructor Create;
    destructor Destroy; override;
    function CurrentConfig: TGraphGatewayConfig;
    function ServerStats: TRtmpServerStats;
    procedure Run;
  end;

function ConfigValueOrDefault(const AValue, ADefault: string): string;
begin
  if Trim(AValue) = '' then
    Result := ADefault
  else
    Result := AValue;
end;

function ReadUInt64Value(Ini: TIniFile; const ASection, AIdent: string;
  ADefault: UInt64): UInt64;
var
  Parsed: Int64;
  Value: string;
begin
  Value := Trim(Ini.ReadString(ASection, AIdent, ''));
  if Value = '' then
    Exit(ADefault);

  if (not TryStrToInt64(Value, Parsed)) or (Parsed < 0) then
    raise Exception.CreateFmt('Invalid unsigned integer for %s.%s: %s',
      [ASection, AIdent, Value]);
  Result := UInt64(Parsed);
end;

function LogLevelName(ALevel: TRtmpLogLevel): string;
begin
  case ALevel of
    llDebug: Result := 'debug';
    llInfo: Result := 'info';
    llWarning: Result := 'warn';
    llError: Result := 'error';
  else
    Result := 'unknown';
  end;
end;

function TimestampModeName(AMode: TRtmpTimestampMode): string;
begin
  case AMode of
    tmPassThrough: Result := 'pass';
    tmRebased: Result := 'rebase';
    tmSmoothed: Result := 'smooth';
  else
    Result := 'unknown';
  end;
end;

{$IFDEF USE_FFMPEG}
{$IFDEF USE_SFML}
constructor TSfmlPlayerThread.Create(APlayer: TNamedSfmlPlayerSink);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPlayer := APlayer;
end;

procedure TSfmlPlayerThread.Execute;
begin
  RtmpMaskFloatingPointExceptions;
  while not Terminated and (FPlayer <> nil) and FPlayer.IsOpen do
  begin
    FPlayer.ProcessEvents;
    FPlayer.Render;
    RtmpSleepMS(16);
  end;
end;
{$ENDIF}
{$ENDIF}

constructor TGraphGatewayStatsThread.Create(AApp: TGraphGatewayApp);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FApp := AApp;
end;

procedure TGraphGatewayStatsThread.Execute;
var
  BufferStats: TRtmpBufferStats;
  Config: TGraphGatewayConfig;
{$IFDEF USE_FFMPEG}
  DecodeStats: TRtmpVideoDecodeStats;
{$ENDIF}
  I: Integer;
  PipelineStats: TRtmpPipelineStats;
  RelayBufferStats: TRtmpBufferStats;
  RelayClientStats: TRtmpClientStats;
  RelaySink: TRtmpRelaySinkNode;
  ServerStats: TRtmpServerStats;
  SwitcherStats: TRtmpLiveSourceSwitcherStats;
begin
  while not Terminated do
  begin
    RtmpSleepMS(1000);
    if Terminated or (FApp = nil) then
      Break;

    Config := FApp.CurrentConfig;
    ServerStats := FApp.ServerStats;
    PipelineStats := FApp.FProgramStats.GetStats;
    BufferStats := FApp.FProgramBuffer.GetStats;
    SwitcherStats := FApp.FSourceSwitcher.Switcher.GetStats;
    WriteLn(Format(
      '[STATS] active=%d publishes=%d bytes=%d packets=%d bitrate=%.0f avg=%.0f idleMS=%d lagMS=%d maxLagMS=%d warns=%d errors=%d protoErr=%d transportErr=%d sessionErr=%d bufferPackets=%d bufferBytes=%d bufferWindowMS=%d evicted=%d evictPkt=%d evictByte=%d evictAge=%d retained=%d retainedBytes=%d',
      [ServerStats.ActiveSessions, ServerStats.ActivePublishes,
       ServerStats.BytesReceived, ServerStats.PacketsReceived,
       ServerStats.CurrentBitrate, ServerStats.AverageBitrate,
       ServerStats.LastPacketIdleMS, ServerStats.TimelineLagMS,
       ServerStats.MaxTimelineLagMS, ServerStats.Warnings, ServerStats.Errors,
       ServerStats.ProtocolErrors, ServerStats.TransportErrors,
       ServerStats.SessionErrors, ServerStats.Buffer.PacketCount,
       ServerStats.Buffer.ByteCount, ServerStats.Buffer.WindowDurationMS,
       ServerStats.Buffer.EvictedPackets, ServerStats.Buffer.EvictedByPacketLimit,
       ServerStats.Buffer.EvictedByByteLimit, ServerStats.Buffer.EvictedByAgeLimit,
       ServerStats.Buffer.RetainedPackets, ServerStats.Buffer.RetainedBytes]));
    WriteLn(Format(
      '[PROGRAM] activeSource=%s switches=%d failovers=%d packets=%d bytes=%d starts=%d stops=%d bufferPackets=%d bufferBytes=%d bufferWindowMS=%d',
      [SwitcherStats.ActiveSourceID, SwitcherStats.SwitchCount,
       SwitcherStats.FailoverSwitchCount, PipelineStats.Packets, PipelineStats.Bytes,
       PipelineStats.StreamStarts, PipelineStats.StreamStops,
       BufferStats.PacketCount, BufferStats.ByteCount, BufferStats.WindowDurationMS]));

    for I := 0 to FApp.FRelaySinks.Count - 1 do
    begin
      RelaySink := TRtmpRelaySinkNode(FApp.FRelaySinks[I]);
      RelayClientStats := RelaySink.ClientStats;
      RelayBufferStats := RelaySink.BufferStats;
      WriteLn(Format(
        '[RELAY:%s] state=%d bytes=%d packets=%d bitrate=%.0f avg=%.0f reconnects=%d bufferPackets=%d bufferBytes=%d',
        [RelaySink.Name, Ord(RelaySink.Client.State), RelayClientStats.BytesSent,
         RelayClientStats.PacketsSent, RelayClientStats.CurrentBitrate,
         RelayClientStats.AverageBitrate, RelayClientStats.Reconnects,
         RelayBufferStats.PacketCount, RelayBufferStats.ByteCount]));
    end;

{$IFDEF USE_FFMPEG}
    for I := 0 to FApp.FVideoDecoders.Count - 1 do
    begin
      DecodeStats := TRtmpVideoDecoderNode(FApp.FVideoDecoders[I]).Stats;
      WriteLn(Format(
        '[DECODE:%d] source=%s stream=%s packets=%d config=%d opens=%d frames=%d submitErr=%d recvErr=%d convErr=%d size=%dx%d',
        [I + 1, DecodeStats.ActiveSourceID, DecodeStats.ActiveStreamName,
         DecodeStats.Packets, DecodeStats.ConfigPacketsSeen,
         DecodeStats.DecoderOpenCount, DecodeStats.FramesDecoded,
         DecodeStats.DecoderSubmitErrors, DecodeStats.DecoderReceiveErrors,
         DecodeStats.ConvertErrors, DecodeStats.Width, DecodeStats.Height]));
    end;
{$ENDIF}

    if Config.PacketLogEvery < 0 then
      Break;
  end;
end;

constructor TGraphGatewayApp.Create;
begin
  inherited Create;
  FManagedObjects := TObjectList.Create(True);
  FPacketCount := 0;
  FPacketParents := TStringList.Create;
  FPacketParents.CaseSensitive := False;
  FPacketParents.Sorted := False;
  FPacketParents.Duplicates := dupIgnore;
  FProgramBuffer := TRtmpCircularBuffer.Create(1024, 16 * 1024 * 1024, 3000);
  FProgramBufferSink := TRtmpBufferSink.Create(FProgramBuffer);
  FProgramStats := TRtmpPacketStatsNode.Create;
  FRelaySinks := TList.Create;
  FServer := TRtmpServer.Create;
  FSourceSwitcher := TRtmpLiveSourceSwitcherNode.Create;
  FStatsThread := nil;
  FTeeNode := TRtmpPacketTeeNode.Create;
{$IFDEF USE_FFMPEG}
  FCallbackPlayers := TList.Create;
{$IFDEF USE_SFML}
  FPlayerThreads := TObjectList.Create(True);
  FSfmlPlayers := TList.Create;
{$ENDIF}
  FVideoDecoders := TList.Create;
  FVideoParents := TStringList.Create;
  FVideoParents.CaseSensitive := False;
  FVideoParents.Sorted := False;
  FVideoParents.Duplicates := dupIgnore;
{$ENDIF}

  FSourceSwitcher.AddSink(FProgramStats);
  FProgramStats.AddSink(FTeeNode);
  FTeeNode.AddSink(FProgramBufferSink);

  RegisterPacketParent('program', FTeeNode);
  RegisterPacketParent('program_stats', FProgramStats);
  RegisterPacketParent('program_switcher', FSourceSwitcher);

  FServer.LogSink.OnLog := HandleServerLog;
  FServer.OnClientConnected := HandleServerClientConnected;
  FServer.OnClientDisconnected := HandleServerClientDisconnected;
  FServer.OnPublishStarted := HandlePublishStarted;
  FServer.OnPublishStopped := HandlePublishStopped;
  FServer.OnData := HandleServerData;
  FServer.PacketSink := FSourceSwitcher;

  FSourceSwitcher.OnActiveSourceChanged := HandlePipelineSourceChanged;
end;

destructor TGraphGatewayApp.Destroy;
begin
  if FStatsThread <> nil then
  begin
    FStatsThread.Terminate;
    FStatsThread.WaitFor;
    FStatsThread.Free;
  end;

  StopBranches;

{$IFDEF USE_FFMPEG}
{$IFDEF USE_SFML}
  FPlayerThreads.Free;
  FSfmlPlayers.Free;
{$ENDIF}
  FVideoParents.Free;
  FVideoDecoders.Free;
  FCallbackPlayers.Free;
{$ENDIF}
  FRelaySinks.Free;
  FServer.Free;
  FTeeNode.Free;
  FSourceSwitcher.Free;
  FProgramStats.Free;
  FProgramBufferSink.Free;
  FProgramBuffer.Free;
  FPacketParents.Free;
  FManagedObjects.Free;
  inherited Destroy;
end;

function TGraphGatewayApp.CurrentConfig: TGraphGatewayConfig;
begin
  Result := FConfig;
end;

function TGraphGatewayApp.ExtractStreamNameFromSourceID(const ASourceID: string): string;
var
  SlashPos: Integer;
begin
  SlashPos := LastDelimiter('/', ASourceID);
  if SlashPos > 0 then
    Result := Copy(ASourceID, SlashPos + 1, MaxInt)
  else
    Result := ASourceID;
end;

function TGraphGatewayApp.FindPacketParent(const AName: string): TRtmpPacketNode;
var
  Index: Integer;
begin
  Result := nil;
  Index := FPacketParents.IndexOf(AName);
  if Index >= 0 then
    Result := TRtmpPacketNode(FPacketParents.Objects[Index]);
end;

function TGraphGatewayApp.FindRelaySinkByClient(Sender: TObject): TRtmpRelaySinkNode;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FRelaySinks.Count - 1 do
    if TRtmpRelaySinkNode(FRelaySinks[I]).Client = Sender then
      Exit(TRtmpRelaySinkNode(FRelaySinks[I]));
end;

{$IFDEF USE_FFMPEG}
function TGraphGatewayApp.FindVideoParent(const AName: string): TRtmpVideoDecoderNode;
var
  Index: Integer;
begin
  Result := nil;
  Index := FVideoParents.IndexOf(AName);
  if Index >= 0 then
    Result := TRtmpVideoDecoderNode(FVideoParents.Objects[Index]);
end;
{$ENDIF}

function TGraphGatewayApp.ParseGraphBool(Ini: TIniFile; const ASection,
  AIdent: string; ADefault: Boolean): Boolean;
begin
  Result := Ini.ReadBool(ASection, AIdent, ADefault);
end;

function TGraphGatewayApp.ParseGraphKind(const AValue: string): string;
begin
  Result := LowerCase(Trim(AValue));
  if Result = '' then
    raise Exception.Create('Graph node kind must not be empty');
end;

function TGraphGatewayApp.ParseLogLevel(const AValue: string): TRtmpLogLevel;
var
  Value: string;
begin
  Value := LowerCase(Trim(AValue));
  if (Value = 'debug') then
    Result := llDebug
  else if (Value = 'info') or (Value = '') then
    Result := llInfo
  else if (Value = 'warn') or (Value = 'warning') then
    Result := llWarning
  else if (Value = 'error') then
    Result := llError
  else
    raise Exception.CreateFmt('Unknown log level "%s"', [AValue]);
end;

function TGraphGatewayApp.ParsePriorityMapValue(const ASourceID: string;
  const AMapValue: string; ADefault: Integer): Integer;
var
  Entry: string;
  EntryValue: string;
  I: Integer;
  NamePart: string;
  PairPos: Integer;
  ParsedValue: Integer;
  Parts: TStringList;
begin
  Result := ADefault;
  if Trim(AMapValue) = '' then
    Exit;

  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ',';
    Parts.DelimitedText := AMapValue;
    for I := 0 to Parts.Count - 1 do
    begin
      Entry := Trim(Parts[I]);
      if Entry = '' then
        Continue;
      PairPos := Pos('=', Entry);
      if PairPos <= 1 then
        Continue;
      NamePart := Trim(Copy(Entry, 1, PairPos - 1));
      EntryValue := Trim(Copy(Entry, PairPos + 1, MaxInt));
      if not SameText(NamePart, ASourceID) then
        Continue;
      if not TryStrToInt(EntryValue, ParsedValue) then
        raise Exception.CreateFmt('Invalid pipeline priority for source "%s": %s',
          [ASourceID, EntryValue]);
      Exit(ParsedValue);
    end;
  finally
    Parts.Free;
  end;
end;

function TGraphGatewayApp.ParseTimestampMode(const AValue: string): TRtmpTimestampMode;
var
  Value: string;
begin
  Value := LowerCase(Trim(AValue));
  if (Value = '') or (Value = 'pass') or (Value = 'passthrough') or
    (Value = 'pass-through') then
    Result := tmPassThrough
  else if (Value = 'rebase') or (Value = 'rebased') then
    Result := tmRebased
  else if (Value = 'smooth') or (Value = 'smoothed') then
    Result := tmSmoothed
  else
    raise Exception.CreateFmt('Unknown timestamp mode "%s"', [AValue]);
end;

function TGraphGatewayApp.ResolveSourcePriority(const ASourceID: string): Integer;
begin
  Result := ParsePriorityMapValue(ASourceID, FConfig.PipelineSourcePriorities,
    FConfig.PipelineDefaultPriority);
  if Result = FConfig.PipelineDefaultPriority then
    Result := ParsePriorityMapValue(ExtractStreamNameFromSourceID(ASourceID),
      FConfig.PipelineSourcePriorities, FConfig.PipelineDefaultPriority);
end;

{$IFDEF USE_FFMPEG}
procedure TGraphGatewayApp.HandleCallbackPlayerFrame(Sender: TObject;
  const AFrame: TRtmpDecodedVideoFrame);
var
  Player: TNamedCallbackPlayerSink;
begin
  if not (Sender is TNamedCallbackPlayerSink) then
    Exit;
  Player := TNamedCallbackPlayerSink(Sender);
  Inc(Player.FrameCount);
  if (Player.LogEveryFrames <= 0) or
    ((Player.FrameCount mod UInt64(Player.LogEveryFrames)) = 0) then
    WriteLn(Format(
      '[PLAYER:%s] frame=%d stream=%s ts=%dms age=%dms size=%dx%d key=%s seq=%d',
      [Player.Name, Player.FrameCount, AFrame.StreamName, AFrame.TimestampMS,
       AFrame.DecodeLatencyMS, AFrame.Width, AFrame.Height,
       BoolToStr(AFrame.IsKeyframe, True), AFrame.SequenceNo]));
end;
{$ENDIF}

procedure TGraphGatewayApp.HandlePipelineSourceChanged(Sender: TObject;
  const APreviousSourceID, ANewSourceID, AReason: string);
begin
  WriteLn(Format('Program source changed: %s -> %s reason=%s',
    [APreviousSourceID, ANewSourceID, AReason]));
end;

procedure TGraphGatewayApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
var
  SourceID: string;
begin
  SourceID := SessionSourceID(Session);
  if SourceID <> '' then
    FSourceSwitcher.Switcher.RegisterSource(SourceID, ResolveSourcePriority(SourceID));
  WriteLn(Format('Publish started: stream=%s from %s:%d',
    [Session.StreamName, Session.RemoteAddress, Session.RemotePort]));
end;

procedure TGraphGatewayApp.HandlePublishStopped(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Publish stopped: stream=%s from %s:%d',
    [Session.StreamName, Session.RemoteAddress, Session.RemotePort]));
end;

procedure TGraphGatewayApp.HandleRelayConnected(Sender: TObject);
var
  Relay: TRtmpRelaySinkNode;
begin
  Relay := FindRelaySinkByClient(Sender);
  if Relay <> nil then
    WriteLn(Format('Relay "%s" connected and publish established.', [Relay.Name]))
  else
    WriteLn('Relay connected and publish established.');
end;

procedure TGraphGatewayApp.HandleRelayDisconnected(Sender: TObject);
var
  Relay: TRtmpRelaySinkNode;
begin
  Relay := FindRelaySinkByClient(Sender);
  if Relay <> nil then
    WriteLn(Format('Relay "%s" disconnected.', [Relay.Name]))
  else
    WriteLn('Relay disconnected.');
end;

procedure TGraphGatewayApp.HandleRelayLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
var
  Prefix: string;
  Relay: TRtmpRelaySinkNode;
begin
  if ALevel < FConfig.LogLevel then
    Exit;
  Relay := FindRelaySinkByClient(Sender);
  if Relay <> nil then
    Prefix := 'RELAY:' + Relay.Name
  else
    Prefix := 'RELAY';
  WriteLn(Format('[%s][%s] %s: %s', [Prefix, LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TGraphGatewayApp.HandleRelayReconnect(Sender: TObject);
var
  Relay: TRtmpRelaySinkNode;
begin
  Relay := FindRelaySinkByClient(Sender);
  if Relay <> nil then
    WriteLn(Format('Relay "%s" reconnecting.', [Relay.Name]))
  else
    WriteLn('Relay reconnecting.');
end;

procedure TGraphGatewayApp.HandleServerClientConnected(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Client connected: %s:%d',
    [Session.RemoteAddress, Session.RemotePort]));
end;

procedure TGraphGatewayApp.HandleServerClientDisconnected(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Client disconnected: %s:%d',
    [Session.RemoteAddress, Session.RemotePort]));
end;

procedure TGraphGatewayApp.HandleServerData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
begin
  Inc(FPacketCount);
  if (FConfig.LogLevel <= llInfo) and
    (Packet.HasFlag(pfIsCodecConfig) or Packet.HasFlag(pfIsKeyframe) or
    ((FConfig.PacketLogEvery > 0) and
    ((FPacketCount mod UInt64(FConfig.PacketLogEvery)) = 0))) then
    WriteLn(Format('Packet stream=%s type=%d ts=%d size=%d keyframe=%s config=%s',
      [Session.StreamName, Ord(Packet.MessageType), Packet.Timestamp,
       Packet.PayloadSize, BoolToStr(Packet.HasFlag(pfIsKeyframe), True),
       BoolToStr(Packet.HasFlag(pfIsCodecConfig), True)]));
end;

procedure TGraphGatewayApp.HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  if ALevel < FConfig.LogLevel then
    Exit;
  WriteLn(Format('[SERVER][%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TGraphGatewayApp.LoadConfig(const APath: string);
var
  Ini: TIniFile;
begin
  FConfig := Default(TGraphGatewayConfig);
  FConfig.ConfigPath := ExpandFileName(APath);
  FConfig.Server := DefaultRtmpServerConfig;
  FConfig.PipelineActiveSource := '';
  FConfig.PipelineDefaultPriority := 100;
  FConfig.PipelineIdleTimeoutMS := 3000;
  FConfig.PipelineSourcePriorities := '';
  FConfig.LogLevel := llInfo;
  FConfig.PacketLogEvery := 0;

  if not FileExists(FConfig.ConfigPath) then
    raise Exception.CreateFmt('Config file not found: %s', [FConfig.ConfigPath]);

  Ini := TIniFile.Create(FConfig.ConfigPath);
  try
    FConfig.Server.BindAddress := ConfigValueOrDefault(
      Ini.ReadString('server', 'bind_address', FConfig.Server.BindAddress),
      FConfig.Server.BindAddress);
    FConfig.Server.Port := Word(Ini.ReadInteger('server', 'port', FConfig.Server.Port));
    FConfig.Server.MaxSessions := Ini.ReadInteger('server', 'max_sessions',
      FConfig.Server.MaxSessions);
    FConfig.Server.MaxChunkSize := Ini.ReadInteger('server', 'max_chunk_size',
      FConfig.Server.MaxChunkSize);
    FConfig.Server.MaxMessageSize := Ini.ReadInteger('server', 'max_message_size',
      FConfig.Server.MaxMessageSize);
    FConfig.Server.MaxChunkStreams := Ini.ReadInteger('server', 'max_chunk_streams',
      FConfig.Server.MaxChunkStreams);
    FConfig.Server.ReadTimeoutMS := Ini.ReadInteger('server', 'read_timeout_ms',
      FConfig.Server.ReadTimeoutMS);
    FConfig.Server.WriteTimeoutMS := Ini.ReadInteger('server', 'write_timeout_ms',
      FConfig.Server.WriteTimeoutMS);
    FConfig.Server.BufferMaxPackets := Ini.ReadInteger('server', 'buffer_max_packets',
      FConfig.Server.BufferMaxPackets);
    FConfig.Server.BufferMaxBytes := ReadUInt64Value(Ini, 'server',
      'buffer_max_bytes', FConfig.Server.BufferMaxBytes);
    FConfig.Server.BufferMaxDurationMS := UInt32(Ini.ReadInteger('server',
      'buffer_max_duration_ms', Integer(FConfig.Server.BufferMaxDurationMS)));
    FConfig.Server.EnableAnalyzer := Ini.ReadBool('server', 'enable_analyzer',
      FConfig.Server.EnableAnalyzer);

    FConfig.PipelineIdleTimeoutMS := Ini.ReadInteger('pipeline', 'idle_timeout_ms',
      FConfig.PipelineIdleTimeoutMS);
    FConfig.PipelineDefaultPriority := Ini.ReadInteger('pipeline',
      'default_priority', FConfig.PipelineDefaultPriority);
    FConfig.PipelineActiveSource := Trim(Ini.ReadString('pipeline', 'active_source',
      FConfig.PipelineActiveSource));
    FConfig.PipelineSourcePriorities := Trim(Ini.ReadString('pipeline',
      'source_priorities', FConfig.PipelineSourcePriorities));

    FConfig.LogLevel := ParseLogLevel(Ini.ReadString('logging', 'level', 'info'));
    FConfig.PacketLogEvery := Ini.ReadInteger('logging', 'packet_log_every', 0);
  finally
    Ini.Free;
  end;
end;

procedure TGraphGatewayApp.PrintStartupSummary;
begin
  WriteLn(Format('Config: %s', [FConfig.ConfigPath]));
  WriteLn(Format('Ingest listen: rtmp://127.0.0.1:%d/live/test',
    [FConfig.Server.Port]));
  WriteLn(Format('Log level: %s', [LogLevelName(FConfig.LogLevel)]));
  WriteLn(Format('Packet sample every: %d', [FConfig.PacketLogEvery]));
  WriteLn(Format('Analyzer enabled: %s', [BoolToStr(FConfig.Server.EnableAnalyzer, True)]));
  WriteLn(Format('Program idle timeout ms: %d', [FConfig.PipelineIdleTimeoutMS]));
  WriteLn(Format('Program default priority: %d', [FConfig.PipelineDefaultPriority]));
  WriteLn('Program source ID format: app/stream');
  if FConfig.PipelineSourcePriorities <> '' then
    WriteLn(Format('Program source priorities: %s', [FConfig.PipelineSourcePriorities]));
  if FConfig.PipelineActiveSource <> '' then
    WriteLn(Format('Program forced active source: %s', [FConfig.PipelineActiveSource]));
  WriteLn(Format('Configured relay branches: %d', [FRelaySinks.Count]));
{$IFDEF USE_FFMPEG}
  WriteLn(Format('Configured decoder branches: %d', [FVideoDecoders.Count]));
{$ENDIF}
end;

procedure TGraphGatewayApp.RegisterPacketParent(const AName: string;
  ANode: TRtmpPacketNode);
var
  Index: Integer;
begin
  if (Trim(AName) = '') or (ANode = nil) then
    Exit;
  Index := FPacketParents.IndexOf(AName);
  if Index >= 0 then
    FPacketParents.Objects[Index] := ANode
  else
    FPacketParents.AddObject(AName, ANode);
end;

{$IFDEF USE_FFMPEG}
procedure TGraphGatewayApp.RegisterVideoParent(const AName: string;
  ANode: TRtmpVideoDecoderNode);
var
  Index: Integer;
begin
  if (Trim(AName) = '') or (ANode = nil) then
    Exit;
  Index := FVideoParents.IndexOf(AName);
  if Index >= 0 then
    FVideoParents.Objects[Index] := ANode
  else
    FVideoParents.AddObject(AName, ANode);
end;
{$ENDIF}

function TGraphGatewayApp.SessionSourceID(Session: TRtmpServerSession): string;
begin
  Result := '';
  if Session = nil then
    Exit;
  Result := Trim(Session.StreamName);
  if (Trim(Session.AppName) <> '') and (Result <> '') then
    Result := Trim(Session.AppName) + '/' + Result;
end;

procedure TGraphGatewayApp.StartBranches;
var
  I: Integer;
begin
  for I := 0 to FRelaySinks.Count - 1 do
    TRtmpRelaySinkNode(FRelaySinks[I]).Start;

{$IFDEF USE_FFMPEG}
{$IFDEF USE_SFML}
  for I := 0 to FPlayerThreads.Count - 1 do
    TSfmlPlayerThread(FPlayerThreads[I]).Start;
{$ENDIF}
{$ENDIF}
end;

procedure TGraphGatewayApp.StopBranches;
var
  I: Integer;
begin
{$IFDEF USE_FFMPEG}
{$IFDEF USE_SFML}
  if FPlayerThreads <> nil then
    for I := 0 to FPlayerThreads.Count - 1 do
      TSfmlPlayerThread(FPlayerThreads[I]).Terminate;
{$ENDIF}
{$ENDIF}

  if FRelaySinks <> nil then
    for I := 0 to FRelaySinks.Count - 1 do
      TRtmpRelaySinkNode(FRelaySinks[I]).Stop;
end;

procedure TGraphGatewayApp.BuildGraphSection(Ini: TIniFile; const ASection: string);
var
  Buffer: TRtmpCircularBuffer;
  BufferSink: TRtmpBufferSink;
{$IFDEF USE_FFMPEG}
  CallbackPlayer: TNamedCallbackPlayerSink;
  DecoderNode: TRtmpVideoDecoderNode;
  VideoParent: TRtmpVideoDecoderNode;
{$ENDIF}
  ClientConfig: TRtmpClientConfig;
{$IFDEF USE_FFMPEG}
{$IFDEF USE_SFML}
  PlayerThread: TSfmlPlayerThread;
  SfmlPlayer: TNamedSfmlPlayerSink;
{$ENDIF}
{$ENDIF}
  Kind: string;
  Name: string;
  ParentName: string;
  PacketParent: TRtmpPacketNode;
  Policy: TRtmpRelayPolicy;
  PolicyNode: TRtmpRelayPolicyNode;
  RelaySink: TRtmpRelaySinkNode;
  StatsNode: TRtmpPacketStatsNode;
  TeeNode: TRtmpPacketTeeNode;
begin
  Name := Copy(ASection, Length('graph.') + 1, MaxInt);
  if Name = '' then
    raise Exception.CreateFmt('Graph section name is invalid: %s', [ASection]);

  Kind := ParseGraphKind(Ini.ReadString(ASection, 'kind', ''));
  ParentName := Trim(Ini.ReadString(ASection, 'parent', 'program'));
  PacketParent := nil;
{$IFDEF USE_FFMPEG}
  VideoParent := nil;
{$ENDIF}

  if (Kind = 'stats') or (Kind = 'tee') or (Kind = 'relay_policy') or
    (Kind = 'buffer') or (Kind = 'relay_sink') or (Kind = 'video_decoder') then
  begin
    PacketParent := FindPacketParent(ParentName);
    if PacketParent = nil then
      raise Exception.CreateFmt('Unknown packet parent "%s" for %s', [ParentName, ASection]);
  end;

  if Kind = 'stats' then
  begin
    StatsNode := TRtmpPacketStatsNode.Create;
    FManagedObjects.Add(StatsNode);
    PacketParent.AddSink(StatsNode);
    RegisterPacketParent(Name, StatsNode);
  end
  else if Kind = 'tee' then
  begin
    TeeNode := TRtmpPacketTeeNode.Create;
    FManagedObjects.Add(TeeNode);
    PacketParent.AddSink(TeeNode);
    RegisterPacketParent(Name, TeeNode);
  end
  else if Kind = 'relay_policy' then
  begin
    PolicyNode := TRtmpRelayPolicyNode.Create;
    Policy := TRtmpRelayPolicy.CreateDefault;
    Policy.AllowMetadata := ParseGraphBool(Ini, ASection, 'allow_metadata', True);
    Policy.AllowAudio := ParseGraphBool(Ini, ASection, 'allow_audio', True);
    Policy.AllowVideo := ParseGraphBool(Ini, ASection, 'allow_video', True);
    Policy.WaitForKeyframe := ParseGraphBool(Ini, ASection, 'wait_for_keyframe', False);
    PolicyNode.Policy := Policy;
    FManagedObjects.Add(PolicyNode);
    PacketParent.AddSink(PolicyNode);
    RegisterPacketParent(Name, PolicyNode);
  end
  else if Kind = 'buffer' then
  begin
    Buffer := TRtmpCircularBuffer.Create(
      Ini.ReadInteger(ASection, 'max_packets', FConfig.Server.BufferMaxPackets),
      ReadUInt64Value(Ini, ASection, 'max_bytes', FConfig.Server.BufferMaxBytes),
      UInt32(Ini.ReadInteger(ASection, 'max_duration_ms',
        Integer(FConfig.Server.BufferMaxDurationMS))));
    BufferSink := TRtmpBufferSink.Create(Buffer);
    FManagedObjects.Add(Buffer);
    FManagedObjects.Add(BufferSink);
    PacketParent.AddSink(BufferSink);
  end
  else if Kind = 'relay_sink' then
  begin
    RelaySink := TRtmpRelaySinkNode.Create(Name,
      Ini.ReadInteger(ASection, 'buffer_max_packets', FConfig.Server.BufferMaxPackets),
      ReadUInt64Value(Ini, ASection, 'buffer_max_bytes', FConfig.Server.BufferMaxBytes),
      UInt32(Ini.ReadInteger(ASection, 'buffer_max_duration_ms',
        Integer(FConfig.Server.BufferMaxDurationMS))));
    ClientConfig := RelaySink.Config;
    ClientConfig := ClientConfig.WithTargetUrl(Trim(Ini.ReadString(ASection,
      'target_url', '')));
    ClientConfig.App := Trim(Ini.ReadString(ASection, 'app', ''));
    ClientConfig.StreamKey := Trim(Ini.ReadString(ASection, 'stream_key', ''));
    ClientConfig.ConnectTimeoutMS := Ini.ReadInteger(ASection, 'connect_timeout_ms',
      ClientConfig.ConnectTimeoutMS);
    ClientConfig.ReconnectDelayMS := Ini.ReadInteger(ASection, 'reconnect_delay_ms',
      ClientConfig.ReconnectDelayMS);
    ClientConfig.MaxReconnectDelayMS := Ini.ReadInteger(ASection, 'max_reconnect_delay_ms',
      ClientConfig.MaxReconnectDelayMS);
    ClientConfig.OutChunkSize := Ini.ReadInteger(ASection, 'out_chunk_size',
      ClientConfig.OutChunkSize);
    ClientConfig.TimestampMode := ParseTimestampMode(
      Ini.ReadString(ASection, 'timestamp_mode', TimestampModeName(ClientConfig.TimestampMode)));
    RelaySink.Config := ClientConfig;
    if Trim(ClientConfig.TargetURL) = '' then
      raise Exception.CreateFmt('relay_sink %s requires target_url', [ASection]);

    RelaySink.Client.OnConnected := HandleRelayConnected;
    RelaySink.Client.OnDisconnected := HandleRelayDisconnected;
    RelaySink.Client.OnReconnect := HandleRelayReconnect;
    RelaySink.Client.LogSink.OnLog := HandleRelayLog;

    FManagedObjects.Add(RelaySink);
    FRelaySinks.Add(RelaySink);
    PacketParent.AddSink(RelaySink);
  end
{$IFDEF USE_FFMPEG}
  else if Kind = 'video_decoder' then
  begin
    DecoderNode := TRtmpVideoDecoderNode.Create;
    FManagedObjects.Add(DecoderNode);
    FVideoDecoders.Add(DecoderNode);
    PacketParent.AddSink(DecoderNode);
    RegisterVideoParent(Name, DecoderNode);
  end
  else if Kind = 'callback_player' then
  begin
    VideoParent := FindVideoParent(ParentName);
    if VideoParent = nil then
      raise Exception.CreateFmt('Unknown video parent "%s" for %s', [ParentName, ASection]);
    CallbackPlayer := TNamedCallbackPlayerSink.Create;
    CallbackPlayer.Name := Name;
    CallbackPlayer.LogEveryFrames := Ini.ReadInteger(ASection, 'log_every_frames', 30);
    CallbackPlayer.OnFrame := HandleCallbackPlayerFrame;
    FManagedObjects.Add(CallbackPlayer);
    FCallbackPlayers.Add(CallbackPlayer);
    VideoParent.AddSink(CallbackPlayer);
  end
{$IFDEF USE_SFML}
  else if Kind = 'sfml_player' then
  begin
    VideoParent := FindVideoParent(ParentName);
    if VideoParent = nil then
      raise Exception.CreateFmt('Unknown video parent "%s" for %s', [ParentName, ASection]);
    SfmlPlayer := TNamedSfmlPlayerSink.Create(
      Cardinal(Ini.ReadInteger(ASection, 'window_width', 960)),
      Cardinal(Ini.ReadInteger(ASection, 'window_height', 540)),
      AnsiString(Ini.ReadString(ASection, 'title', Name)));
    SfmlPlayer.Name := Name;
    FManagedObjects.Add(SfmlPlayer);
    FSfmlPlayers.Add(SfmlPlayer);
    VideoParent.AddSink(SfmlPlayer);
    PlayerThread := TSfmlPlayerThread.Create(SfmlPlayer);
    FPlayerThreads.Add(PlayerThread);
  end
{$ENDIF}
{$ENDIF}
  else
    raise Exception.CreateFmt('Unsupported graph kind "%s" in %s', [Kind, ASection]);
end;

procedure TGraphGatewayApp.BuildConfiguredGraph;
var
  I: Integer;
  Ini: TIniFile;
  Sections: TStringList;
begin
  Ini := TIniFile.Create(FConfig.ConfigPath);
  Sections := TStringList.Create;
  try
    Ini.ReadSections(Sections);
    for I := 0 to Sections.Count - 1 do
      if SameText(Copy(Sections[I], 1, Length('graph.')), 'graph.') and
        ParseGraphBool(Ini, Sections[I], 'enabled', True) then
        BuildGraphSection(Ini, Sections[I]);
  finally
    Sections.Free;
    Ini.Free;
  end;
end;

procedure TGraphGatewayApp.Run;
var
  ConfigPath: string;
begin
  if ParamCount >= 1 then
    ConfigPath := ParamStr(1)
  else
    ConfigPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
      'RtmpGraphGatewayConsole.ini';

  LoadConfig(ConfigPath);

  FServer.Config := FConfig.Server;
  FServer.MinLogLevel := llDebug;
  FServer.AttachPlaybackBuffer(FProgramBuffer);
  FProgramBuffer.MaxPackets := FConfig.Server.BufferMaxPackets;
  FProgramBuffer.MaxBytes := FConfig.Server.BufferMaxBytes;
  FProgramBuffer.MaxDurationMS := FConfig.Server.BufferMaxDurationMS;
  FSourceSwitcher.Switcher.IdleTimeoutMS := FConfig.PipelineIdleTimeoutMS;
  if FConfig.PipelineActiveSource <> '' then
    FSourceSwitcher.ForceActiveSource(FConfig.PipelineActiveSource)
  else
    FSourceSwitcher.ClearForcedSource;

  BuildConfiguredGraph;

  FServer.Start;
  try
    StartBranches;

    FStatsThread := TGraphGatewayStatsThread.Create(Self);
    FStatsThread.Start;
    PrintStartupSummary;
    WriteLn('Press Enter to stop.');
    ReadLn;

    FStatsThread.Terminate;
    FStatsThread.WaitFor;
    FreeAndNil(FStatsThread);

    StopBranches;
  finally
    FServer.Stop;
  end;
end;

function TGraphGatewayApp.ServerStats: TRtmpServerStats;
begin
  Result := FServer.GetStats;
end;

var
  App: TGraphGatewayApp;

begin
  RtmpMaskFloatingPointExceptions;
  App := TGraphGatewayApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

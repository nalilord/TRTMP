program RtmpGatewayConsole;

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
  IniFiles,
  SysUtils,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Client,
  TRTMP.RTMP.Pipeline.Switcher,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Pipeline,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Server.Session,
  TRTMP.RTMP.Types;

type
  TGatewayApp = class;

  TGatewayStatsThread = class(TThread)
  private
    FApp: TGatewayApp;
  protected
    procedure Execute; override;
  public
    constructor Create(AApp: TGatewayApp);
  end;

  TGatewayConfig = record
    ConfigPath: string;
    Server: TRtmpServerConfig;
    PipelineActiveSource: string;
    PipelineDefaultPriority: Integer;
    PipelineIdleTimeoutMS: Integer;
    PipelineSourcePriorities: string;
    RelayEnabled: Boolean;
    Client: TRtmpClientConfig;
    LogLevel: TRtmpLogLevel;
    PacketLogEvery: Integer;
  end;

  TGatewayApp = class
  private
    FClient: TRtmpClient;
    FConfig: TGatewayConfig;
    FPacketCount: UInt64;
    FProgramBuffer: TRtmpCircularBuffer;
    FProgramBufferSink: TRtmpBufferSink;
    FProgramStats: TRtmpPacketStatsNode;
    FServer: TRtmpServer;
    FSourceSwitcher: TRtmpLiveSourceSwitcherNode;
    FStatsThread: TGatewayStatsThread;
    FTeeNode: TRtmpPacketTeeNode;
    function ExtractStreamNameFromSourceID(const ASourceID: string): string;
    function ParseLogLevel(const AValue: string): TRtmpLogLevel;
    function ParsePriorityMapValue(const ASourceID: string;
      const AMapValue: string; ADefault: Integer): Integer;
    function ParseTimestampMode(const AValue: string): TRtmpTimestampMode;
    function SessionSourceID(Session: TRtmpServerSession): string;
    function ResolveSourcePriority(const ASourceID: string): Integer;
    procedure HandleClientConnected(Sender: TObject);
    procedure HandleClientDisconnected(Sender: TObject);
    procedure HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleClientReconnect(Sender: TObject);
    procedure HandlePipelineSourceChanged(Sender: TObject;
      const APreviousSourceID, ANewSourceID, AReason: string);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure HandlePublishStopped(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerClientConnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerClientDisconnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure LoadConfig(const APath: string);
    procedure PrintStartupSummary;
  public
    constructor Create;
    destructor Destroy; override;
    function ClientStats: TRtmpClientStats;
    function CurrentConfig: TGatewayConfig;
    function ServerStats: TRtmpServerStats;
    procedure Run;
  end;

function ConfigValueOrDefault(const AValue, ADefault: string): string;
begin
  if Trim(AValue) = '' then
    Result:=ADefault
  else
    Result:=AValue;
end;

function ReadUInt64Value(Ini: TIniFile; const ASection, AIdent: string;
  ADefault: UInt64): UInt64;
var
  Parsed: Int64;
  Value: string;
begin
  Value:=Trim(Ini.ReadString(ASection, AIdent, ''));
  if Value = '' then
    Exit(ADefault);

  if (NOT TryStrToInt64(Value, Parsed)) OR (Parsed < 0) then
    raise Exception.CreateFmt('Invalid unsigned integer for %s.%s: %s',
      [ASection, AIdent, Value]);
  Result:=UInt64(Parsed);
end;

function LogLevelName(ALevel: TRtmpLogLevel): string;
begin
  case ALevel of
    llDebug: Result:='debug';
    llInfo: Result:='info';
    llWarning: Result:='warn';
    llError: Result:='error';
  else
    Result:='unknown';
  end;
end;

function TimestampModeName(AMode: TRtmpTimestampMode): string;
begin
  case AMode of
    tmPassThrough: Result:='pass';
    tmRebased: Result:='rebase';
    tmSmoothed: Result:='smooth';
  else
    Result:='unknown';
  end;
end;

constructor TGatewayStatsThread.Create(AApp: TGatewayApp);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FApp:=AApp;
end;

procedure TGatewayStatsThread.Execute;
var
  ClientStats: TRtmpClientStats;
  Config: TGatewayConfig;
  PipelineStats: TRtmpPipelineStats;
  ProgramBufferStats: TRtmpBufferStats;
  SwitcherStats: TRtmpLiveSourceSwitcherStats;
  ServerStats: TRtmpServerStats;
begin
  while NOT Terminated do
  begin
    RtmpSleepMS(1000);
    if Terminated OR (FApp = nil) then
      Break;

    Config:=FApp.CurrentConfig;
    ServerStats:=FApp.ServerStats;
    PipelineStats:=FApp.FProgramStats.GetStats;
    ProgramBufferStats:=FApp.FProgramBuffer.GetStats;
    SwitcherStats:=FApp.FSourceSwitcher.Switcher.GetStats;
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
       ProgramBufferStats.PacketCount, ProgramBufferStats.ByteCount,
       ProgramBufferStats.WindowDurationMS]));

    if Config.RelayEnabled then
    begin
      ClientStats:=FApp.ClientStats;
      WriteLn(Format(
        '[RELAY] state=%d bytes=%d packets=%d bitrate=%.0f avg=%.0f reconnects=%d requests=%d',
        [Ord(FApp.FClient.State), ClientStats.BytesSent, ClientStats.PacketsSent,
         ClientStats.CurrentBitrate, ClientStats.AverageBitrate,
         ClientStats.Reconnects, ClientStats.ReconnectRequests]));
    end;
  end;
end;

constructor TGatewayApp.Create;
begin
  inherited Create;
  FClient:=TRtmpClient.Create;
  FPacketCount:=0;
  FProgramBuffer:=TRtmpCircularBuffer.Create(1024, 16 * 1024 * 1024, 3000);
  FProgramBufferSink:=TRtmpBufferSink.Create(FProgramBuffer);
  FProgramStats:=TRtmpPacketStatsNode.Create;
  FServer:=TRtmpServer.Create;
  FSourceSwitcher:=TRtmpLiveSourceSwitcherNode.Create;
  FStatsThread:=nil;
  FTeeNode:=TRtmpPacketTeeNode.Create;

  FSourceSwitcher.AddSink(FProgramStats);
  FProgramStats.AddSink(FTeeNode);
  FTeeNode.AddSink(FProgramBufferSink);

  FServer.LogSink.OnLog:=HandleServerLog;
  FServer.OnClientConnected:=HandleServerClientConnected;
  FServer.OnClientDisconnected:=HandleServerClientDisconnected;
  FServer.OnPublishStarted:=HandlePublishStarted;
  FServer.OnPublishStopped:=HandlePublishStopped;
  FServer.OnData:=HandleServerData;
  FServer.PacketSink:=FSourceSwitcher;

  FSourceSwitcher.OnActiveSourceChanged:=HandlePipelineSourceChanged;

  FClient.LogSink.OnLog:=HandleClientLog;
  FClient.OnConnected:=HandleClientConnected;
  FClient.OnDisconnected:=HandleClientDisconnected;
  FClient.OnReconnect:=HandleClientReconnect;
end;

destructor TGatewayApp.Destroy;
begin
  if FStatsThread <> nil then
  begin
    FStatsThread.Terminate;
    FStatsThread.WaitFor;
    FStatsThread.Free;
  end;
  FClient.Free;
  FServer.Free;
  FTeeNode.Free;
  FSourceSwitcher.Free;
  FProgramStats.Free;
  FProgramBufferSink.Free;
  FProgramBuffer.Free;
  inherited Destroy;
end;

function TGatewayApp.ClientStats: TRtmpClientStats;
begin
  Result:=FClient.GetStats;
end;

function TGatewayApp.CurrentConfig: TGatewayConfig;
begin
  Result:=FConfig;
end;

function TGatewayApp.ExtractStreamNameFromSourceID(const ASourceID: string): string;
var
  SlashPos: Integer;
begin
  SlashPos:=LastDelimiter('/', ASourceID);
  if SlashPos > 0 then
    Result:=Copy(ASourceID, SlashPos + 1, MaxInt)
  else
    Result:=ASourceID;
end;

function TGatewayApp.ParseLogLevel(const AValue: string): TRtmpLogLevel;
var
  Value: string;
begin
  Value:=LowerCase(Trim(AValue));
  if (Value = 'debug') then
    Result:=llDebug
  else if (Value = 'info') OR (Value = '') then
    Result:=llInfo
  else if (Value = 'warn') OR (Value = 'warning') then
    Result:=llWarning
  else if (Value = 'error') then
    Result:=llError
  else
    raise Exception.CreateFmt('Unknown log level "%s"', [AValue]);
end;

function TGatewayApp.ParsePriorityMapValue(const ASourceID: string;
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
  Result:=ADefault;
  if Trim(AMapValue) = '' then
    Exit;

  Parts:=TStringList.Create;
  try
    Parts.StrictDelimiter:=True;
    Parts.Delimiter:=',';
    Parts.DelimitedText:=AMapValue;
    for I:=0 to Parts.Count - 1 do
    begin
      Entry:=Trim(Parts[I]);
      if Entry = '' then
        Continue;

      PairPos:=Pos('=', Entry);
      if PairPos <= 1 then
        Continue;

      NamePart:=Trim(Copy(Entry, 1, PairPos - 1));
      EntryValue:=Trim(Copy(Entry, PairPos + 1, MaxInt));
      if NOT SameText(NamePart, ASourceID) then
        Continue;
      if NOT TryStrToInt(EntryValue, ParsedValue) then
        raise Exception.CreateFmt('Invalid pipeline priority for source "%s": %s',
          [ASourceID, EntryValue]);
      Exit(ParsedValue);
    end;
  finally
    Parts.Free;
  end;
end;

function TGatewayApp.ParseTimestampMode(const AValue: string): TRtmpTimestampMode;
var
  Value: string;
begin
  Value:=LowerCase(Trim(AValue));
  if (Value = '') OR (Value = 'pass') OR (Value = 'passthrough') OR
    (Value = 'pass-through') then
    Result:=tmPassThrough
  else if (Value = 'rebase') OR (Value = 'rebased') then
    Result:=tmRebased
  else if (Value = 'smooth') OR (Value = 'smoothed') then
    Result:=tmSmoothed
  else
    raise Exception.CreateFmt('Unknown timestamp mode "%s"', [AValue]);
end;

function TGatewayApp.ResolveSourcePriority(const ASourceID: string): Integer;
begin
  Result:=ParsePriorityMapValue(ASourceID, FConfig.PipelineSourcePriorities,
    FConfig.PipelineDefaultPriority);
  if Result = FConfig.PipelineDefaultPriority then
    Result:=ParsePriorityMapValue(ExtractStreamNameFromSourceID(ASourceID),
      FConfig.PipelineSourcePriorities, FConfig.PipelineDefaultPriority);
end;

function TGatewayApp.SessionSourceID(Session: TRtmpServerSession): string;
begin
  Result:='';
  if Session = nil then
    Exit;

  Result:=Trim(Session.StreamName);
  if (Trim(Session.AppName) <> '') AND (Result <> '') then
    Result:=Trim(Session.AppName) + '/' + Result;
end;

procedure MaybeForceActiveSourceAlias(ASwitcher: TRtmpLiveSourceSwitcherNode;
  const AConfiguredActiveSource, AActualSourceID, AStreamName: string);
begin
  if (ASwitcher = nil) OR (Trim(AConfiguredActiveSource) = '') then
    Exit;

  if SameText(AConfiguredActiveSource, AActualSourceID) then
    ASwitcher.ForceActiveSource(AActualSourceID)
  else if SameText(AConfiguredActiveSource, AStreamName) then
    ASwitcher.ForceActiveSource(AActualSourceID);
end;

procedure TGatewayApp.HandleClientConnected(Sender: TObject);
begin
  WriteLn('Relay connected and publish established.');
end;

procedure TGatewayApp.HandleClientDisconnected(Sender: TObject);
begin
  WriteLn('Relay disconnected.');
end;

procedure TGatewayApp.HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  if ALevel < FConfig.LogLevel then
    Exit;
  WriteLn(Format('[CLIENT][%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TGatewayApp.HandleClientReconnect(Sender: TObject);
begin
  WriteLn('Relay reconnecting.');
end;

procedure TGatewayApp.HandlePipelineSourceChanged(Sender: TObject;
  const APreviousSourceID, ANewSourceID, AReason: string);
begin
  WriteLn(Format('Program source changed: %s -> %s reason=%s',
    [APreviousSourceID, ANewSourceID, AReason]));
end;

procedure TGatewayApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
var
  SourceID: string;
begin
  SourceID:=SessionSourceID(Session);
  if SourceID <> '' then
  begin
    FSourceSwitcher.Switcher.RegisterSource(SourceID, ResolveSourcePriority(SourceID));
    MaybeForceActiveSourceAlias(FSourceSwitcher, FConfig.PipelineActiveSource,
      SourceID, Session.StreamName);
  end;
  WriteLn(Format('Publish started: stream=%s from %s:%d',
    [Session.StreamName, Session.RemoteAddress, Session.RemotePort]));
end;

procedure TGatewayApp.HandlePublishStopped(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Publish stopped: stream=%s from %s:%d',
    [Session.StreamName, Session.RemoteAddress, Session.RemotePort]));
end;

procedure TGatewayApp.HandleServerClientConnected(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Client connected: %s:%d',
    [Session.RemoteAddress, Session.RemotePort]));
end;

procedure TGatewayApp.HandleServerClientDisconnected(Sender: TObject;
  Session: TRtmpServerSession);
begin
  WriteLn(Format('Client disconnected: %s:%d',
    [Session.RemoteAddress, Session.RemotePort]));
end;

procedure TGatewayApp.HandleServerData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
begin
  Inc(FPacketCount);

  if (FConfig.LogLevel <= llInfo) AND
    (Packet.HasFlag(pfIsCodecConfig) OR Packet.HasFlag(pfIsKeyframe) OR
    ((FConfig.PacketLogEvery > 0) AND
    ((FPacketCount MOD UInt64(FConfig.PacketLogEvery)) = 0))) then
    WriteLn(Format('Packet stream=%s type=%d ts=%d size=%d keyframe=%s config=%s',
      [Session.StreamName, Ord(Packet.MessageType), Packet.Timestamp,
       Packet.PayloadSize, BoolToStr(Packet.HasFlag(pfIsKeyframe), True),
       BoolToStr(Packet.HasFlag(pfIsCodecConfig), True)]));
end;

procedure TGatewayApp.HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  if ALevel < FConfig.LogLevel then
    Exit;
  WriteLn(Format('[SERVER][%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TGatewayApp.LoadConfig(const APath: string);
var
  Ini: TIniFile;
begin
  FConfig:=Default(TGatewayConfig);
  FConfig.ConfigPath:=ExpandFileName(APath);
  FConfig.Server:=DefaultRtmpServerConfig;
  FConfig.PipelineActiveSource:='';
  FConfig.PipelineDefaultPriority:=100;
  FConfig.PipelineIdleTimeoutMS:=3000;
  FConfig.PipelineSourcePriorities:='';
  FConfig.Client:=DefaultRtmpClientConfig;
  FConfig.LogLevel:=llInfo;
  FConfig.PacketLogEvery:=0;

  if NOT FileExists(FConfig.ConfigPath) then
    raise Exception.CreateFmt('Config file not found: %s', [FConfig.ConfigPath]);

  Ini:=TIniFile.Create(FConfig.ConfigPath);
  try
    FConfig.Server.BindAddress:=ConfigValueOrDefault(
      Ini.ReadString('server', 'bind_address', FConfig.Server.BindAddress),
      FConfig.Server.BindAddress);
    FConfig.Server.Port:=Word(Ini.ReadInteger('server', 'port', FConfig.Server.Port));
    FConfig.Server.MaxSessions:=Ini.ReadInteger('server', 'max_sessions',
      FConfig.Server.MaxSessions);
    FConfig.Server.MaxChunkSize:=Ini.ReadInteger('server', 'max_chunk_size',
      FConfig.Server.MaxChunkSize);
    FConfig.Server.MaxMessageSize:=Ini.ReadInteger('server', 'max_message_size',
      FConfig.Server.MaxMessageSize);
    FConfig.Server.MaxChunkStreams:=Ini.ReadInteger('server', 'max_chunk_streams',
      FConfig.Server.MaxChunkStreams);
    FConfig.Server.ReadTimeoutMS:=Ini.ReadInteger('server', 'read_timeout_ms',
      FConfig.Server.ReadTimeoutMS);
    FConfig.Server.WriteTimeoutMS:=Ini.ReadInteger('server', 'write_timeout_ms',
      FConfig.Server.WriteTimeoutMS);
    FConfig.Server.BufferMaxPackets:=Ini.ReadInteger('server', 'buffer_max_packets',
      FConfig.Server.BufferMaxPackets);
    FConfig.Server.BufferMaxBytes:=ReadUInt64Value(Ini, 'server',
      'buffer_max_bytes', FConfig.Server.BufferMaxBytes);
    FConfig.Server.BufferMaxDurationMS:=UInt32(Ini.ReadInteger('server',
      'buffer_max_duration_ms', Integer(FConfig.Server.BufferMaxDurationMS)));
    FConfig.Server.EnableAnalyzer:=Ini.ReadBool('server', 'enable_analyzer',
      FConfig.Server.EnableAnalyzer);
    FConfig.Server.Tls.Enabled:=Ini.ReadBool('server', 'tls_enabled',
      FConfig.Server.Tls.Enabled);
    FConfig.Server.Tls.CertificateFile:=Trim(Ini.ReadString('server',
      'tls_certificate_file', FConfig.Server.Tls.CertificateFile));
    FConfig.Server.Tls.CertificatePassword:=Ini.ReadString('server',
      'tls_certificate_password', FConfig.Server.Tls.CertificatePassword);
    FConfig.Server.Tls.PrivateKeyFile:=Trim(Ini.ReadString('server',
      'tls_private_key_file', FConfig.Server.Tls.PrivateKeyFile));
    FConfig.Server.Tls.CAFile:=Trim(Ini.ReadString('server', 'tls_ca_file',
      FConfig.Server.Tls.CAFile));
    FConfig.Server.Tls.CAPath:=Trim(Ini.ReadString('server', 'tls_ca_path',
      FConfig.Server.Tls.CAPath));
    FConfig.Server.Tls.RequireClientCertificate:=Ini.ReadBool('server',
      'tls_require_client_certificate',
      FConfig.Server.Tls.RequireClientCertificate);

    FConfig.PipelineIdleTimeoutMS:=Ini.ReadInteger('pipeline', 'idle_timeout_ms',
      FConfig.PipelineIdleTimeoutMS);
    FConfig.PipelineDefaultPriority:=Ini.ReadInteger('pipeline',
      'default_priority', FConfig.PipelineDefaultPriority);
    FConfig.PipelineActiveSource:=Trim(Ini.ReadString('pipeline', 'active_source',
      FConfig.PipelineActiveSource));
    FConfig.PipelineSourcePriorities:=Trim(Ini.ReadString('pipeline',
      'source_priorities', FConfig.PipelineSourcePriorities));

    FConfig.RelayEnabled:=Ini.ReadBool('relay', 'enabled', False);
    FConfig.Client.TargetURL:=Trim(Ini.ReadString('relay', 'target_url', ''));
    FConfig.Client.App:=Trim(Ini.ReadString('relay', 'app', ''));
    FConfig.Client.StreamKey:=Trim(Ini.ReadString('relay', 'stream_key', ''));
    FConfig.Client.ConnectTimeoutMS:=Ini.ReadInteger('relay', 'connect_timeout_ms',
      FConfig.Client.ConnectTimeoutMS);
    FConfig.Client.ReconnectDelayMS:=Ini.ReadInteger('relay', 'reconnect_delay_ms',
      FConfig.Client.ReconnectDelayMS);
    FConfig.Client.MaxReconnectDelayMS:=Ini.ReadInteger('relay',
      'max_reconnect_delay_ms', FConfig.Client.MaxReconnectDelayMS);
    FConfig.Client.ReconnectBoundaryTimeoutMS:=Ini.ReadInteger('relay',
      'reconnect_boundary_timeout_ms',
      FConfig.Client.ReconnectBoundaryTimeoutMS);
    FConfig.Client.OutChunkSize:=Ini.ReadInteger('relay', 'out_chunk_size',
      FConfig.Client.OutChunkSize);
    FConfig.Client.TimestampMode:=ParseTimestampMode(
      Ini.ReadString('relay', 'timestamp_mode',
        TimestampModeName(FConfig.Client.TimestampMode)));
    FConfig.Client.RequiredAudioTrackID:=Ini.ReadInteger('relay',
      'required_audio_track_id', FConfig.Client.RequiredAudioTrackID);
    FConfig.Client.Tls.VerifyPeer:=Ini.ReadBool('relay', 'tls_verify_peer',
      FConfig.Client.Tls.VerifyPeer);
    FConfig.Client.Tls.ServerName:=Trim(Ini.ReadString('relay',
      'tls_server_name', FConfig.Client.Tls.ServerName));
    FConfig.Client.Tls.CAFile:=Trim(Ini.ReadString('relay', 'tls_ca_file',
      FConfig.Client.Tls.CAFile));
    FConfig.Client.Tls.CAPath:=Trim(Ini.ReadString('relay', 'tls_ca_path',
      FConfig.Client.Tls.CAPath));
    FConfig.Client.Tls.CertificateFile:=Trim(Ini.ReadString('relay',
      'tls_certificate_file', FConfig.Client.Tls.CertificateFile));
    FConfig.Client.Tls.CertificatePassword:=Ini.ReadString('relay',
      'tls_certificate_password', FConfig.Client.Tls.CertificatePassword);
    FConfig.Client.Tls.PrivateKeyFile:=Trim(Ini.ReadString('relay',
      'tls_private_key_file', FConfig.Client.Tls.PrivateKeyFile));
    FConfig.Client.AllowInsecureRedirect:=Ini.ReadBool('relay',
      'allow_insecure_redirect', FConfig.Client.AllowInsecureRedirect);
    if Ini.ReadBool('relay', 'require_twitch_vod_audio', False) then
      FConfig.Client.RequiredAudioTrackID:=1;

    FConfig.LogLevel:=ParseLogLevel(Ini.ReadString('logging', 'level', 'info'));
    FConfig.PacketLogEvery:=Ini.ReadInteger('logging', 'packet_log_every', 0);
  finally
    Ini.Free;
  end;

  if FConfig.RelayEnabled AND (FConfig.Client.TargetURL = '') then
    raise Exception.Create('relay.enabled=true requires relay.target_url');
end;

procedure TGatewayApp.PrintStartupSummary;
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
  if FConfig.RelayEnabled then
  begin
    WriteLn(Format('Relay enabled: %s', [FConfig.Client.TargetURL]));
    WriteLn(Format('Relay timestamp mode: %s',
      [TimestampModeName(FConfig.Client.TimestampMode)]));
    if FConfig.Client.RequiredAudioTrackID >= 0 then
      WriteLn(Format('Relay required audio track: %d',
        [FConfig.Client.RequiredAudioTrackID]));
  end
  else
    WriteLn('Relay enabled: False');
end;

procedure TGatewayApp.Run;
var
  ConfigPath: string;
begin
  if ParamCount >= 1 then
    ConfigPath:=ParamStr(1)
  else
    ConfigPath:=IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
      'RtmpGatewayConsole.ini';

  LoadConfig(ConfigPath);

  FServer.Config:=FConfig.Server;
  FServer.MinLogLevel:=llDebug;
  FServer.AttachPlaybackBuffer(FProgramBuffer);
  FProgramBuffer.MaxPackets:=FConfig.Server.BufferMaxPackets;
  FProgramBuffer.MaxBytes:=FConfig.Server.BufferMaxBytes;
  FProgramBuffer.MaxDurationMS:=FConfig.Server.BufferMaxDurationMS;
  FSourceSwitcher.Switcher.IdleTimeoutMS:=FConfig.PipelineIdleTimeoutMS;
  if FConfig.PipelineActiveSource <> '' then
    FSourceSwitcher.ForceActiveSource(FConfig.PipelineActiveSource)
  else
    FSourceSwitcher.ClearForcedSource;

  if FConfig.RelayEnabled then
  begin
    FClient.Config:=FConfig.Client;
    FClient.AttachBuffer(FProgramBuffer);
  end;

  FServer.Start;
  try
    if FConfig.RelayEnabled then
      FClient.Start;

    FStatsThread:=TGatewayStatsThread.Create(Self);
    FStatsThread.Start;
    PrintStartupSummary;
    WriteLn('Press Enter to stop.');
    ReadLn;

    FStatsThread.Terminate;
    FStatsThread.WaitFor;
    FreeAndNil(FStatsThread);

    if FConfig.RelayEnabled then
      FClient.Stop;
  finally
    FServer.Stop;
  end;
end;

function TGatewayApp.ServerStats: TRtmpServerStats;
begin
  Result:=FServer.GetStats;
end;

var
  App: TGatewayApp;

begin
  App:=TGatewayApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

unit RtmpPipeline;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  Classes,
  SyncObjs,
  SysUtils,
  RtmpBuffer,
  RtmpClient,
  RtmpLiveSourceSwitcher,
  RtmpPacket,
  RtmpTypes;

type
  TRtmpPipelineStats = record
    StreamStarts: UInt64;
    StreamStops: UInt64;
    Packets: UInt64;
    Bytes: UInt64;
    LastSourceID: string;
    LastStreamName: string;
  end;

  TRtmpRelayPolicy = record
    AllowMetadata: Boolean;
    AllowAudio: Boolean;
    AllowVideo: Boolean;
    WaitForKeyframe: Boolean;
    class function CreateDefault: TRtmpRelayPolicy; static;
  end;

  TRtmpPacketSink = class
  public
    procedure HandleStreamStarted(const ASourceID, AStreamName: string); virtual;
    procedure HandlePacket(const ASourceID: string; APacket: TRtmpPacket); virtual; abstract;
    procedure HandleStreamStopped(const ASourceID, AStreamName: string); virtual;
  end;

  TRtmpPacketNode = class(TRtmpPacketSink)
  private
    FLock: TCriticalSection;
    FSinks: TList;
  protected
    procedure NotifyPacket(const ASourceID: string; APacket: TRtmpPacket);
    procedure NotifyStreamStarted(const ASourceID, AStreamName: string);
    procedure NotifyStreamStopped(const ASourceID, AStreamName: string);
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddSink(ASink: TRtmpPacketSink);
    procedure RemoveSink(ASink: TRtmpPacketSink);

    procedure HandleStreamStarted(const ASourceID, AStreamName: string); override;
    procedure HandlePacket(const ASourceID: string; APacket: TRtmpPacket); override;
    procedure HandleStreamStopped(const ASourceID, AStreamName: string); override;
  end;

  TRtmpPacketTeeNode = class(TRtmpPacketNode)
  end;

  TRtmpPacketStatsNode = class(TRtmpPacketNode)
  private
    FLock: TCriticalSection;
    FStats: TRtmpPipelineStats;
  public
    constructor Create;
    destructor Destroy; override;

    function GetStats: TRtmpPipelineStats;
    procedure HandleStreamStarted(const ASourceID, AStreamName: string); override;
    procedure HandlePacket(const ASourceID: string; APacket: TRtmpPacket); override;
    procedure HandleStreamStopped(const ASourceID, AStreamName: string); override;
  end;

  TRtmpBufferSink = class(TRtmpPacketSink)
  private
    FBuffer: TRtmpCircularBuffer;
  public
    constructor Create(ABuffer: TRtmpCircularBuffer);
    procedure HandlePacket(const ASourceID: string; APacket: TRtmpPacket); override;
  end;

  TRtmpRelayPolicyNode = class(TRtmpPacketNode)
  private
    FActiveSourceID: string;
    FActiveStreamName: string;
    FPolicy: TRtmpRelayPolicy;
    FWaitingForKeyframe: Boolean;
    function PacketAllowed(APacket: TRtmpPacket): Boolean;
    procedure ResetSourceState(const ASourceID, AStreamName: string);
  public
    constructor Create;
    procedure HandleStreamStarted(const ASourceID, AStreamName: string); override;
    procedure HandlePacket(const ASourceID: string; APacket: TRtmpPacket); override;
    procedure HandleStreamStopped(const ASourceID, AStreamName: string); override;
    property Policy: TRtmpRelayPolicy read FPolicy write FPolicy;
  end;

  TRtmpRelaySinkNode = class(TRtmpPacketSink)
  private
    FBuffer: TRtmpCircularBuffer;
    FClient: TRtmpClient;
    FConfig: TRtmpClientConfig;
    FName: string;
    FStarted: Boolean;
  public
    constructor Create(const AName: string; AMaxPackets: Integer;
      AMaxBytes: UInt64; AMaxDurationMS: UInt32);
    destructor Destroy; override;

    function BufferStats: TRtmpBufferStats;
    function ClientStats: TRtmpClientStats;
    procedure HandlePacket(const ASourceID: string; APacket: TRtmpPacket); override;
    procedure Start;
    procedure Stop;

    property Buffer: TRtmpCircularBuffer read FBuffer;
    property Client: TRtmpClient read FClient;
    property Config: TRtmpClientConfig read FConfig write FConfig;
    property Name: string read FName;
  end;

  TRtmpLiveSourceSwitcherNode = class(TRtmpPacketNode)
  private
    FOnActiveSourceChanged: TRtmpLiveSourceSwitchEvent;
    FSwitcher: TRtmpLiveSourceSwitcher;
    procedure HandleSwitcherOutputPacket(Sender: TObject; const ASourceID: string;
      APacket: TRtmpPacket);
    procedure HandleSwitcherSourceChanged(Sender: TObject;
      const APreviousSourceID, ANewSourceID, AReason: string);
  public
    constructor Create(AOutputBuffer: TRtmpCircularBuffer = nil);
    destructor Destroy; override;

    procedure ClearForcedSource;
    procedure ForceActiveSource(const ASourceID: string);
    function Switcher: TRtmpLiveSourceSwitcher;

    procedure HandleStreamStarted(const ASourceID, AStreamName: string); override;
    procedure HandlePacket(const ASourceID: string; APacket: TRtmpPacket); override;
    procedure HandleStreamStopped(const ASourceID, AStreamName: string); override;

    property OnActiveSourceChanged: TRtmpLiveSourceSwitchEvent
      read FOnActiveSourceChanged write FOnActiveSourceChanged;
  end;

implementation

class function TRtmpRelayPolicy.CreateDefault: TRtmpRelayPolicy;
begin
  Result := Default(TRtmpRelayPolicy);
  Result.AllowMetadata := True;
  Result.AllowAudio := True;
  Result.AllowVideo := True;
  Result.WaitForKeyframe := False;
end;

procedure TRtmpPacketSink.HandleStreamStarted(const ASourceID, AStreamName: string);
begin
end;

procedure TRtmpPacketSink.HandleStreamStopped(const ASourceID, AStreamName: string);
begin
end;

constructor TRtmpPacketNode.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSinks := TList.Create;
end;

destructor TRtmpPacketNode.Destroy;
begin
  FSinks.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRtmpPacketNode.AddSink(ASink: TRtmpPacketSink);
begin
  if ASink = nil then
    Exit;

  FLock.Acquire;
  try
    if FSinks.IndexOf(ASink) < 0 then
      FSinks.Add(ASink);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpPacketNode.RemoveSink(ASink: TRtmpPacketSink);
begin
  FLock.Acquire;
  try
    FSinks.Remove(ASink);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpPacketNode.NotifyStreamStarted(const ASourceID, AStreamName: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FSinks.Count - 1 do
      TRtmpPacketSink(FSinks[I]).HandleStreamStarted(ASourceID, AStreamName);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpPacketNode.NotifyPacket(const ASourceID: string; APacket: TRtmpPacket);
var
  I: Integer;
begin
  if APacket = nil then
    Exit;

  FLock.Acquire;
  try
    for I := 0 to FSinks.Count - 1 do
      TRtmpPacketSink(FSinks[I]).HandlePacket(ASourceID, APacket);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpPacketNode.NotifyStreamStopped(const ASourceID, AStreamName: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FSinks.Count - 1 do
      TRtmpPacketSink(FSinks[I]).HandleStreamStopped(ASourceID, AStreamName);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpPacketNode.HandleStreamStarted(const ASourceID, AStreamName: string);
begin
  NotifyStreamStarted(ASourceID, AStreamName);
end;

procedure TRtmpPacketNode.HandlePacket(const ASourceID: string; APacket: TRtmpPacket);
begin
  NotifyPacket(ASourceID, APacket);
end;

procedure TRtmpPacketNode.HandleStreamStopped(const ASourceID, AStreamName: string);
begin
  NotifyStreamStopped(ASourceID, AStreamName);
end;

constructor TRtmpPacketStatsNode.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FStats := Default(TRtmpPipelineStats);
end;

destructor TRtmpPacketStatsNode.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TRtmpPacketStatsNode.GetStats: TRtmpPipelineStats;
begin
  FLock.Acquire;
  try
    Result := FStats;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpPacketStatsNode.HandleStreamStarted(const ASourceID,
  AStreamName: string);
begin
  FLock.Acquire;
  try
    Inc(FStats.StreamStarts);
    FStats.LastSourceID := ASourceID;
    FStats.LastStreamName := AStreamName;
  finally
    FLock.Release;
  end;
  inherited HandleStreamStarted(ASourceID, AStreamName);
end;

procedure TRtmpPacketStatsNode.HandlePacket(const ASourceID: string;
  APacket: TRtmpPacket);
begin
  FLock.Acquire;
  try
    Inc(FStats.Packets);
    Inc(FStats.Bytes, UInt64(APacket.PayloadSize));
    FStats.LastSourceID := ASourceID;
  finally
    FLock.Release;
  end;
  inherited HandlePacket(ASourceID, APacket);
end;

procedure TRtmpPacketStatsNode.HandleStreamStopped(const ASourceID,
  AStreamName: string);
begin
  FLock.Acquire;
  try
    Inc(FStats.StreamStops);
    FStats.LastSourceID := ASourceID;
    FStats.LastStreamName := AStreamName;
  finally
    FLock.Release;
  end;
  inherited HandleStreamStopped(ASourceID, AStreamName);
end;

constructor TRtmpBufferSink.Create(ABuffer: TRtmpCircularBuffer);
begin
  inherited Create;
  FBuffer := ABuffer;
end;

procedure TRtmpBufferSink.HandlePacket(const ASourceID: string; APacket: TRtmpPacket);
begin
  if (FBuffer = nil) or (APacket = nil) then
    Exit;
  FBuffer.Push(APacket.CloneShallow);
end;

constructor TRtmpRelayPolicyNode.Create;
begin
  inherited Create;
  FPolicy := TRtmpRelayPolicy.CreateDefault;
  FActiveSourceID := '';
  FActiveStreamName := '';
  FWaitingForKeyframe := False;
end;

function TRtmpRelayPolicyNode.PacketAllowed(APacket: TRtmpPacket): Boolean;
begin
  Result := False;
  if APacket = nil then
    Exit;

  if APacket.HasFlag(pfIsMetadata) then
    Exit(FPolicy.AllowMetadata);
  if APacket.HasFlag(pfIsAudio) then
    Exit(FPolicy.AllowAudio);
  if APacket.HasFlag(pfIsVideo) then
    Exit(FPolicy.AllowVideo);
end;

procedure TRtmpRelayPolicyNode.ResetSourceState(const ASourceID,
  AStreamName: string);
begin
  FActiveSourceID := ASourceID;
  FActiveStreamName := AStreamName;
  FWaitingForKeyframe := FPolicy.WaitForKeyframe;
end;

procedure TRtmpRelayPolicyNode.HandleStreamStarted(const ASourceID,
  AStreamName: string);
begin
  ResetSourceState(ASourceID, AStreamName);
  inherited HandleStreamStarted(ASourceID, AStreamName);
end;

procedure TRtmpRelayPolicyNode.HandlePacket(const ASourceID: string;
  APacket: TRtmpPacket);
begin
  if APacket = nil then
    Exit;

  if not SameText(FActiveSourceID, ASourceID) then
    ResetSourceState(ASourceID, FActiveStreamName);

  if not PacketAllowed(APacket) then
    Exit;

  if FWaitingForKeyframe and APacket.HasFlag(pfIsVideo) and
    (not APacket.HasFlag(pfIsCodecConfig)) then
  begin
    if not APacket.HasFlag(pfIsKeyframe) then
      Exit;
    FWaitingForKeyframe := False;
  end;

  inherited HandlePacket(ASourceID, APacket);
end;

procedure TRtmpRelayPolicyNode.HandleStreamStopped(const ASourceID,
  AStreamName: string);
begin
  if SameText(FActiveSourceID, ASourceID) then
    ResetSourceState('', '');
  inherited HandleStreamStopped(ASourceID, AStreamName);
end;

constructor TRtmpRelaySinkNode.Create(const AName: string; AMaxPackets: Integer;
  AMaxBytes: UInt64; AMaxDurationMS: UInt32);
begin
  inherited Create;
  FName := Trim(AName);
  FConfig := DefaultRtmpClientConfig;
  FBuffer := TRtmpCircularBuffer.Create(AMaxPackets, AMaxBytes, AMaxDurationMS);
  FClient := TRtmpClient.Create;
  FClient.AttachBuffer(FBuffer);
  FStarted := False;
end;

destructor TRtmpRelaySinkNode.Destroy;
begin
  Stop;
  FClient.Free;
  FBuffer.Free;
  inherited Destroy;
end;

function TRtmpRelaySinkNode.BufferStats: TRtmpBufferStats;
begin
  if FBuffer <> nil then
    Result := FBuffer.GetStats
  else
    Result := Default(TRtmpBufferStats);
end;

function TRtmpRelaySinkNode.ClientStats: TRtmpClientStats;
begin
  if FClient <> nil then
    Result := FClient.GetStats
  else
    Result := Default(TRtmpClientStats);
end;

procedure TRtmpRelaySinkNode.HandlePacket(const ASourceID: string;
  APacket: TRtmpPacket);
begin
  if (FBuffer = nil) or (APacket = nil) then
    Exit;
  FBuffer.Push(APacket.CloneShallow);
end;

procedure TRtmpRelaySinkNode.Start;
begin
  if FStarted or (FClient = nil) then
    Exit;
  FClient.Config := FConfig;
  FClient.Start;
  FStarted := True;
end;

procedure TRtmpRelaySinkNode.Stop;
begin
  if not FStarted or (FClient = nil) then
    Exit;
  FClient.Stop;
  FStarted := False;
end;

constructor TRtmpLiveSourceSwitcherNode.Create(AOutputBuffer: TRtmpCircularBuffer);
begin
  inherited Create;
  FSwitcher := TRtmpLiveSourceSwitcher.Create(AOutputBuffer);
  FSwitcher.OnOutputPacket := HandleSwitcherOutputPacket;
  FSwitcher.OnActiveSourceChanged := HandleSwitcherSourceChanged;
end;

destructor TRtmpLiveSourceSwitcherNode.Destroy;
begin
  FSwitcher.Free;
  inherited Destroy;
end;

procedure TRtmpLiveSourceSwitcherNode.HandleSwitcherOutputPacket(Sender: TObject;
  const ASourceID: string; APacket: TRtmpPacket);
begin
  NotifyPacket(ASourceID, APacket);
end;

procedure TRtmpLiveSourceSwitcherNode.HandleSwitcherSourceChanged(Sender: TObject;
  const APreviousSourceID, ANewSourceID, AReason: string);
var
  PreviousStreamName: string;
  NewStreamName: string;
begin
  if APreviousSourceID <> '' then
  begin
    PreviousStreamName := FSwitcher.GetSourceStreamName(APreviousSourceID);
    NotifyStreamStopped(APreviousSourceID, PreviousStreamName);
  end;

  if ANewSourceID <> '' then
  begin
    NewStreamName := FSwitcher.GetSourceStreamName(ANewSourceID);
    NotifyStreamStarted(ANewSourceID, NewStreamName);
  end;

  if Assigned(FOnActiveSourceChanged) then
    FOnActiveSourceChanged(Self, APreviousSourceID, ANewSourceID, AReason);
end;

procedure TRtmpLiveSourceSwitcherNode.HandleStreamStarted(const ASourceID,
  AStreamName: string);
begin
  FSwitcher.NoteSourceStarted(ASourceID, AStreamName);
end;

procedure TRtmpLiveSourceSwitcherNode.HandlePacket(const ASourceID: string;
  APacket: TRtmpPacket);
begin
  FSwitcher.NoteSourcePacket(ASourceID, APacket);
end;

procedure TRtmpLiveSourceSwitcherNode.HandleStreamStopped(const ASourceID,
  AStreamName: string);
begin
  FSwitcher.NoteSourceStopped(ASourceID);
end;

procedure TRtmpLiveSourceSwitcherNode.ClearForcedSource;
begin
  FSwitcher.ClearForcedSource;
end;

procedure TRtmpLiveSourceSwitcherNode.ForceActiveSource(const ASourceID: string);
begin
  FSwitcher.ForceActiveSource(ASourceID);
end;

function TRtmpLiveSourceSwitcherNode.Switcher: TRtmpLiveSourceSwitcher;
begin
  Result := FSwitcher;
end;

end.

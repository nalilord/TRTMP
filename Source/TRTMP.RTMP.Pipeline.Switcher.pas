unit TRTMP.RTMP.Pipeline.Switcher;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  Classes,
  Contnrs,
  SyncObjs,
  SysUtils,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Types;

type
  TRtmpLiveSourceSwitcherStats = record
    ActiveSourceID: string;
    SourceCount: Integer;
    SwitchCount: UInt64;
    ManualSwitchCount: UInt64;
    FailoverSwitchCount: UInt64;
    IdleTimeoutCount: UInt64;
    OutputPackets: UInt64;
    OutputBytes: UInt64;
    LastOutputTimestamp: UInt32;
  end;

  TRtmpLiveSourceSwitchEvent = procedure(Sender: TObject;
    const APreviousSourceID, ANewSourceID, AReason: string) of object;
  TRtmpLiveSourceOutputPacketEvent = procedure(Sender: TObject;
    const ASourceID: string; APacket: TRtmpPacket) of object;

  TRtmpLiveSourceSwitcher = class;

  TRtmpLiveSourceSwitcherMonitorThread = class(TThread)
  private
    FSwitcher: TRtmpLiveSourceSwitcher;
  protected
    procedure Execute; override;
  public
    constructor Create(ASwitcher: TRtmpLiveSourceSwitcher);
  end;

  TRtmpLiveSourceSwitcher = class
  private type
    TRtmpSourceState = class
    public
      SourceID: string;
      StreamName: string;
      Priority: Integer;
      Started: Boolean;
      LastPacketTick: TRtmpTick;
      SawVideo: Boolean;
      PendingBootstrap: Boolean;
      SegmentInputBase: UInt32;
      SegmentOutputBase: UInt32;
      LatestMetadata: TRtmpPacket;
      LatestAudioConfig: TRtmpPacket;
      LatestVideoConfig: TRtmpPacket;

      constructor Create;
      destructor Destroy; override;
      procedure ClearRetained;
      procedure ReplaceRetained(var ATarget: TRtmpPacket; ASource: TRtmpPacket);
    end;
  private
    FEvaluationIntervalMS: Integer;
    FForcedSourceID: string;
    FIdleTimeoutMS: Integer;
    FLock: TCriticalSection;
    FMonitorThread: TRtmpLiveSourceSwitcherMonitorThread;
    FOnActiveSourceChanged: TRtmpLiveSourceSwitchEvent;
    FOnOutputPacket: TRtmpLiveSourceOutputPacketEvent;
    FOutputBuffer: TRtmpCircularBuffer;
    FOwnsOutputBuffer: Boolean;
    FSources: TObjectList;
    FStats: TRtmpLiveSourceSwitcherStats;
    function BuildOutputPacket(ASource: TRtmpSourceState;
      APacket: TRtmpPacket; AOutputTimestamp: UInt32): TRtmpPacket;
    function FindSourceLocked(const ASourceID: string): TRtmpSourceState;
    procedure EmitOutputPacket(const ASourceID: string; APacket: TRtmpPacket);
    function GetActiveSourceID: string;
    function GetActiveStreamName: string;
    function GetOrCreateSourceLocked(const ASourceID: string): TRtmpSourceState;
    function IsBootstrapHeader(APacket: TRtmpPacket): Boolean;
    function IsSourceEligibleLocked(ASource: TRtmpSourceState;
      ANow: TRtmpTick): Boolean;
    function MapOutputTimestampLocked(ASource: TRtmpSourceState;
      APacket: TRtmpPacket): UInt32;
    function SelectBestSourceLocked(ANow: TRtmpTick): TRtmpSourceState;
    procedure ActivateSourceLocked(ANewSource: TRtmpSourceState);
    procedure AttachOwnedBufferIfNeeded;
    procedure EvaluateLocked(ANow: TRtmpTick; out APreviousSourceID,
      ANewSourceID, AReason: string);
    procedure PushBootstrapHeadersLocked(ASource: TRtmpSourceState);
    procedure RoutePacketLocked(ASource: TRtmpSourceState; APacket: TRtmpPacket);
    procedure UpdateRetainedLocked(ASource: TRtmpSourceState; APacket: TRtmpPacket);
  public
    constructor Create(AOutputBuffer: TRtmpCircularBuffer = nil);
    destructor Destroy; override;

    procedure AttachOutputBuffer(AOutputBuffer: TRtmpCircularBuffer);
    procedure ClearForcedSource;
    procedure Evaluate;
    procedure ForceActiveSource(const ASourceID: string);
    function ActiveStreamName: string;
    function GetStats: TRtmpLiveSourceSwitcherStats;
    function GetSourceStreamName(const ASourceID: string): string;
    procedure NoteSourcePacket(const ASourceID: string; APacket: TRtmpPacket);
    procedure NoteSourceStarted(const ASourceID: string;
      const AStreamName: string = '');
    procedure NoteSourceStopped(const ASourceID: string);
    procedure RegisterSource(const ASourceID: string; APriority: Integer = 100);
    procedure UnregisterSource(const ASourceID: string);

    property ActiveSourceID: string read GetActiveSourceID;
    property EvaluationIntervalMS: Integer read FEvaluationIntervalMS write FEvaluationIntervalMS;
    property IdleTimeoutMS: Integer read FIdleTimeoutMS write FIdleTimeoutMS;
    property OnActiveSourceChanged: TRtmpLiveSourceSwitchEvent
      read FOnActiveSourceChanged write FOnActiveSourceChanged;
    property OnOutputPacket: TRtmpLiveSourceOutputPacketEvent
      read FOnOutputPacket write FOnOutputPacket;
    property OutputBuffer: TRtmpCircularBuffer read FOutputBuffer;
  end;

implementation

const
  DEFAULT_BUFFER_MAX_PACKETS = 1024;
  DEFAULT_BUFFER_MAX_BYTES = UInt64(16 * 1024 * 1024);
  DEFAULT_BUFFER_MAX_DURATION_MS = 3000;

constructor TRtmpLiveSourceSwitcher.TRtmpSourceState.Create;
begin
  inherited Create;
  Priority:=100;
  Started:=False;
  LastPacketTick:=0;
  SawVideo:=False;
  PendingBootstrap:=False;
  SegmentInputBase:=0;
  SegmentOutputBase:=0;
  LatestMetadata:=nil;
  LatestAudioConfig:=nil;
  LatestVideoConfig:=nil;
end;

destructor TRtmpLiveSourceSwitcher.TRtmpSourceState.Destroy;
begin
  ClearRetained;
  inherited Destroy;
end;

procedure TRtmpLiveSourceSwitcher.TRtmpSourceState.ClearRetained;
begin
  FreeAndNil(LatestMetadata);
  FreeAndNil(LatestAudioConfig);
  FreeAndNil(LatestVideoConfig);
end;

procedure TRtmpLiveSourceSwitcher.TRtmpSourceState.ReplaceRetained(
  var ATarget: TRtmpPacket; ASource: TRtmpPacket);
begin
  FreeAndNil(ATarget);
  if ASource <> nil then
    ATarget:=ASource.CloneShallow;
end;

constructor TRtmpLiveSourceSwitcherMonitorThread.Create(
  ASwitcher: TRtmpLiveSourceSwitcher);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FSwitcher:=ASwitcher;
end;

procedure TRtmpLiveSourceSwitcherMonitorThread.Execute;
var
  IntervalMS: Integer;
begin
  while NOT Terminated do
  begin
    if FSwitcher = nil then
      Break;

    IntervalMS:=FSwitcher.EvaluationIntervalMS;
    if IntervalMS <= 0 then
      IntervalMS:=100;
    RtmpSleepMS(IntervalMS);
    if Terminated then
      Break;
    FSwitcher.Evaluate;
  end;
end;

constructor TRtmpLiveSourceSwitcher.Create(AOutputBuffer: TRtmpCircularBuffer);
begin
  inherited Create;
  FLock:=TCriticalSection.Create;
  FSources:=TObjectList.Create(True);
  FIdleTimeoutMS:=3000;
  FEvaluationIntervalMS:=100;
  FOutputBuffer:=AOutputBuffer;
  FOwnsOutputBuffer:=AOutputBuffer = nil;
  AttachOwnedBufferIfNeeded;
  FMonitorThread:=TRtmpLiveSourceSwitcherMonitorThread.Create(Self);
  FMonitorThread.Start;
end;

destructor TRtmpLiveSourceSwitcher.Destroy;
begin
  if FMonitorThread <> nil then
  begin
    FMonitorThread.Terminate;
    FMonitorThread.WaitFor;
    FreeAndNil(FMonitorThread);
  end;
  FSources.Free;
  if FOwnsOutputBuffer then
    FreeAndNil(FOutputBuffer);
  FLock.Free;
  inherited Destroy;
end;

procedure TRtmpLiveSourceSwitcher.AttachOwnedBufferIfNeeded;
begin
  if FOutputBuffer = nil then
    FOutputBuffer:=TRtmpCircularBuffer.Create(DEFAULT_BUFFER_MAX_PACKETS,
      DEFAULT_BUFFER_MAX_BYTES, DEFAULT_BUFFER_MAX_DURATION_MS);
end;

procedure TRtmpLiveSourceSwitcher.AttachOutputBuffer(
  AOutputBuffer: TRtmpCircularBuffer);
begin
  if AOutputBuffer = nil then
    Exit;

  FLock.Acquire;
  try
    if FOwnsOutputBuffer then
      FreeAndNil(FOutputBuffer);
    FOutputBuffer:=AOutputBuffer;
    FOwnsOutputBuffer:=False;
  finally
    FLock.Release;
  end;
end;

function TRtmpLiveSourceSwitcher.FindSourceLocked(
  const ASourceID: string): TRtmpSourceState;
var
  I: Integer;
begin
  Result:=nil;
  for I:=0 to FSources.Count - 1 do
    if SameText(TRtmpSourceState(FSources[I]).SourceID, ASourceID) then
      Exit(TRtmpSourceState(FSources[I]));
end;

procedure TRtmpLiveSourceSwitcher.EmitOutputPacket(const ASourceID: string;
  APacket: TRtmpPacket);
var
  DispatchPacket: TRtmpPacket;
begin
  if (NOT Assigned(FOnOutputPacket)) OR (APacket = nil) then
    Exit;

  DispatchPacket:=APacket.CloneShallow;
  try
    FOnOutputPacket(Self, ASourceID, DispatchPacket);
  finally
    DispatchPacket.Free;
  end;
end;

function TRtmpLiveSourceSwitcher.GetOrCreateSourceLocked(
  const ASourceID: string): TRtmpSourceState;
begin
  Result:=FindSourceLocked(ASourceID);
  if Result <> nil then
    Exit;

  Result:=TRtmpSourceState.Create;
  Result.SourceID:=ASourceID;
  FSources.Add(Result);
end;

procedure TRtmpLiveSourceSwitcher.RegisterSource(const ASourceID: string;
  APriority: Integer);
var
  Source: TRtmpSourceState;
begin
  FLock.Acquire;
  try
    Source:=GetOrCreateSourceLocked(ASourceID);
    Source.Priority:=APriority;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpLiveSourceSwitcher.UnregisterSource(const ASourceID: string);
var
  I: Integer;
  PreviousSourceID: string;
  NewSourceID: string;
  Reason: string;
begin
  PreviousSourceID:='';
  NewSourceID:='';
  Reason:='';

  FLock.Acquire;
  try
    for I:=FSources.Count - 1 downto 0 do
      if SameText(TRtmpSourceState(FSources[I]).SourceID, ASourceID) then
      begin
        if SameText(FStats.ActiveSourceID, ASourceID) then
          EvaluateLocked(RtmpGetTickCount64, PreviousSourceID, NewSourceID, Reason);
        FSources.Delete(I);
        Break;
      end;
    FStats.SourceCount:=FSources.Count;
  finally
    FLock.Release;
  end;

  if Assigned(FOnActiveSourceChanged) AND (Reason <> '') then
    FOnActiveSourceChanged(Self, PreviousSourceID, NewSourceID, Reason);
end;

procedure TRtmpLiveSourceSwitcher.NoteSourceStarted(const ASourceID,
  AStreamName: string);
var
  Source: TRtmpSourceState;
begin
  FLock.Acquire;
  try
    Source:=GetOrCreateSourceLocked(ASourceID);
    Source.StreamName:=AStreamName;
    Source.Started:=True;
    FStats.SourceCount:=FSources.Count;
  finally
    FLock.Release;
  end;

  Evaluate;
end;

procedure TRtmpLiveSourceSwitcher.NoteSourceStopped(const ASourceID: string);
var
  NewSourceID: string;
  PreviousSourceID: string;
  Reason: string;
  Source: TRtmpSourceState;
begin
  PreviousSourceID:='';
  NewSourceID:='';
  Reason:='';

  FLock.Acquire;
  try
    Source:=FindSourceLocked(ASourceID);
    if Source <> nil then
    begin
      Source.Started:=False;
      Source.PendingBootstrap:=False;
      if SameText(FStats.ActiveSourceID, ASourceID) then
        EvaluateLocked(RtmpGetTickCount64, PreviousSourceID, NewSourceID, Reason);
    end;
  finally
    FLock.Release;
  end;

  if Assigned(FOnActiveSourceChanged) AND (Reason <> '') then
    FOnActiveSourceChanged(Self, PreviousSourceID, NewSourceID, Reason);
end;

function TRtmpLiveSourceSwitcher.IsBootstrapHeader(APacket: TRtmpPacket): Boolean;
begin
  Result:=(APacket <> nil) AND
    (APacket.HasFlag(pfIsMetadata) OR
     (APacket.HasFlag(pfIsCodecConfig) AND
       (APacket.HasFlag(pfIsAudio) OR APacket.HasFlag(pfIsVideo))));
end;

procedure TRtmpLiveSourceSwitcher.UpdateRetainedLocked(ASource: TRtmpSourceState;
  APacket: TRtmpPacket);
begin
  if (ASource = nil) OR (APacket = nil) then
    Exit;

  if APacket.HasFlag(pfIsMetadata) then
    ASource.ReplaceRetained(ASource.LatestMetadata, APacket);
  if APacket.HasFlag(pfIsAudio) AND APacket.HasFlag(pfIsCodecConfig) then
    ASource.ReplaceRetained(ASource.LatestAudioConfig, APacket);
  if APacket.HasFlag(pfIsVideo) AND APacket.HasFlag(pfIsCodecConfig) then
    ASource.ReplaceRetained(ASource.LatestVideoConfig, APacket);
  if APacket.HasFlag(pfIsVideo) then
    ASource.SawVideo:=True;
end;

function TRtmpLiveSourceSwitcher.IsSourceEligibleLocked(ASource: TRtmpSourceState;
  ANow: TRtmpTick): Boolean;
begin
  Result:=(ASource <> nil) AND ASource.Started AND (ASource.LastPacketTick <> 0);
  if NOT Result then
    Exit;

  if (FIdleTimeoutMS > 0) AND (ANow > ASource.LastPacketTick) then
    Result:=(ANow - ASource.LastPacketTick) <= UInt64(FIdleTimeoutMS);
end;

function TRtmpLiveSourceSwitcher.SelectBestSourceLocked(
  ANow: TRtmpTick): TRtmpSourceState;
var
  Candidate: TRtmpSourceState;
  I: Integer;
begin
  Result:=nil;

  if FForcedSourceID <> '' then
  begin
    Candidate:=FindSourceLocked(FForcedSourceID);
    if IsSourceEligibleLocked(Candidate, ANow) then
      Exit(Candidate);
  end;

  for I:=0 to FSources.Count - 1 do
  begin
    Candidate:=TRtmpSourceState(FSources[I]);
    if NOT IsSourceEligibleLocked(Candidate, ANow) then
      Continue;
    if (Result = nil) OR (Candidate.Priority < Result.Priority) then
      Result:=Candidate;
  end;
end;

procedure TRtmpLiveSourceSwitcher.ActivateSourceLocked(ANewSource: TRtmpSourceState);
begin
  if ANewSource <> nil then
  begin
    ANewSource.PendingBootstrap:=True;
    ANewSource.SegmentInputBase:=0;
    if FStats.OutputPackets > 0 then
      ANewSource.SegmentOutputBase:=FStats.LastOutputTimestamp + 1
    else
      ANewSource.SegmentOutputBase:=0;
    FStats.ActiveSourceID:=ANewSource.SourceID;
  end
  else
    FStats.ActiveSourceID:='';
end;

procedure TRtmpLiveSourceSwitcher.EvaluateLocked(ANow: TRtmpTick;
  out APreviousSourceID, ANewSourceID, AReason: string);
var
  ActiveSource: TRtmpSourceState;
  BestSource: TRtmpSourceState;
begin
  APreviousSourceID:='';
  ANewSourceID:='';
  AReason:='';

  ActiveSource:=FindSourceLocked(FStats.ActiveSourceID);
  BestSource:=SelectBestSourceLocked(ANow);

  if (ActiveSource = BestSource) then
    Exit;

  APreviousSourceID:=FStats.ActiveSourceID;
  if BestSource <> nil then
    ANewSourceID:=BestSource.SourceID
  else
    ANewSourceID:='';

  if (FForcedSourceID <> '') AND (ANewSourceID <> '') AND
    SameText(FForcedSourceID, ANewSourceID) then
  begin
    if APreviousSourceID <> '' then
      AReason:='manual'
    else
      AReason:='activate';
  end
  else if (ActiveSource <> nil) AND (NOT IsSourceEligibleLocked(ActiveSource, ANow)) then
  begin
    if ActiveSource.Started then
      AReason:='idle-timeout'
    else
      AReason:='stopped';
  end
  else if (ActiveSource <> nil) AND (BestSource <> nil) AND
    (BestSource.Priority < ActiveSource.Priority) then
    AReason:='priority'
  else if (BestSource <> nil) then
    AReason:='activate'
  else
    AReason:='unavailable';

  ActivateSourceLocked(BestSource);
  if APreviousSourceID <> ANewSourceID then
  begin
    Inc(FStats.SwitchCount);
    if AReason = 'manual' then
      Inc(FStats.ManualSwitchCount)
    else if (AReason = 'idle-timeout') OR (AReason = 'stopped') OR
      (AReason = 'unavailable') then
      Inc(FStats.FailoverSwitchCount);
    if AReason = 'idle-timeout' then
      Inc(FStats.IdleTimeoutCount);
  end
  else
    AReason:='';
end;

procedure TRtmpLiveSourceSwitcher.Evaluate;
var
  NewSourceID: string;
  PreviousSourceID: string;
  Reason: string;
begin
  PreviousSourceID:='';
  NewSourceID:='';
  Reason:='';

  FLock.Acquire;
  try
    EvaluateLocked(RtmpGetTickCount64, PreviousSourceID, NewSourceID, Reason);
  finally
    FLock.Release;
  end;

  if Assigned(FOnActiveSourceChanged) AND (Reason <> '') then
    FOnActiveSourceChanged(Self, PreviousSourceID, NewSourceID, Reason);
end;

procedure TRtmpLiveSourceSwitcher.ForceActiveSource(const ASourceID: string);
begin
  FLock.Acquire;
  try
    FForcedSourceID:=ASourceID;
  finally
    FLock.Release;
  end;
  Evaluate;
end;

procedure TRtmpLiveSourceSwitcher.ClearForcedSource;
begin
  FLock.Acquire;
  try
    FForcedSourceID:='';
  finally
    FLock.Release;
  end;
  Evaluate;
end;

function TRtmpLiveSourceSwitcher.MapOutputTimestampLocked(
  ASource: TRtmpSourceState; APacket: TRtmpPacket): UInt32;
var
  RelativeTimestamp: UInt32;
begin
  if ASource.SegmentInputBase > APacket.Timestamp then
    RelativeTimestamp:=0
  else
    RelativeTimestamp:=APacket.Timestamp - ASource.SegmentInputBase;

  Result:=ASource.SegmentOutputBase + RelativeTimestamp;
  if Result < FStats.LastOutputTimestamp then
    Result:=FStats.LastOutputTimestamp;
end;

function TRtmpLiveSourceSwitcher.BuildOutputPacket(ASource: TRtmpSourceState;
  APacket: TRtmpPacket; AOutputTimestamp: UInt32): TRtmpPacket;
begin
  Result:=TRtmpPacket.Create(APacket.MessageType, AOutputTimestamp, 0,
    APacket.MessageStreamID, APacket.ChunkStreamID, APacket.Payload,
    APacket.Flags, FStats.OutputPackets + 1, RtmpGetTickCount64);
end;

procedure TRtmpLiveSourceSwitcher.PushBootstrapHeadersLocked(
  ASource: TRtmpSourceState);
var
  HeaderPacket: TRtmpPacket;
  OutputPacket: TRtmpPacket;
begin
  if FOutputBuffer = nil then
    Exit;

  HeaderPacket:=ASource.LatestMetadata;
  if HeaderPacket <> nil then
  begin
    OutputPacket:=BuildOutputPacket(ASource, HeaderPacket, ASource.SegmentOutputBase);
    try
      FOutputBuffer.Push(OutputPacket);
      Inc(FStats.OutputPackets);
      Inc(FStats.OutputBytes, UInt64(HeaderPacket.PayloadSize));
      FStats.LastOutputTimestamp:=ASource.SegmentOutputBase;
      EmitOutputPacket(ASource.SourceID, OutputPacket);
    except
      OutputPacket.Free;
      raise;
    end;
  end;

  HeaderPacket:=ASource.LatestAudioConfig;
  if HeaderPacket <> nil then
  begin
    OutputPacket:=BuildOutputPacket(ASource, HeaderPacket, ASource.SegmentOutputBase);
    try
      FOutputBuffer.Push(OutputPacket);
      Inc(FStats.OutputPackets);
      Inc(FStats.OutputBytes, UInt64(HeaderPacket.PayloadSize));
      FStats.LastOutputTimestamp:=ASource.SegmentOutputBase;
      EmitOutputPacket(ASource.SourceID, OutputPacket);
    except
      OutputPacket.Free;
      raise;
    end;
  end;

  HeaderPacket:=ASource.LatestVideoConfig;
  if HeaderPacket <> nil then
  begin
    OutputPacket:=BuildOutputPacket(ASource, HeaderPacket, ASource.SegmentOutputBase);
    try
      FOutputBuffer.Push(OutputPacket);
      Inc(FStats.OutputPackets);
      Inc(FStats.OutputBytes, UInt64(HeaderPacket.PayloadSize));
      FStats.LastOutputTimestamp:=ASource.SegmentOutputBase;
      EmitOutputPacket(ASource.SourceID, OutputPacket);
    except
      OutputPacket.Free;
      raise;
    end;
  end;
end;

procedure TRtmpLiveSourceSwitcher.RoutePacketLocked(ASource: TRtmpSourceState;
  APacket: TRtmpPacket);
var
  OutputPacket: TRtmpPacket;
  OutputTimestamp: UInt32;
  RequiresKeyframe: Boolean;
begin
  if (ASource = nil) OR (APacket = nil) OR (FOutputBuffer = nil) then
    Exit;

  if ASource.PendingBootstrap then
  begin
    if IsBootstrapHeader(APacket) then
      Exit;

    RequiresKeyframe:=ASource.SawVideo;
    if RequiresKeyframe AND
      NOT (APacket.HasFlag(pfIsVideo) AND APacket.HasFlag(pfIsKeyframe)) then
      Exit;

    ASource.SegmentInputBase:=APacket.Timestamp;
    if FStats.OutputPackets > 0 then
      ASource.SegmentOutputBase:=FStats.LastOutputTimestamp + 1
    else
      ASource.SegmentOutputBase:=0;
    PushBootstrapHeadersLocked(ASource);
    ASource.PendingBootstrap:=False;
  end;

  OutputTimestamp:=MapOutputTimestampLocked(ASource, APacket);
  OutputPacket:=BuildOutputPacket(ASource, APacket, OutputTimestamp);
  try
    FOutputBuffer.Push(OutputPacket);
    Inc(FStats.OutputPackets);
    Inc(FStats.OutputBytes, UInt64(APacket.PayloadSize));
    FStats.LastOutputTimestamp:=OutputTimestamp;
    EmitOutputPacket(ASource.SourceID, OutputPacket);
  except
    OutputPacket.Free;
    raise;
  end;
end;

procedure TRtmpLiveSourceSwitcher.NoteSourcePacket(const ASourceID: string;
  APacket: TRtmpPacket);
var
  NewSourceID: string;
  PreviousSourceID: string;
  Reason: string;
  Source: TRtmpSourceState;
begin
  if APacket = nil then
    Exit;

  PreviousSourceID:='';
  NewSourceID:='';
  Reason:='';

  FLock.Acquire;
  try
    Source:=GetOrCreateSourceLocked(ASourceID);
    Source.Started:=True;
    Source.LastPacketTick:=RtmpGetTickCount64;
    UpdateRetainedLocked(Source, APacket);
    EvaluateLocked(Source.LastPacketTick, PreviousSourceID, NewSourceID, Reason);
    if SameText(FStats.ActiveSourceID, Source.SourceID) then
      RoutePacketLocked(Source, APacket);
    FStats.SourceCount:=FSources.Count;
  finally
    FLock.Release;
  end;

  if Assigned(FOnActiveSourceChanged) AND (Reason <> '') then
    FOnActiveSourceChanged(Self, PreviousSourceID, NewSourceID, Reason);
end;

function TRtmpLiveSourceSwitcher.GetActiveSourceID: string;
begin
  FLock.Acquire;
  try
    Result:=FStats.ActiveSourceID;
  finally
    FLock.Release;
  end;
end;

function TRtmpLiveSourceSwitcher.GetSourceStreamName(
  const ASourceID: string): string;
var
  Source: TRtmpSourceState;
begin
  FLock.Acquire;
  try
    Source:=FindSourceLocked(ASourceID);
    if Source <> nil then
      Result:=Source.StreamName
    else
      Result:='';
  finally
    FLock.Release;
  end;
end;

function TRtmpLiveSourceSwitcher.GetActiveStreamName: string;
begin
  Result:=GetSourceStreamName(ActiveSourceID);
end;

function TRtmpLiveSourceSwitcher.ActiveStreamName: string;
begin
  Result:=GetActiveStreamName;
end;

function TRtmpLiveSourceSwitcher.GetStats: TRtmpLiveSourceSwitcherStats;
begin
  FLock.Acquire;
  try
    Result:=FStats;
    Result.SourceCount:=FSources.Count;
  finally
    FLock.Release;
  end;
end;

end.

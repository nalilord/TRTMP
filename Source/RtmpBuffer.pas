unit RtmpBuffer;

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
  RtmpPacket,
  RtmpTypes;

type
  TRtmpCircularBuffer = class
  private
    FItems: TObjectList;
    FLock: TCriticalSection;
    FLatestAudioConfig: TRtmpPacket;
    FLatestKeyframe: TRtmpPacket;
    FLatestMetadata: TRtmpPacket;
    FLatestVideoConfig: TRtmpPacket;
    FStats: TRtmpBufferStats;
    FMaxPackets: Integer;
    FMaxBytes: UInt64;
    FMaxDurationMS: UInt32;
    FCurrentBytes: UInt64;
    function GetCount: Integer;
    function GetBootstrapSequenceNoLocked(AFallbackSequenceNo: UInt64): UInt64;
    function GetRetainedBytesLocked: UInt64;
    function GetRetainedPacketCountLocked: Integer;
    function HasPacketWithSequenceNoLocked(ASequenceNo: UInt64): Boolean;
    procedure PushLocked(APacket: TRtmpPacket);
    procedure ReplacePinnedPacket(var ATarget: TRtmpPacket; ASource: TRtmpPacket);
    procedure SetMaxBytes(AValue: UInt64);
    procedure SetMaxDurationMS(AValue: UInt32);
    procedure SetMaxPackets(AValue: Integer);
    function SnapshotStatsLocked: TRtmpBufferStats;
    procedure TrimToBudget;
  public
    constructor Create(AMaxPackets: Integer; AMaxBytes: UInt64;
      AMaxDurationMS: UInt32 = 0);
    destructor Destroy; override;

    procedure Clear;
    function CurrentBytes: UInt64;
    function GetBootstrapSequenceNo(AFallbackSequenceNo: UInt64): UInt64;
    function GetCodecHeaders: TRtmpPacketArray;
    function GetCodecHeadersSnapshot: TRtmpPacketArray;
    function GetLatestKeyframe: TRtmpPacket;
    function GetSinceSequence(ASequenceNo: UInt64): TRtmpPacketArray;
    function GetSinceSequenceSnapshot(ASequenceNo: UInt64): TRtmpPacketArray;
    function GetStats: TRtmpBufferStats;
    function GetSnapshot: TRtmpPacketArray;
    function PeekLatest: TRtmpPacket;
    procedure Push(APacket: TRtmpPacket);
    function PushAndGetStats(APacket: TRtmpPacket; out ABefore,
      AAfter: TRtmpBufferStats): Boolean;

    property Count: Integer read GetCount;
    property MaxPackets: Integer read FMaxPackets write SetMaxPackets;
    property MaxBytes: UInt64 read FMaxBytes write SetMaxBytes;
    property MaxDurationMS: UInt32 read FMaxDurationMS write SetMaxDurationMS;
  end;

implementation

function ClonePacketArray(const APackets: TRtmpPacketArray): TRtmpPacketArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(APackets));
  for I := 0 to High(APackets) do
    if APackets[I] <> nil then
      Result[I] := APackets[I].CloneShallow
    else
      Result[I] := nil;
end;

constructor TRtmpCircularBuffer.Create(AMaxPackets: Integer; AMaxBytes: UInt64;
  AMaxDurationMS: UInt32);
begin
  inherited Create;
  FItems := TObjectList.Create(True);
  FLock := TCriticalSection.Create;
  FMaxPackets := AMaxPackets;
  FMaxBytes := AMaxBytes;
  FMaxDurationMS := AMaxDurationMS;
  FCurrentBytes := 0;
  FStats := Default(TRtmpBufferStats);
  FStats.MaxPackets := AMaxPackets;
  FStats.MaxBytes := AMaxBytes;
  FStats.MaxDurationMS := AMaxDurationMS;
  FLatestMetadata := nil;
  FLatestAudioConfig := nil;
  FLatestVideoConfig := nil;
  FLatestKeyframe := nil;
end;

destructor TRtmpCircularBuffer.Destroy;
begin
  Clear;
  FLock.Free;
  FItems.Free;
  inherited Destroy;
end;

procedure TRtmpCircularBuffer.Clear;
begin
  FLock.Acquire;
  try
    FItems.Clear;
    FCurrentBytes := 0;
    FStats := Default(TRtmpBufferStats);
    FStats.MaxPackets := FMaxPackets;
    FStats.MaxBytes := FMaxBytes;
    FStats.MaxDurationMS := FMaxDurationMS;
    FreeAndNil(FLatestMetadata);
    FreeAndNil(FLatestAudioConfig);
    FreeAndNil(FLatestVideoConfig);
    FreeAndNil(FLatestKeyframe);
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.CurrentBytes: UInt64;
begin
  FLock.Acquire;
  try
    Result := FCurrentBytes;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.GetBootstrapSequenceNo(
  AFallbackSequenceNo: UInt64): UInt64;
begin
  FLock.Acquire;
  try
    Result := GetBootstrapSequenceNoLocked(AFallbackSequenceNo);
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.GetBootstrapSequenceNoLocked(
  AFallbackSequenceNo: UInt64): UInt64;
begin
  if FLatestKeyframe <> nil then
    Result := FLatestKeyframe.SequenceNo
  else
    Result := AFallbackSequenceNo;
end;

function TRtmpCircularBuffer.GetCodecHeaders: TRtmpPacketArray;
var
  CountFound: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    CountFound := 0;
    if FLatestMetadata <> nil then
      Inc(CountFound);
    if FLatestAudioConfig <> nil then
      Inc(CountFound);
    if FLatestVideoConfig <> nil then
      Inc(CountFound);

    SetLength(Result, CountFound);
    CountFound := 0;
    if FLatestMetadata <> nil then
    begin
      Result[CountFound] := FLatestMetadata;
      Inc(CountFound);
    end;
    if FLatestAudioConfig <> nil then
    begin
      Result[CountFound] := FLatestAudioConfig;
      Inc(CountFound);
    end;
    if FLatestVideoConfig <> nil then
      Result[CountFound] := FLatestVideoConfig;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.GetCodecHeadersSnapshot: TRtmpPacketArray;
var
  CountFound: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    CountFound := 0;
    if FLatestMetadata <> nil then
      Inc(CountFound);
    if FLatestAudioConfig <> nil then
      Inc(CountFound);
    if FLatestVideoConfig <> nil then
      Inc(CountFound);

    SetLength(Result, CountFound);
    CountFound := 0;
    if FLatestMetadata <> nil then
    begin
      Result[CountFound] := FLatestMetadata.CloneShallow;
      Inc(CountFound);
    end;
    if FLatestAudioConfig <> nil then
    begin
      Result[CountFound] := FLatestAudioConfig.CloneShallow;
      Inc(CountFound);
    end;
    if FLatestVideoConfig <> nil then
      Result[CountFound] := FLatestVideoConfig.CloneShallow;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.GetCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FItems.Count;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.GetRetainedBytesLocked: UInt64;
begin
  Result := 0;
  if FLatestMetadata <> nil then
    Inc(Result, UInt64(FLatestMetadata.PayloadSize));
  if FLatestAudioConfig <> nil then
    Inc(Result, UInt64(FLatestAudioConfig.PayloadSize));
  if FLatestVideoConfig <> nil then
    Inc(Result, UInt64(FLatestVideoConfig.PayloadSize));
  if FLatestKeyframe <> nil then
    Inc(Result, UInt64(FLatestKeyframe.PayloadSize));
end;

function TRtmpCircularBuffer.GetRetainedPacketCountLocked: Integer;
begin
  Result := 0;
  if FLatestMetadata <> nil then
    Inc(Result);
  if FLatestAudioConfig <> nil then
    Inc(Result);
  if FLatestVideoConfig <> nil then
    Inc(Result);
  if FLatestKeyframe <> nil then
    Inc(Result);
end;

function TRtmpCircularBuffer.GetLatestKeyframe: TRtmpPacket;
begin
  FLock.Acquire;
  try
    Result := FLatestKeyframe;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.GetStats: TRtmpBufferStats;
begin
  FLock.Acquire;
  try
    Result := SnapshotStatsLocked;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.GetSinceSequence(ASequenceNo: UInt64): TRtmpPacketArray;
var
  I: Integer;
  CountFound: Integer;
  IncludeRetainedKeyframe: Boolean;
begin
  Result := nil;
  CountFound := 0;

  FLock.Acquire;
  try
    IncludeRetainedKeyframe := (FLatestKeyframe <> nil) and
      (FLatestKeyframe.SequenceNo >= ASequenceNo) and
      (not HasPacketWithSequenceNoLocked(FLatestKeyframe.SequenceNo));
    if IncludeRetainedKeyframe then
      Inc(CountFound);

    for I := 0 to FItems.Count - 1 do
      if TRtmpPacket(FItems[I]).SequenceNo >= ASequenceNo then
        Inc(CountFound);

    SetLength(Result, CountFound);
    CountFound := 0;

    if IncludeRetainedKeyframe then
    begin
      Result[CountFound] := FLatestKeyframe;
      Inc(CountFound);
    end;

    for I := 0 to FItems.Count - 1 do
      if TRtmpPacket(FItems[I]).SequenceNo >= ASequenceNo then
      begin
        Result[CountFound] := TRtmpPacket(FItems[I]);
        Inc(CountFound);
      end;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.GetSinceSequenceSnapshot(
  ASequenceNo: UInt64): TRtmpPacketArray;
var
  I: Integer;
  CountFound: Integer;
  IncludeRetainedKeyframe: Boolean;
begin
  Result := nil;
  CountFound := 0;

  FLock.Acquire;
  try
    IncludeRetainedKeyframe := (FLatestKeyframe <> nil) and
      (FLatestKeyframe.SequenceNo >= ASequenceNo) and
      (not HasPacketWithSequenceNoLocked(FLatestKeyframe.SequenceNo));
    if IncludeRetainedKeyframe then
      Inc(CountFound);

    for I := 0 to FItems.Count - 1 do
      if TRtmpPacket(FItems[I]).SequenceNo >= ASequenceNo then
        Inc(CountFound);

    SetLength(Result, CountFound);
    CountFound := 0;

    if IncludeRetainedKeyframe then
    begin
      Result[CountFound] := FLatestKeyframe.CloneShallow;
      Inc(CountFound);
    end;

    for I := 0 to FItems.Count - 1 do
      if TRtmpPacket(FItems[I]).SequenceNo >= ASequenceNo then
      begin
        Result[CountFound] := TRtmpPacket(FItems[I]).CloneShallow;
        Inc(CountFound);
      end;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.HasPacketWithSequenceNoLocked(ASequenceNo: UInt64): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FItems.Count - 1 do
    if TRtmpPacket(FItems[I]).SequenceNo = ASequenceNo then
      Exit(True);
end;

function TRtmpCircularBuffer.GetSnapshot: TRtmpPacketArray;
var
  I: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    SetLength(Result, FItems.Count);
    for I := 0 to FItems.Count - 1 do
      Result[I] := TRtmpPacket(FItems[I]);
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.PeekLatest: TRtmpPacket;
begin
  Result := nil;

  FLock.Acquire;
  try
    if FItems.Count > 0 then
      Result := TRtmpPacket(FItems[FItems.Count - 1]);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpCircularBuffer.Push(APacket: TRtmpPacket);
begin
  if APacket = nil then
    Exit;

  FLock.Acquire;
  try
    PushLocked(APacket);
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.PushAndGetStats(APacket: TRtmpPacket; out ABefore,
  AAfter: TRtmpBufferStats): Boolean;
begin
  ABefore := Default(TRtmpBufferStats);
  AAfter := Default(TRtmpBufferStats);
  Result := False;
  if APacket = nil then
    Exit;

  FLock.Acquire;
  try
    ABefore := SnapshotStatsLocked;
    PushLocked(APacket);
    AAfter := SnapshotStatsLocked;
    Result := True;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpCircularBuffer.PushLocked(APacket: TRtmpPacket);
begin
  if APacket.HasFlag(pfIsMetadata) then
    ReplacePinnedPacket(FLatestMetadata, APacket);
  if APacket.HasFlag(pfIsAudio) and APacket.HasFlag(pfIsCodecConfig) then
    ReplacePinnedPacket(FLatestAudioConfig, APacket);
  if APacket.HasFlag(pfIsVideo) and APacket.HasFlag(pfIsCodecConfig) then
    ReplacePinnedPacket(FLatestVideoConfig, APacket);
  if APacket.HasFlag(pfIsKeyframe) and not APacket.HasFlag(pfIsCodecConfig) then
    ReplacePinnedPacket(FLatestKeyframe, APacket);

  FItems.Add(APacket);
  Inc(FCurrentBytes, UInt64(APacket.PayloadSize));
  Inc(FStats.TotalPacketsPushed);
  Inc(FStats.TotalBytesPushed, UInt64(APacket.PayloadSize));
  TrimToBudget;
end;

procedure TRtmpCircularBuffer.ReplacePinnedPacket(var ATarget: TRtmpPacket;
  ASource: TRtmpPacket);
begin
  FreeAndNil(ATarget);
  if ASource <> nil then
    ATarget := ASource.CloneShallow;
end;

procedure TRtmpCircularBuffer.SetMaxBytes(AValue: UInt64);
begin
  FLock.Acquire;
  try
    FMaxBytes := AValue;
    FStats.MaxBytes := AValue;
    TrimToBudget;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpCircularBuffer.SetMaxDurationMS(AValue: UInt32);
begin
  FLock.Acquire;
  try
    FMaxDurationMS := AValue;
    FStats.MaxDurationMS := AValue;
    TrimToBudget;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpCircularBuffer.SetMaxPackets(AValue: Integer);
begin
  FLock.Acquire;
  try
    FMaxPackets := AValue;
    FStats.MaxPackets := AValue;
    TrimToBudget;
  finally
    FLock.Release;
  end;
end;

function TRtmpCircularBuffer.SnapshotStatsLocked: TRtmpBufferStats;
begin
  Result := FStats;
  Result.PacketCount := FItems.Count;
  Result.ByteCount := FCurrentBytes;
  Result.MaxPackets := FMaxPackets;
  Result.MaxBytes := FMaxBytes;
  Result.MaxDurationMS := FMaxDurationMS;
  if FItems.Count > 1 then
    Result.WindowDurationMS := TRtmpPacket(FItems[FItems.Count - 1]).Timestamp -
      TRtmpPacket(FItems[0]).Timestamp
  else
    Result.WindowDurationMS := 0;
  Result.HasMetadata := FLatestMetadata <> nil;
  Result.HasAudioConfig := FLatestAudioConfig <> nil;
  Result.HasVideoConfig := FLatestVideoConfig <> nil;
  Result.HasKeyframe := FLatestKeyframe <> nil;
  Result.RetainedPackets := GetRetainedPacketCountLocked;
  Result.RetainedBytes := GetRetainedBytesLocked;
end;

procedure TRtmpCircularBuffer.TrimToBudget;
var
  DueToAgeLimit: Boolean;
  DueToByteLimit: Boolean;
  OldPacket: TRtmpPacket;
  TrimmedByBytes: Boolean;
  TrimmedByPackets: Boolean;
  TrimmedByAge: Boolean;
  DueToPacketLimit: Boolean;
  LatestPacket: TRtmpPacket;
  WindowDurationMS: UInt32;
begin
  TrimmedByBytes := False;
  TrimmedByPackets := False;
  TrimmedByAge := False;
  while ((FMaxPackets > 0) and (FItems.Count > FMaxPackets)) or
    ((FMaxBytes > 0) and (FCurrentBytes > FMaxBytes)) or
    ((FMaxDurationMS > 0) and (FItems.Count > 1)) do
  begin
    if FItems.Count = 0 then
      Break;

    DueToAgeLimit := False;
    DueToPacketLimit := (FMaxPackets > 0) and (FItems.Count > FMaxPackets);
    DueToByteLimit := (not DueToPacketLimit) and (FMaxBytes > 0) and
      (FCurrentBytes > FMaxBytes);

    if (not DueToPacketLimit) and (not DueToByteLimit) and
      (FMaxDurationMS > 0) and (FItems.Count > 1) then
    begin
      LatestPacket := TRtmpPacket(FItems[FItems.Count - 1]);
      OldPacket := TRtmpPacket(FItems[0]);
      if (LatestPacket <> nil) and (OldPacket <> nil) and
        (LatestPacket.Timestamp >= OldPacket.Timestamp) then
      begin
        WindowDurationMS := LatestPacket.Timestamp - OldPacket.Timestamp;
        DueToAgeLimit := WindowDurationMS > FMaxDurationMS;
      end;
    end;

    if DueToPacketLimit then
      TrimmedByPackets := True
    else if DueToAgeLimit then
      TrimmedByAge := True
    else if DueToByteLimit then
      TrimmedByBytes := True;

    if not (DueToPacketLimit or DueToAgeLimit or DueToByteLimit) then
      Break;

    OldPacket := TRtmpPacket(FItems[0]);
    if OldPacket <> nil then
    begin
      Dec(FCurrentBytes, UInt64(OldPacket.PayloadSize));
      Inc(FStats.EvictedPackets);
      Inc(FStats.EvictedBytes, UInt64(OldPacket.PayloadSize));
      if DueToPacketLimit then
        Inc(FStats.EvictedByPacketLimit)
      else if DueToAgeLimit then
        Inc(FStats.EvictedByAgeLimit)
      else if DueToByteLimit then
        Inc(FStats.EvictedByByteLimit);
    end;
    FItems.Delete(0);
  end;

  if TrimmedByPackets then
    Inc(FStats.TrimEventsByPackets);
  if TrimmedByBytes then
    Inc(FStats.TrimEventsByBytes);
  if TrimmedByAge then
    Inc(FStats.TrimEventsByAge);
end;

end.

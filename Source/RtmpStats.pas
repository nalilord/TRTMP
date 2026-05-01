unit RtmpStats;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SyncObjs,
  RtmpCompat,
  RtmpPacket,
  RtmpTypes;

type
  TRtmpServerStatsTracker = class
  private
    FFirstPacketArrivalTick: TRtmpTick;
    FFirstPacketTimestamp: UInt32;
    FHasFirstPacket: Boolean;
    FLock: TCriticalSection;
    FLastBitrateBytes: UInt64;
    FLastBitrateTick: TRtmpTick;
    FLastPacketArrivalTick: TRtmpTick;
    FLastPacketTimestamp: UInt32;
    FHasLastPacket: Boolean;
    FStartedAt: TRtmpTick;
    FStats: TRtmpServerStats;
    procedure ResetStreamTimingLocked;
    procedure RecalculateBitrate;
  public
    constructor Create;
    destructor Destroy; override;

    procedure NoteError;
    procedure NoteLog(ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
    procedure NotePacket(const APacket: TRtmpPacket);
    procedure NoteDroppedPacket;
    procedure NotePublishStarted;
    procedure NotePublishStopped;
    procedure NoteSessionRejected;
    procedure NoteSessionStarted;
    procedure NoteSessionStopped;
    procedure Reset;
    function Snapshot: TRtmpServerStats;
  end;

implementation

procedure TRtmpServerStatsTracker.ResetStreamTimingLocked;
begin
  FHasFirstPacket := False;
  FHasLastPacket := False;
  FFirstPacketArrivalTick := 0;
  FFirstPacketTimestamp := 0;
  FLastPacketArrivalTick := 0;
  FLastPacketTimestamp := 0;
  FStats.LastPacketIdleMS := 0;
  FStats.TimelineLagMS := 0;
  FStats.MaxTimelineLagMS := 0;
end;

constructor TRtmpServerStatsTracker.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  Reset;
end;

destructor TRtmpServerStatsTracker.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TRtmpServerStatsTracker.NoteDroppedPacket;
begin
  FLock.Acquire;
  try
    Inc(FStats.DroppedPackets);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServerStatsTracker.NoteError;
begin
  NoteLog(llError, 'server', '');
end;

procedure TRtmpServerStatsTracker.NoteLog(ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  FLock.Acquire;
  try
    case ALevel of
      llWarning:
        begin
          Inc(FStats.Warnings);
          FStats.LastWarningCategory := ACategory;
          FStats.LastWarningMessage := AMessage;
        end;
      llError:
        begin
          Inc(FStats.Errors);
          FStats.LastErrorCategory := ACategory;
          FStats.LastErrorMessage := AMessage;

          if (ACategory = 'protocol') or (ACategory = 'handshake') then
            Inc(FStats.ProtocolErrors)
          else if (ACategory = 'accept') or (ACategory = 'socket') then
            Inc(FStats.TransportErrors)
          else
            Inc(FStats.SessionErrors);
        end;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServerStatsTracker.NotePacket(const APacket: TRtmpPacket);
var
  MediaElapsedMS: Int64;
  TimelineLagMS: Int64;
  WallElapsedMS: Int64;
begin
  if APacket = nil then
    Exit;

  FLock.Acquire;
  try
    if not FHasFirstPacket then
    begin
      FFirstPacketArrivalTick := APacket.ArrivalTick;
      FFirstPacketTimestamp := APacket.Timestamp;
      FHasFirstPacket := True;
    end;

    Inc(FStats.PacketsReceived);
    Inc(FStats.BytesReceived, UInt64(APacket.PayloadSize));
    FLastPacketArrivalTick := APacket.ArrivalTick;
    FLastPacketTimestamp := APacket.Timestamp;
    FHasLastPacket := True;

    if FHasFirstPacket then
    begin
      WallElapsedMS := Int64(FLastPacketArrivalTick) - Int64(FFirstPacketArrivalTick);
      MediaElapsedMS := Int64(FLastPacketTimestamp) - Int64(FFirstPacketTimestamp);
      TimelineLagMS := WallElapsedMS - MediaElapsedMS;

      if TimelineLagMS > High(Integer) then
        TimelineLagMS := High(Integer)
      else if TimelineLagMS < Low(Integer) then
        TimelineLagMS := Low(Integer);

      if Integer(TimelineLagMS) > FStats.MaxTimelineLagMS then
        FStats.MaxTimelineLagMS := Integer(TimelineLagMS);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServerStatsTracker.NoteSessionStarted;
begin
  FLock.Acquire;
  try
    Inc(FStats.ActiveSessions);
    Inc(FStats.TotalSessions);
    if FStats.ActiveSessions > FStats.PeakActiveSessions then
      FStats.PeakActiveSessions := FStats.ActiveSessions;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServerStatsTracker.NotePublishStarted;
begin
  FLock.Acquire;
  try
    Inc(FStats.ActivePublishes);
    if FStats.ActivePublishes > FStats.PeakActivePublishes then
      FStats.PeakActivePublishes := FStats.ActivePublishes;
    ResetStreamTimingLocked;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServerStatsTracker.NotePublishStopped;
begin
  FLock.Acquire;
  try
    if FStats.ActivePublishes > 0 then
      Dec(FStats.ActivePublishes);
    ResetStreamTimingLocked;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServerStatsTracker.NoteSessionRejected;
begin
  FLock.Acquire;
  try
    Inc(FStats.RejectedSessions);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServerStatsTracker.NoteSessionStopped;
begin
  FLock.Acquire;
  try
    if FStats.ActiveSessions > 0 then
      Dec(FStats.ActiveSessions);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpServerStatsTracker.RecalculateBitrate;
var
  DeltaBytes: UInt64;
  DeltaMS: UInt64;
  MediaElapsedMS: Int64;
  NowTick: UInt64;
  TimelineLagMS: Int64;
  UptimeMS: UInt64;
  WallElapsedMS: Int64;
begin
  NowTick := RtmpGetTickCount64;
  UptimeMS := NowTick - FStartedAt;
  if UptimeMS > 0 then
    FStats.AverageBitrate := (FStats.BytesReceived * 8.0 * 1000.0) / UptimeMS
  else
    FStats.AverageBitrate := 0.0;

  DeltaMS := NowTick - FLastBitrateTick;
  if DeltaMS > 0 then
  begin
    DeltaBytes := FStats.BytesReceived - FLastBitrateBytes;
    FStats.CurrentBitrate := (DeltaBytes * 8.0 * 1000.0) / DeltaMS;
    FLastBitrateTick := NowTick;
    FLastBitrateBytes := FStats.BytesReceived;
  end
  else
    FStats.CurrentBitrate := 0.0;

  if FHasLastPacket then
    FStats.LastPacketIdleMS := NowTick - FLastPacketArrivalTick
  else
    FStats.LastPacketIdleMS := 0;

  if FHasFirstPacket and FHasLastPacket then
  begin
    WallElapsedMS := Int64(FLastPacketArrivalTick) - Int64(FFirstPacketArrivalTick);
    MediaElapsedMS := Int64(FLastPacketTimestamp) - Int64(FFirstPacketTimestamp);
    TimelineLagMS := WallElapsedMS - MediaElapsedMS;

    if TimelineLagMS > High(Integer) then
      TimelineLagMS := High(Integer)
    else if TimelineLagMS < Low(Integer) then
      TimelineLagMS := Low(Integer);

    FStats.TimelineLagMS := Integer(TimelineLagMS);
    if FStats.TimelineLagMS > FStats.MaxTimelineLagMS then
      FStats.MaxTimelineLagMS := FStats.TimelineLagMS;
  end
  else
    FStats.TimelineLagMS := 0;
end;

procedure TRtmpServerStatsTracker.Reset;
begin
  FLock.Acquire;
  try
    FStats := Default(TRtmpServerStats);
    FStartedAt := RtmpGetTickCount64;
    FLastBitrateTick := FStartedAt;
    FLastBitrateBytes := 0;
    ResetStreamTimingLocked;
  finally
    FLock.Release;
  end;
end;

function TRtmpServerStatsTracker.Snapshot: TRtmpServerStats;
begin
  FLock.Acquire;
  try
    RecalculateBitrate;
    Result := FStats;
  finally
    FLock.Release;
  end;
end;

end.

program RtmpServerLatencyStatsSmoke;

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
  RtmpBuffer,
  RtmpClient,
  RtmpPacket,
  RtmpServer,
  RtmpServerSession,
  RtmpStats,
  RtmpTypes;

type
  TLatencyStatsSmokeApp = class
  private
    FClient: TRtmpClient;
    FNextSequenceNo: UInt64;
    FPublishStarted: Boolean;
    FServer: TRtmpServer;
    FSourceBuffer: TRtmpCircularBuffer;
    procedure AssertEqualInt(const AMessage: string; AExpected, AActual: Integer);
    procedure AssertTrue(const AMessage: string; ACondition: Boolean);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure PushPacket(AMessageType: TRtmpMessageType; ATimestamp: UInt32;
      AChunkStreamID: UInt32; const APayloadBytes: array of Byte;
      AFlags: TRtmpPacketFlags);
    procedure TestDeterministicTimelineStats;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

constructor TLatencyStatsSmokeApp.Create;
var
  ClientConfig: TRtmpClientConfig;
  ServerConfig: TRtmpServerConfig;
begin
  inherited Create;
  FClient := TRtmpClient.Create;
  FNextSequenceNo := 0;
  FPublishStarted := False;
  FServer := TRtmpServer.Create;
  FSourceBuffer := TRtmpCircularBuffer.Create(128, 4 * 1024 * 1024);

  ServerConfig := DefaultRtmpServerConfig;
  ServerConfig.BindAddress := '127.0.0.1';
  ServerConfig.Port := 1946;
  FServer.Config := ServerConfig;
  FServer.OnPublishStarted := HandlePublishStarted;

  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig := DefaultRtmpClientConfig;
  ClientConfig.TargetURL := 'rtmp://127.0.0.1:1946/live/test';
  ClientConfig.OutChunkSize := 4096;
  FClient.Config := ClientConfig;
end;

destructor TLatencyStatsSmokeApp.Destroy;
begin
  FClient.Free;
  FServer.Free;
  FSourceBuffer.Free;
  inherited Destroy;
end;

procedure TLatencyStatsSmokeApp.AssertTrue(const AMessage: string;
  ACondition: Boolean);
begin
  if not ACondition then
    raise Exception.Create(AMessage);
end;

procedure TLatencyStatsSmokeApp.AssertEqualInt(const AMessage: string;
  AExpected, AActual: Integer);
begin
  if AExpected <> AActual then
    raise Exception.CreateFmt('%s expected=%d actual=%d',
      [AMessage, AExpected, AActual]);
end;

procedure TLatencyStatsSmokeApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  FPublishStarted := True;
end;

procedure TLatencyStatsSmokeApp.PushPacket(AMessageType: TRtmpMessageType;
  ATimestamp: UInt32; AChunkStreamID: UInt32; const APayloadBytes: array of Byte;
  AFlags: TRtmpPacketFlags);
var
  Packet: TRtmpPacket;
begin
  Packet := TRtmpPacket.Create(AMessageType, ATimestamp, ATimestamp, 1,
    AChunkStreamID, TRtmpSharedPayload.Create(Bytes(APayloadBytes)), AFlags,
    FNextSequenceNo);
  Inc(FNextSequenceNo);
  FSourceBuffer.Push(Packet);
end;

procedure TLatencyStatsSmokeApp.TestDeterministicTimelineStats;
var
  Packet: TRtmpPacket;
  Stats: TRtmpServerStats;
  Tracker: TRtmpServerStatsTracker;
begin
  Tracker := TRtmpServerStatsTracker.Create;
  try
    Packet := TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$17, $01])), [pfIsVideo, pfIsKeyframe],
      1, 1000);
    try
      Tracker.NotePacket(Packet);
    finally
      Packet.Free;
    end;

    Packet := TRtmpPacket.Create(mtVideo, 40, 40, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$27, $01])), [pfIsVideo], 2, 1120);
    try
      Tracker.NotePacket(Packet);
    finally
      Packet.Free;
    end;

    Stats := Tracker.Snapshot;
    AssertEqualInt('deterministic lag after slow arrival', 80, Stats.TimelineLagMS);
    AssertEqualInt('deterministic max lag after slow arrival', 80, Stats.MaxTimelineLagMS);

    Packet := TRtmpPacket.Create(mtVideo, 120, 80, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$27, $01])), [pfIsVideo], 3, 1160);
    try
      Tracker.NotePacket(Packet);
    finally
      Packet.Free;
    end;

    Stats := Tracker.Snapshot;
    AssertEqualInt('deterministic lag after partial catch-up', 40, Stats.TimelineLagMS);
    AssertEqualInt('deterministic max lag retains peak', 80, Stats.MaxTimelineLagMS);

    Packet := TRtmpPacket.Create(mtVideo, 300, 180, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$27, $01])), [pfIsVideo], 4, 1200);
    try
      Tracker.NotePacket(Packet);
    finally
      Packet.Free;
    end;

    Stats := Tracker.Snapshot;
    AssertEqualInt('deterministic negative lag when media runs ahead',
      -100, Stats.TimelineLagMS);
    AssertEqualInt('deterministic max lag remains positive peak',
      80, Stats.MaxTimelineLagMS);

    Tracker.NotePublishStarted;
    Stats := Tracker.Snapshot;
    AssertEqualInt('deterministic lag reset on publish start', 0, Stats.TimelineLagMS);
    AssertEqualInt('deterministic max lag reset on publish start', 0, Stats.MaxTimelineLagMS);
  finally
    Tracker.Free;
  end;
end;

procedure TLatencyStatsSmokeApp.Run;
var
  Deadline: UInt64;
  Stats: TRtmpServerStats;
begin
  TestDeterministicTimelineStats;

  FServer.Start;
  try
    FClient.Start;
    try
      Deadline := GetTickCount64 + 4000;
      while GetTickCount64 < Deadline do
      begin
        if FPublishStarted then
          Break;
        Sleep(20);
      end;

      AssertTrue('latency smoke failed: publish did not start', FPublishStarted);

      PushPacket(mtDataAMF0, 0, 5, [$12, $00, $01, $02], [pfIsMetadata]);
      PushPacket(mtAudio, 0, 4, [$AF, $00, $12, $10],
        [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader]);
      PushPacket(mtVideo, 0, 6, [$17, $00, $00, $00, $00, $01, $64, $00, $1E],
        [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe]);

      PushPacket(mtVideo, 0, 6, [$17, $01, $00, $00, $00, $10, $11, $12, $13],
        [pfIsVideo, pfIsKeyframe]);
      Sleep(40);
      PushPacket(mtVideo, 40, 6, [$27, $01, $00, $00, $00, $14, $15, $16, $17],
        [pfIsVideo]);
      Sleep(40);
      PushPacket(mtVideo, 80, 6, [$27, $01, $00, $00, $00, $18, $19, $1A, $1B],
        [pfIsVideo]);
      Sleep(40);
      PushPacket(mtVideo, 120, 6, [$17, $01, $00, $00, $00, $1C, $1D, $1E, $1F],
        [pfIsVideo, pfIsKeyframe]);
      Sleep(80);

      Stats := FServer.GetStats;
    finally
      FClient.Stop;
    end;
  finally
    FServer.Stop;
  end;

  AssertTrue('latency smoke failed: expected packets on server',
    Stats.PacketsReceived >= 6);
  AssertTrue('latency smoke failed: expected recent packet idle time',
    Stats.LastPacketIdleMS <= 500);
  AssertTrue('latency smoke failed: expected bounded timeline lag',
    Abs(Stats.TimelineLagMS) <= 250);
  AssertTrue('latency smoke failed: expected max lag to track lag',
    Stats.MaxTimelineLagMS >= Stats.TimelineLagMS);

  WriteLn(Format(
    'Server latency stats smoke passed: idleMS=%d lagMS=%d maxLagMS=%d packets=%d',
    [Stats.LastPacketIdleMS, Stats.TimelineLagMS, Stats.MaxTimelineLagMS,
     Stats.PacketsReceived]));
end;

var
  App: TLatencyStatsSmokeApp;

begin
  App := TLatencyStatsSmokeApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

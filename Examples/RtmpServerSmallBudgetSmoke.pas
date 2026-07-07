program RtmpServerSmallBudgetSmoke;

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
  RtmpTypes;

type
  TSmallBudgetSmokeApp = class
  private
    FClient: TRtmpClient;
    FBufferWarningSeen: Boolean;
    FPacketsReceived: Integer;
    FPublishStarted: Boolean;
    FSequenceNo: UInt64;
    FServer: TRtmpServer;
    FSourceBuffer: TRtmpCircularBuffer;
    procedure AssertTrue(const AMessage: string; AValue: Boolean);
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure PushLivePackets;
    procedure SeedSourceBuffer;
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

constructor TSmallBudgetSmokeApp.Create;
var
  ClientConfig: TRtmpClientConfig;
  Config: TRtmpServerConfig;
begin
  inherited Create;
  FSourceBuffer := TRtmpCircularBuffer.Create(256, 2 * 1024 * 1024);
  FServer := TRtmpServer.Create;
  FClient := TRtmpClient.Create;
  FBufferWarningSeen := False;
  FPacketsReceived := 0;
  FPublishStarted := False;
  FSequenceNo := 0;

  Config := DefaultRtmpServerConfig;
  Config.BindAddress := '127.0.0.1';
  Config.Port := 1942;
  Config.BufferMaxPackets := 6;
  Config.BufferMaxBytes := 2048;
  Config.BufferMaxDurationMS := 120;
  FServer.Config := Config;
  FServer.LogSink.OnLog := HandleLog;
  FServer.OnData := HandleData;
  FServer.OnPublishStarted := HandlePublishStarted;

  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig := DefaultRtmpClientConfig;
  ClientConfig.TargetURL := 'rtmp://127.0.0.1:1942/live/test';
  ClientConfig.OutChunkSize := 4096;
  FClient.Config := ClientConfig;
end;

destructor TSmallBudgetSmokeApp.Destroy;
begin
  FClient.Free;
  FServer.Free;
  FSourceBuffer.Free;
  inherited Destroy;
end;

procedure TSmallBudgetSmokeApp.AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if not AValue then
    raise Exception.Create(AMessage);
end;

procedure TSmallBudgetSmokeApp.HandleData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
begin
  Inc(FPacketsReceived);
end;

procedure TSmallBudgetSmokeApp.HandleLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  if (ALevel = llWarning) and (ACategory = 'buffer') and
    (Pos('Buffer pressure evicted=', AMessage) > 0) then
    FBufferWarningSeen := True;
end;

procedure TSmallBudgetSmokeApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  FPublishStarted := True;
end;

procedure TSmallBudgetSmokeApp.SeedSourceBuffer;
var
  Packet: TRtmpPacket;
begin
  Packet := TRtmpPacket.Create(mtDataAMF0, 0, 0, 1, 5,
    TRtmpSharedPayload.Create(Bytes([$12, 0, 1, 2])), [pfIsMetadata], FSequenceNo);
  FSourceBuffer.Push(Packet);
  Inc(FSequenceNo);

  Packet := TRtmpPacket.Create(mtAudio, 0, 0, 1, 4,
    TRtmpSharedPayload.Create(Bytes([$AF, $00, $12, $10])),
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], FSequenceNo);
  FSourceBuffer.Push(Packet);
  Inc(FSequenceNo);

  Packet := TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $00, $00, $00, $00, $01, $64, $00, $1E])),
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], FSequenceNo);
  FSourceBuffer.Push(Packet);
  Inc(FSequenceNo);
end;

procedure TSmallBudgetSmokeApp.PushLivePackets;
var
  I: Integer;
  Packet: TRtmpPacket;
  Timestamp: UInt32;
begin
  for I := 0 to 29 do
  begin
    Timestamp := UInt32((I + 1) * 21);

    Packet := TRtmpPacket.Create(mtAudio, Timestamp, 21, 1, 4,
      TRtmpSharedPayload.Create(Bytes([$AF, $01, Byte(I and $FF), $55, $66, $77])),
      [pfIsAudio], FSequenceNo);
    FSourceBuffer.Push(Packet);
    Inc(FSequenceNo);

    if (I mod 10) = 0 then
      Packet := TRtmpPacket.Create(mtVideo, Timestamp, 21, 1, 6,
        TRtmpSharedPayload.Create(Bytes([$17, $01, 0, 0, 0, $09, Byte(I), $11, $12, $13])),
        [pfIsVideo, pfIsKeyframe], FSequenceNo)
    else
      Packet := TRtmpPacket.Create(mtVideo, Timestamp, 21, 1, 6,
        TRtmpSharedPayload.Create(Bytes([$27, $01, 0, 0, 0, $09, Byte(I), $21, $22, $23])),
        [pfIsVideo], FSequenceNo);
    FSourceBuffer.Push(Packet);
    Inc(FSequenceNo);

    Sleep(5);
  end;
end;

procedure TSmallBudgetSmokeApp.Run;
var
  Deadline: UInt64;
  Stats: TRtmpServerStats;
begin
  SeedSourceBuffer;
  FServer.Start;
  try
    FClient.Start;
    try
      Deadline := GetTickCount64 + 3000;
      while GetTickCount64 < Deadline do
      begin
        if FPublishStarted then
          Break;
        Sleep(20);
      end;
      AssertTrue('small-budget smoke: publish did not start in time', FPublishStarted);

      PushLivePackets;

      Deadline := GetTickCount64 + 5000;
      while GetTickCount64 < Deadline do
      begin
        if FPacketsReceived >= 40 then
          Break;
        Sleep(50);
      end;
    finally
      FClient.Stop;
    end;
  finally
    FServer.Stop;
  end;

  Stats := FServer.GetStats;
  if FPacketsReceived < 40 then
    raise Exception.CreateFmt(
      'small-budget smoke: expected >=40 packets actual=%d evicted=%d bufferPackets=%d windowMS=%d errors=%d',
      [FPacketsReceived, Stats.Buffer.EvictedPackets, Stats.Buffer.PacketCount,
       Stats.Buffer.WindowDurationMS, Stats.Errors]);
  AssertTrue('small-budget smoke: expected buffer evictions', Stats.Buffer.EvictedPackets > 0);
  AssertTrue('small-budget smoke: expected live buffer-pressure warning', FBufferWarningSeen);
  AssertTrue('small-budget smoke: expected buffer warning category',
    Stats.LastWarningCategory = 'buffer');
  AssertTrue('small-budget smoke: expected warning counter', Stats.Warnings > 0);
  AssertTrue('small-budget smoke: packet budget exceeded',
    Stats.Buffer.PacketCount <= Stats.Buffer.MaxPackets);
  AssertTrue('small-budget smoke: byte budget exceeded',
    Stats.Buffer.ByteCount <= Stats.Buffer.MaxBytes);
  AssertTrue('small-budget smoke: duration budget exceeded',
    Stats.Buffer.WindowDurationMS <= Stats.Buffer.MaxDurationMS);
  AssertTrue('small-budget smoke: expected age or packet or byte reason',
    (Stats.Buffer.EvictedByAgeLimit > 0) or (Stats.Buffer.EvictedByPacketLimit > 0) or
      (Stats.Buffer.EvictedByByteLimit > 0));
  AssertTrue('small-budget smoke: expected zero server errors', Stats.Errors = 0);

  WriteLn(Format(
    'Small-budget smoke passed: packets=%d evicted=%d packetCount=%d byteCount=%d windowMS=%d',
    [FPacketsReceived, Stats.Buffer.EvictedPackets, Stats.Buffer.PacketCount,
     Stats.Buffer.ByteCount, Stats.Buffer.WindowDurationMS]));
end;

var
  App: TSmallBudgetSmokeApp;

begin
  App := TSmallBudgetSmokeApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

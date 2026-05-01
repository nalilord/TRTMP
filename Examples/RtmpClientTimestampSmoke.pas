program RtmpClientTimestampSmoke;

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
  RtmpCompat,
  RtmpBuffer,
  RtmpClient,
  RtmpPacket,
  RtmpServer,
  RtmpServerSession,
  RtmpTypes;

type
  TUInt32Array = array of UInt32;

  TTimestampSmokeCase = class
  private
    FCapturedTimestamps: TUInt32Array;
    FClient: TRtmpClient;
    FExpectedTimestamps: TUInt32Array;
    FPublishStarted: Boolean;
    FServer: TRtmpServer;
    FSourceBuffer: TRtmpCircularBuffer;
    FSourceTimestamps: TUInt32Array;
    procedure AppendCapturedTimestamp(ATimestamp: UInt32);
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure SeedSourceBuffer;
  public
    constructor Create(APort: Word; ATimestampMode: TRtmpTimestampMode;
      const ASourceTimestamps, AExpectedTimestamps: array of UInt32);
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

function UInt32ArrayToText(const AValues: TUInt32Array): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AValues) do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + IntToStr(AValues[I]);
  end;
end;

constructor TTimestampSmokeCase.Create(APort: Word;
  ATimestampMode: TRtmpTimestampMode; const ASourceTimestamps,
  AExpectedTimestamps: array of UInt32);
var
  ClientConfig: TRtmpClientConfig;
  Config: TRtmpServerConfig;
  I: Integer;
begin
  inherited Create;
  FSourceBuffer := TRtmpCircularBuffer.Create(64, 2 * 1024 * 1024);
  FServer := TRtmpServer.Create;
  FClient := TRtmpClient.Create;
  FPublishStarted := False;
  FCapturedTimestamps := nil;

  SetLength(FSourceTimestamps, Length(ASourceTimestamps));
  for I := 0 to High(ASourceTimestamps) do
    FSourceTimestamps[I] := ASourceTimestamps[I];

  SetLength(FExpectedTimestamps, Length(AExpectedTimestamps));
  for I := 0 to High(AExpectedTimestamps) do
    FExpectedTimestamps[I] := AExpectedTimestamps[I];

  Config := DefaultRtmpServerConfig;
  Config.BindAddress := '127.0.0.1';
  Config.Port := APort;
  Config.BufferMaxPackets := 128;
  Config.BufferMaxBytes := 4 * 1024 * 1024;
  FServer.Config := Config;
  FServer.OnData := HandleData;
  FServer.OnPublishStarted := HandlePublishStarted;

  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig := DefaultRtmpClientConfig;
  ClientConfig.TargetURL := Format('rtmp://127.0.0.1:%d/live/test', [APort]);
  ClientConfig.OutChunkSize := 4096;
  ClientConfig.TimestampMode := ATimestampMode;
  FClient.Config := ClientConfig;
end;

destructor TTimestampSmokeCase.Destroy;
begin
  FClient.Free;
  FServer.Free;
  FSourceBuffer.Free;
  inherited Destroy;
end;

procedure TTimestampSmokeCase.AppendCapturedTimestamp(ATimestamp: UInt32);
var
  Count: Integer;
begin
  Count := Length(FCapturedTimestamps);
  SetLength(FCapturedTimestamps, Count + 1);
  FCapturedTimestamps[Count] := ATimestamp;
end;

procedure TTimestampSmokeCase.HandleData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
begin
  if (Packet <> nil) and Packet.HasFlag(pfIsVideo) then
    AppendCapturedTimestamp(Packet.Timestamp);
end;

procedure TTimestampSmokeCase.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  FPublishStarted := True;
end;

procedure TTimestampSmokeCase.SeedSourceBuffer;
var
  Flags: TRtmpPacketFlags;
  I: Integer;
  Packet: TRtmpPacket;
begin
  for I := 0 to High(FSourceTimestamps) do
  begin
    Flags := [pfIsVideo];
    if I = 0 then
      Include(Flags, pfIsKeyframe);

    Packet := TRtmpPacket.Create(mtVideo, FSourceTimestamps[I], 0, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$17, $01, $00, $00, Byte(I), $09, $10, $11, $12, $13])),
      Flags, I);
    FSourceBuffer.Push(Packet);
  end;
end;

procedure TTimestampSmokeCase.Run;
var
  Deadline: UInt64;
  I: Integer;
begin
  SeedSourceBuffer;
  FServer.Start;
  try
    FClient.Start;
    try
      Deadline := RtmpGetTickCount64 + 4000;
      while RtmpGetTickCount64 < Deadline do
      begin
        if FPublishStarted and (Length(FCapturedTimestamps) >= Length(FExpectedTimestamps)) then
          Break;
        Sleep(50);
      end;
    finally
      FClient.Stop;
    end;
  finally
    FServer.Stop;
  end;

  if not FPublishStarted then
    raise Exception.Create('Timestamp smoke failed: publish did not start');

  if Length(FCapturedTimestamps) < Length(FExpectedTimestamps) then
    raise Exception.CreateFmt('Timestamp smoke failed: expected %d packets, got %d',
      [Length(FExpectedTimestamps), Length(FCapturedTimestamps)]);

  for I := 0 to High(FExpectedTimestamps) do
    if FCapturedTimestamps[I] <> FExpectedTimestamps[I] then
      raise Exception.CreateFmt('Timestamp smoke failed: expected [%s] got [%s]',
        [UInt32ArrayToText(FExpectedTimestamps), UInt32ArrayToText(FCapturedTimestamps)]);
end;

procedure RunCase(const AName: string; APort: Word; ATimestampMode: TRtmpTimestampMode;
  const ASourceTimestamps, AExpectedTimestamps: array of UInt32);
var
  Smoke: TTimestampSmokeCase;
begin
  Smoke := TTimestampSmokeCase.Create(APort, ATimestampMode,
    ASourceTimestamps, AExpectedTimestamps);
  try
    Smoke.Run;
    WriteLn(Format('Timestamp smoke passed: %s', [AName]));
  finally
    Smoke.Free;
  end;
end;

begin
  RunCase('pass-through', 1950, tmPassThrough,
    [1000, 1200, 1400], [1000, 1200, 1400]);
  RunCase('rebased', 1951, tmRebased,
    [1000, 1200, 1400], [0, 200, 400]);
  RunCase('smoothed', 1952, tmSmoothed,
    [1000, 900, 1040], [0, 0, 140]);
end.

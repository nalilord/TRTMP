program RtmpClientSmoke;

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
  TSmokeApp = class
  private
    FClient: TRtmpClient;
    FPacketsReceived: Integer;
    FPublishStarted: Boolean;
    FServer: TRtmpServer;
    FSourceBuffer: TRtmpCircularBuffer;
    procedure HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
    procedure HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
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

constructor TSmokeApp.Create;
var
  ClientConfig: TRtmpClientConfig;
  Config: TRtmpServerConfig;
begin
  inherited Create;
  FSourceBuffer := TRtmpCircularBuffer.Create(64, 2 * 1024 * 1024);
  FServer := TRtmpServer.Create;
  FClient := TRtmpClient.Create;
  FPacketsReceived := 0;
  FPublishStarted := False;

  Config := DefaultRtmpServerConfig;
  Config.BindAddress := '127.0.0.1';
  Config.Port := 1940;
  Config.BufferMaxPackets := 128;
  Config.BufferMaxBytes := 4 * 1024 * 1024;
  FServer.Config := Config;
  FServer.OnData := HandleData;
  FServer.OnPublishStarted := HandlePublishStarted;
  FServer.LogSink.OnLog := HandleServerLog;

  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig := DefaultRtmpClientConfig;
  ClientConfig.TargetURL := 'rtmp://127.0.0.1:1940/live/test';
  ClientConfig.OutChunkSize := 4096;
  FClient.Config := ClientConfig;
  FClient.LogSink.OnLog := HandleClientLog;
end;

destructor TSmokeApp.Destroy;
begin
  FClient.Free;
  FServer.Free;
  FSourceBuffer.Free;
  inherited Destroy;
end;

procedure TSmokeApp.HandleClientLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  WriteLn(Format('[CLIENT] %s: %s', [ACategory, AMessage]));
end;

procedure TSmokeApp.HandleData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
begin
  Inc(FPacketsReceived);
end;

procedure TSmokeApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  FPublishStarted := True;
end;

procedure TSmokeApp.HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  WriteLn(Format('[SERVER] %s: %s', [ACategory, AMessage]));
end;

procedure TSmokeApp.SeedSourceBuffer;
var
  Packet: TRtmpPacket;
begin
  Packet := TRtmpPacket.Create(mtDataAMF0, 0, 0, 1, 5,
    TRtmpSharedPayload.Create(Bytes([$12, 0, 1, 2])), [pfIsMetadata], 0);
  FSourceBuffer.Push(Packet);

  Packet := TRtmpPacket.Create(mtAudio, 0, 0, 1, 4,
    TRtmpSharedPayload.Create(Bytes([$AF, $00, $12, $10])),
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], 1);
  FSourceBuffer.Push(Packet);

  Packet := TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $00, $00, $00, $00, $01, $64, $00, $1E])),
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], 2);
  FSourceBuffer.Push(Packet);

  Packet := TRtmpPacket.Create(mtVideo, 40, 40, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $01, $00, $00, $00, $09, $10, $11, $12, $13])),
    [pfIsVideo, pfIsKeyframe], 3);
  FSourceBuffer.Push(Packet);
end;

procedure TSmokeApp.Run;
var
  Deadline: UInt64;
begin
  SeedSourceBuffer;
  FServer.Start;
  try
    FClient.Start;
    try
      Deadline := RtmpGetTickCount64 + 4000;
      while RtmpGetTickCount64 < Deadline do
      begin
        if FPublishStarted and (FPacketsReceived >= 4) then
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
    raise Exception.Create('Smoke test failed: publish did not start');
  if FPacketsReceived < 4 then
    raise Exception.CreateFmt('Smoke test failed: expected >=4 packets, got %d',
      [FPacketsReceived]);

  WriteLn(Format('Smoke test passed: publishStarted=%s packetsReceived=%d',
    [BoolToStr(FPublishStarted, True), FPacketsReceived]));
end;

var
  App: TSmokeApp;

begin
  App := TSmokeApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

program RtmpClientReconnectSmoke;

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
  TReconnectSmokeApp = class
  private
    FClient: TRtmpClient;
    FPacketsReceived: Integer;
    FPublishStarted: Boolean;
    FServer: TRtmpServer;
    FSourceBuffer: TRtmpCircularBuffer;
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession;
      Packet: TRtmpPacket);
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

constructor TReconnectSmokeApp.Create;
var
  ClientConfig: TRtmpClientConfig;
  ServerConfig: TRtmpServerConfig;
begin
  inherited Create;
  FSourceBuffer := TRtmpCircularBuffer.Create(64, 2 * 1024 * 1024);
  FServer := TRtmpServer.Create;
  FClient := TRtmpClient.Create;
  FPacketsReceived := 0;
  FPublishStarted := False;

  ServerConfig := DefaultRtmpServerConfig;
  ServerConfig.BindAddress := '127.0.0.1';
  ServerConfig.Port := 1942;
  ServerConfig.BufferMaxPackets := 128;
  ServerConfig.BufferMaxBytes := 4 * 1024 * 1024;
  FServer.Config := ServerConfig;
  FServer.OnData := HandleData;
  FServer.OnPublishStarted := HandlePublishStarted;

  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig := DefaultRtmpClientConfig;
  ClientConfig.TargetURL := 'rtmp://127.0.0.1:1942/live/test';
  ClientConfig.ConnectTimeoutMS := 200;
  ClientConfig.OutChunkSize := 4096;
  ClientConfig.ReconnectDelayMS := 250;
  ClientConfig.MaxReconnectDelayMS := 1000;
  FClient.Config := ClientConfig;
end;

destructor TReconnectSmokeApp.Destroy;
begin
  FClient.Free;
  FServer.Free;
  FSourceBuffer.Free;
  inherited Destroy;
end;

procedure TReconnectSmokeApp.HandleData(Sender: TObject;
  Session: TRtmpServerSession; Packet: TRtmpPacket);
begin
  Inc(FPacketsReceived);
end;

procedure TReconnectSmokeApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  FPublishStarted := True;
end;

procedure TReconnectSmokeApp.SeedSourceBuffer;
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

procedure TReconnectSmokeApp.Run;
var
  ClientStats: TRtmpClientStats;
  Deadline: UInt64;
begin
  SeedSourceBuffer;
  FClient.Start;
  try
    Sleep(1200);
    FServer.Start;
    try
      Deadline := RtmpGetTickCount64 + 8000;
      while RtmpGetTickCount64 < Deadline do
      begin
        if FPublishStarted and (FPacketsReceived >= 4) then
          Break;
        Sleep(50);
      end;
    finally
      FServer.Stop;
    end;
  finally
    FClient.Stop;
  end;

  ClientStats := FClient.GetStats;
  if not FPublishStarted then
    raise Exception.Create('Reconnect smoke failed: publish did not start');
  if FPacketsReceived < 4 then
    raise Exception.CreateFmt('Reconnect smoke failed: expected >=4 packets, got %d',
      [FPacketsReceived]);
  if ClientStats.Reconnects = 0 then
    raise Exception.Create('Reconnect smoke failed: reconnect counter did not advance');

  WriteLn(Format(
    'Reconnect smoke passed: publishStarted=%s packetsReceived=%d reconnects=%d',
    [BoolToStr(FPublishStarted, True), FPacketsReceived, ClientStats.Reconnects]));
end;

var
  App: TReconnectSmokeApp;

begin
  App := TReconnectSmokeApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

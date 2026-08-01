program RtmpServerPublishEventSmoke;

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
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Client,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Server.Session,
  TRTMP.RTMP.Types;

type
  TPublishEventSmokeApp = class
  private
    FClient: TRtmpClient;
    FPublishStarted: Boolean;
    FServer: TRtmpServer;
    FSourceBuffer: TRtmpCircularBuffer;
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
  Result:=nil;
  SetLength(Result, Length(AValues));
  for I:=0 to High(AValues) do
    Result[I]:=AValues[I];
end;

constructor TPublishEventSmokeApp.Create;
var
  ClientConfig: TRtmpClientConfig;
  ServerConfig: TRtmpServerConfig;
begin
  inherited Create;
  FClient:=TRtmpClient.Create;
  FPublishStarted:=False;
  FServer:=TRtmpServer.Create;
  FSourceBuffer:=TRtmpCircularBuffer.Create(64, 2 * 1024 * 1024);

  ServerConfig:=DefaultRtmpServerConfig;
  ServerConfig.BindAddress:='127.0.0.1';
  ServerConfig.Port:=1945;
  FServer.Config:=ServerConfig;
  FServer.MinLogLevel:=llError;
  FServer.OnPublishStarted:=HandlePublishStarted;

  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig:=DefaultRtmpClientConfig;
  ClientConfig.TargetURL:='rtmp://127.0.0.1:1945/live/test';
  FClient.Config:=ClientConfig;
end;

destructor TPublishEventSmokeApp.Destroy;
begin
  FClient.Free;
  FServer.Free;
  FSourceBuffer.Free;
  inherited Destroy;
end;

procedure TPublishEventSmokeApp.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
begin
  FPublishStarted:=True;
end;

procedure TPublishEventSmokeApp.SeedSourceBuffer;
var
  Packet: TRtmpPacket;
begin
  Packet:=TRtmpPacket.Create(mtDataAMF0, 0, 0, 1, 5,
    TRtmpSharedPayload.Create(Bytes([$12, $00, $01, $02])), [pfIsMetadata], 0);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtAudio, 0, 0, 1, 4,
    TRtmpSharedPayload.Create(Bytes([$AF, $00, $12, $10])),
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], 1);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $00, $00, $00, $00, $01, $64, $00, $1E])),
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], 2);
  FSourceBuffer.Push(Packet);

  Packet:=TRtmpPacket.Create(mtVideo, 40, 40, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $01, $00, $00, $00, $09, $10, $11, $12, $13])),
    [pfIsVideo, pfIsKeyframe], 3);
  FSourceBuffer.Push(Packet);
end;

procedure TPublishEventSmokeApp.Run;
var
  Deadline: UInt64;
begin
  SeedSourceBuffer;
  FServer.Start;
  try
    FClient.Start;
    try
      Deadline:=GetTickCount64 + 4000;
      while GetTickCount64 < Deadline do
      begin
        if FPublishStarted then
          Break;
        Sleep(50);
      end;
    finally
      FClient.Stop;
    end;
  finally
    FServer.Stop;
  end;

  if NOT FPublishStarted then
    raise Exception.Create(
      'Publish-event smoke failed: OnPublishStarted should fire even when MinLogLevel=llError');

  WriteLn('Server publish-event smoke passed.');
end;

var
  App: TPublishEventSmokeApp;

begin
  App:=TPublishEventSmokeApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

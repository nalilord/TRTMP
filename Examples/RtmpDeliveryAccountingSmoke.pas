program RtmpDeliveryAccountingSmoke;

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
  TRTMP.Core.Compat,
  TRTMP.RTMP.Client,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Server,
  TRTMP.RTMP.Types;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure PushFrame(ABuffer: TRtmpCircularBuffer; AOrdinal: UInt64);
var
  Payload: TBytes;
begin
  SetLength(Payload, 4);
  Payload[0]:=$AF;
  Payload[1]:=1;
  Payload[2]:=Byte(AOrdinal);
  Payload[3]:=$A5;
  ABuffer.Push(TRtmpPacket.Create(mtAudio, UInt32(AOrdinal * 20), 0, 1, 4,
    TRtmpSharedPayload.Create(Payload), [pfIsAudio], AOrdinal));
end;

procedure WaitAccounted(AClient: TRtmpClient; AOrdinal: UInt64);
var
  Deadline: UInt64;
begin
  Deadline:=RtmpGetTickCount64 + 4000;
  while (AClient.Stats.FAccountedMediaOrdinal < AOrdinal) AND (RtmpGetTickCount64 < Deadline) do
    Sleep(10);
  Check(AClient.Stats.FAccountedMediaOrdinal >= AOrdinal, 'Delivery accounting did not advance');
end;

var
  Buffer: TRtmpCircularBuffer;
  Client: TRtmpClient;
  NeverStarted: TRtmpClient;
  ClientConfig: TRtmpClientConfig;
  Config: TRtmpServerConfig;
  Deadline: UInt64;
  I: Integer;
  Server: TRtmpServer;
  Before, After: TRtmpClientStats;
begin
  Buffer:=TRtmpCircularBuffer.Create(3, 1024);
  Client:=TRtmpClient.Create;
  Server:=TRtmpServer.Create;
  try
    Client.AttachBuffer(Buffer);
    ClientConfig:=DefaultRtmpClientConfig;
    ClientConfig.TargetURL:='rtmp://127.0.0.1:1968/live/synthetic';
    ClientConfig.ConnectTimeoutMS:=100;
    ClientConfig.ReconnectDelayMS:=50;
    ClientConfig.MaxReconnectDelayMS:=100;
    ClientConfig.ReaderBatchMaxPackets:=4;
    ClientConfig.ReaderBatchMaxBytes:=1024;
    ClientConfig.ReaderMaxLagMS:=10000;
    Client.Config:=ClientConfig;
    Config:=DefaultRtmpServerConfig;
    Config.BindAddress:='127.0.0.1';
    Config.Port:=1968;
    Server.Config:=Config;
    for I:=1 to 10 do
      PushFrame(Buffer, I);
    Client.Start;
    WaitAccounted(Client, 7);
    Check(Client.Stats.FDroppedMediaPackets = 7, 'Disconnected eviction did not count exactly seven lost frames');
    Before:=Client.Stats;
    After:=Client.Stats;
    Check(Before.FDroppedMediaPackets = After.FDroppedMediaPackets, 'Reading statistics changed the loss counter');
    Server.Start;
    WaitAccounted(Client, 10);
    Check(Client.Stats.FDroppedMediaPackets = 7, 'Recovery recounted already finalized losses');
    Check(Client.Stats.FForwardedMediaPackets = 3, 'Recovery did not forward the retained frames');
    for I:=11 to 20 do
    begin
      PushFrame(Buffer, I);
      WaitAccounted(Client, I);
    end;
    Check(Client.Stats.FDroppedMediaPackets = 7, 'Healthy ring eviction was reported as media loss');
    Server.Stop;
    for I:=21 to 30 do
      PushFrame(Buffer, I);
    Deadline:=RtmpGetTickCount64 + 4000;
    while (Client.Stats.FDroppedMediaPackets = 7) AND (RtmpGetTickCount64 < Deadline) do
      Sleep(10);
    Check(Client.Stats.FDroppedMediaPackets > 7, 'A second disconnection did not advance losses');
    Server.Start;
    WaitAccounted(Client, 30);
    Client.Stop;
    After:=Client.Stats;
    Check(After.FForwardedMediaPackets + After.FDroppedMediaPackets = 30, 'Final loss/sent conservation failed');
    Client.Stop;
    Check(Client.Stats.FDroppedMediaPackets = After.FDroppedMediaPackets, 'Repeated stop recounted the tail');
    PushFrame(Buffer, 31);
    Client.Stop;
    Check(Client.Stats.FDroppedMediaPackets = After.FDroppedMediaPackets, 'Stopped client counted new arrivals');
    NeverStarted:=TRtmpClient.Create;
    try
      NeverStarted.AttachBuffer(Buffer);
      NeverStarted.SetDeliveryBaseline(31);
      for I:=32 to 34 do
        PushFrame(Buffer, I);
      NeverStarted.Stop;
      Check(NeverStarted.Stats.FDroppedMediaPackets = 3,
        'Never-started client did not finalize the eligible tail');
    finally
      NeverStarted.Free;
    end;
    WriteLn(Format('Delivery accounting passed: forwarded=%d dropped=%d input=30',
      [After.FForwardedMediaPackets, After.FDroppedMediaPackets]));
  finally
    Client.Free;
    Server.Free;
    Buffer.Free;
  end;
end.

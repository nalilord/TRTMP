program RtmpServerLifecycleTests;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
uses
  {$IFDEF UNIX}{$IFDEF FPC}cthreads,{$ENDIF}{$ENDIF}
  SysUtils, TRTMP.Core.Compat, TRTMP.RTMP.Server, TRTMP.RTMP.Types,
  TRTMP.Transport, TRTMP.Transport.Platform;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if NOT ACondition then raise Exception.Create(AMessage);
end;

procedure WaitForSessions(AServer: TRtmpServer; ACount: Integer);
var Started: UInt64;
begin
  Started:=RtmpGetTickCount64;
  while (AServer.Stats.ActiveSessions <> ACount) AND
    (RtmpGetTickCount64 - Started < 3000) do RtmpSleepMS(10);
  Check(AServer.Stats.ActiveSessions = ACount, 'Unexpected active session count');
end;

procedure Handshake(const AConnection: IRtmpConnection);
var Buffer: array[0..3072] of Byte; Offset, Received: Integer;
begin
  FillChar(Buffer, SizeOf(Buffer), 0);
  Buffer[0]:=3;
  Check(AConnection.Send(Buffer[0], 1537, 1000) = 1537, 'C0/C1 send failed');
  Offset:=0;
  while Offset < SizeOf(Buffer) do
  begin
    Received:=AConnection.Receive(Buffer[Offset], SizeOf(Buffer) - Offset, 1000);
    Check(Received > 0, 'Handshake reply missing');
    Inc(Offset, Received);
  end;
  Check(AConnection.Send(Buffer[1], 1536, 1000) = 1536, 'C2 send failed');
end;

var
  Server: TRtmpServer;
  Config: TRtmpServerConfig;
  Factory: IRtmpTransportFactory;
  Connection: IRtmpConnection;
  Started: UInt64;
  I: Integer;
begin
  Config:=DefaultRtmpServerConfig;
  Config.BindAddress:='127.0.0.1';
  Config.Port:=StrToIntDef(ParamStr(1), 31936);
  Config.MaxSessions:=1;
  Config.HandshakeTimeoutMS:=250;
  Config.IdleTimeoutMS:=250;
  // A large read wait must not postpone either elapsed deadline.
  Config.ReadTimeoutMS:=10000;
  Factory:=TRtmpPlatformTransportFactory.Create;
  Server:=TRtmpServer.Create(Config);
  try
    Server.MinLogLevel:=llError;
    for I:=1 to 10 do
    begin
      Server.Start;
      Connection:=Factory.CreateClientConnection(
        TRtmpSocketEndpoint.Create(Config.BindAddress, Config.Port), 1000);
      WaitForSessions(Server, 1);
      if I mod 2 = 0 then Handshake(Connection);
      Started:=RtmpGetTickCount64;
      Server.Stop;
      Check(Server.Stats.ActiveSessions = 0, 'Stop returned before session shutdown');
      Check(RtmpGetTickCount64 - Started < 2000, 'Stop failed to unblock receive');
      Connection.Close;
      Connection:=nil;
    end;
    Server.Start;
    Connection:=Factory.CreateClientConnection(
      TRtmpSocketEndpoint.Create(Config.BindAddress, Config.Port), 1000);
    WaitForSessions(Server, 1);
    WaitForSessions(Server, 0);
    Connection.Close;
    // The single admission slot must now be reusable.
    Connection:=Factory.CreateClientConnection(
      TRtmpSocketEndpoint.Create(Config.BindAddress, Config.Port), 1000);
    Handshake(Connection);
    WaitForSessions(Server, 1);
    WaitForSessions(Server, 0);
    Connection.Close;
    Server.Stop;
  finally
    Server.Free;
  end;
  Writeln('RtmpServerLifecycleTests: PASS (shutdown, restart, handshake and idle deadlines)');
end.

program RtmpClientLifetimeSmoke;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

uses
  {$IFDEF UNIX}{$IFDEF FPC}cthreads,{$ENDIF}{$ENDIF}
  SysUtils,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Client,
  TRTMP.RTMP.Types;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

var
  Client: TRtmpClient;
  Config: TRtmpClientConfig;
  I: Integer;
  Started: UInt64;
begin
  Client:=TRtmpClient.Create;
  try
    Started:=RtmpGetTickCount64;
    for I:=1 to 40 do
    begin
      Client.Start;
      Client.Start;
      if I MOD 2 = 0 then
        RtmpSleepMS(2);
      Client.RequestStop;
      Client.Stop;
      Client.Stop;
      Check(Client.State = csStopped, 'client did not stop');
    end;
    Check(RtmpGetTickCount64 - Started < 8000,
      'immediate start/stop did not join promptly');
  finally
    Client.Free;
  end;
  Config:=TRtmpClientConfig.CreateDefault.WithTarget(
    'rtmp://127.0.0.1:1/app', 'app', 'key').WithReconnect(5000, 5000);
  Client:=TRtmpClient.Create(Config);
  try
    Started:=RtmpGetTickCount64;
    Client.Start;
    while (Client.State <> csReconnecting) AND
      (RtmpGetTickCount64 - Started < 1500) do
      RtmpSleepMS(10);
    Check(Client.State = csReconnecting,
      'failed connection did not enter reconnect wait');
    Started:=RtmpGetTickCount64;
    Client.Stop;
    Check(RtmpGetTickCount64 - Started < 500,
      'stop did not interrupt reconnect wait');
    Check(Client.State = csStopped, 'client did not stop after reconnect wait');
  finally
    Client.Free;
  end;
  WriteLn('RtmpClientLifetimeSmoke: PASS');
end.

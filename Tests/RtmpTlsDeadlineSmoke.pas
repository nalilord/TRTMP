program RtmpTlsDeadlineSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  TRTMP.Transport,
  TRTMP.Transport.TLS,
  TRTMP.Transport.TLS.OpenSSL;

var
  Connection: IRtmpConnection;
  Factory: IRtmpTlsTransportFactory;
  Options: TRtmpTlsClientOptions;
  Port: Integer;
  StartedMs: QWord;
  TimedOut: Boolean;
  FailureText: String;
begin
  if (ParamCount <> 1) OR (NOT TryStrToInt(ParamStr(1), Port)) OR
    (Port < 1) OR (Port > 65535) then
    Halt(2);
  Factory:=TRtmpOpenSSLTransportFactory.Create;
  Options:=TRtmpTlsClientOptions.CreateDefault;
  Options.VerifyPeer:=False;
  Options.ServerName:='127.0.0.1';
  TimedOut:=False;
  FailureText:='';
  StartedMs:=GetTickCount64;
  try
    Connection:=Factory.CreateTlsClientConnection(
      TRtmpSocketEndpoint.Create('127.0.0.1', Port), Options, 300);
    if Connection <> nil then
      Connection.Close;
  except
    on E: ERtmpTransportError do
    begin
      TimedOut:=Pos('timed out', E.Message) > 0;
      FailureText:=E.Message;
    end;
  end;
  if (NOT TimedOut) OR (GetTickCount64 - StartedMs > 800) then
  begin
    WriteLn(StdErr, 'elapsed=', GetTickCount64 - StartedMs, ' error=', FailureText);
    Halt(3);
  end;
  WriteLn('TLS handshake deadline passed');
end.

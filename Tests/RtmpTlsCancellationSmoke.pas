program RtmpTlsCancellationSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  TRTMP.Transport,
  TRTMP.Transport.Native,
  TRTMP.Transport.TLS,
  TRTMP.Transport.TLS.OpenSSL;

type
  TCancelToken = class(TInterfacedObject, IRtmpConnectCancellation)
  private
    FCancelled: LongInt;
  public
    procedure Cancel;
    function IsCancelled: Boolean;
  end;

  TCancelThread = class(TThread)
  private
    FToken: TCancelToken;
  protected
    procedure Execute; override;
  public
    constructor Create(AToken: TCancelToken);
  end;

procedure TCancelToken.Cancel;
begin
  InterlockedExchange(FCancelled, 1);
end;

function TCancelToken.IsCancelled: Boolean;
begin
  Result:=InterlockedCompareExchange(FCancelled, 0, 0) <> 0;
end;

constructor TCancelThread.Create(AToken: TCancelToken);
begin
  inherited Create(True);
  FToken:=AToken;
  FreeOnTerminate:=False;
end;

procedure TCancelThread.Execute;
begin
  Sleep(100);
  FToken.Cancel;
end;

var
  CancelThread: TCancelThread;
  Connection: IRtmpConnection;
  Factory: IRtmpCancelableTlsTransportFactory;
  NativeFactory: IRtmpCancelableTransportFactory;
  Options: TRtmpTlsClientOptions;
  Port: Integer;
  StartedMS: QWord;
  Token: IRtmpConnectCancellation;
  TokenObject: TCancelToken;
  WasCancelled: Boolean;
begin
  if (ParamCount <> 1) OR (NOT TryStrToInt(ParamStr(1), Port)) OR
    (Port < 1) OR (Port > 65535) then
    Halt(2);
  Factory:=TRtmpOpenSSLTransportFactory.Create;
  Options:=TRtmpTlsClientOptions.CreateDefault;
  Options.VerifyPeer:=False;
  Options.ServerName:='127.0.0.1';
  TokenObject:=TCancelToken.Create;
  Token:=TokenObject;
  CancelThread:=TCancelThread.Create(TokenObject);
  try
    WasCancelled:=False;
    StartedMS:=GetTickCount64;
    CancelThread.Start;
    try
      Connection:=Factory.CreateTlsClientConnectionCancelable(
        TRtmpSocketEndpoint.Create('127.0.0.1', Port), Options,
        3000, Token);
      if Connection <> nil then
        Connection.Close;
    except
      on E: ERtmpTransportError do
        WasCancelled:=Pos('cancelled', E.Message) > 0;
    end;
    CancelThread.WaitFor;
    if (NOT WasCancelled) OR (GetTickCount64 - StartedMS > 700) then
    begin
      WriteLn(StdErr, 'TLS cancellation failed, elapsed=',
        GetTickCount64 - StartedMS);
      Halt(3);
    end;
    NativeFactory:=TRtmpNativeTransportFactory.Create;
    WasCancelled:=False;
    StartedMS:=GetTickCount64;
    try
      Connection:=NativeFactory.CreateClientConnectionCancelable(
        TRtmpSocketEndpoint.Create('127.0.0.1', Port), 3000, Token);
      if Connection <> nil then
        Connection.Close;
    except
      on E: ERtmpTransportError do
        WasCancelled:=Pos('cancelled', E.Message) > 0;
    end;
    if (NOT WasCancelled) OR (GetTickCount64 - StartedMS > 100) then
      raise Exception.Create('pre-cancelled TCP connect did not abort promptly');
  finally
    CancelThread.Free;
  end;
  WriteLn('TLS handshake cancellation passed');
end.

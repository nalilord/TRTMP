program RtmpTcpCancellationSmoke;

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
  TRTMP.Transport.Native;

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
  Factory: IRtmpCancelableTransportFactory;
  Port: Integer;
  StartedMS: QWord;
  Token: IRtmpConnectCancellation;
  TokenObject: TCancelToken;
  WasCancelled: Boolean;
begin
  if (ParamCount <> 1) OR (NOT TryStrToInt(ParamStr(1), Port)) OR
    (Port < 1) OR (Port > 65535) then
    Halt(2);
  Factory:=TRtmpNativeTransportFactory.Create;
  TokenObject:=TCancelToken.Create;
  Token:=TokenObject;
  CancelThread:=TCancelThread.Create(TokenObject);
  try
    WasCancelled:=False;
    StartedMS:=GetTickCount64;
    CancelThread.Start;
    try
      Connection:=Factory.CreateClientConnectionCancelable(
        TRtmpSocketEndpoint.Create('127.0.0.1', Port), 3000, Token);
      if Connection <> nil then
        Connection.Close;
    except
      on E: ERtmpTransportError do
        WasCancelled:=Pos('cancelled', E.Message) > 0;
    end;
    CancelThread.WaitFor;
    if (NOT WasCancelled) OR (GetTickCount64 - StartedMS < 80) OR
      (GetTickCount64 - StartedMS > 700) then
    begin
      WriteLn(StdErr, 'TCP in-flight cancellation failed, elapsed=',
        GetTickCount64 - StartedMS);
      Halt(3);
    end;
  finally
    CancelThread.Free;
  end;
  WriteLn('TCP in-flight cancellation passed');
end.

program RtmpTlsTransportSmoke;

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
  Classes,
  SysUtils,
  TRTMP.Transport,
  TRTMP.Transport.TLS,
  {$IFDEF MSWINDOWS}
  TRTMP.Transport.TLS.SChannel;
  {$ELSE}
  TRTMP.Transport.TLS.OpenSSL;
  {$ENDIF}

type
  TTlsServerThread = class(TThread)
  private
    FErrorText: string;
    FListener: IRtmpListener;
  protected
    procedure Execute; override;
  public
    constructor Create(const AListener: IRtmpListener);
    destructor Destroy; override;
    property ErrorText: string read FErrorText;
  end;

function ReceiveExact(const AConnection: IRtmpConnection; ABuffer: Pointer;
  ACount, ATimeoutMS: Integer): Boolean;
var
  Offset: Integer;
  ReadCount: Integer;
begin
  Offset:=0;
  while Offset < ACount do
  begin
    ReadCount:=AConnection.Receive(PByte(ABuffer)[Offset], ACount - Offset,
      ATimeoutMS);
    if ReadCount <= 0 then
      Exit(False);
    Inc(Offset, ReadCount);
  end;
  Result:=True;
end;

function SendExact(const AConnection: IRtmpConnection; ABuffer: Pointer;
  ACount, ATimeoutMS: Integer): Boolean;
var
  Offset: Integer;
  SentCount: Integer;
begin
  Offset:=0;
  while Offset < ACount do
  begin
    SentCount:=AConnection.Send(PByte(ABuffer)[Offset], ACount - Offset,
      ATimeoutMS);
    if SentCount <= 0 then
      Exit(False);
    Inc(Offset, SentCount);
  end;
  Result:=True;
end;

constructor TTlsServerThread.Create(const AListener: IRtmpListener);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FErrorText:='';
  FListener:=AListener;
end;

destructor TTlsServerThread.Destroy;
begin
  if FListener <> nil then
    FListener.Close;
  inherited Destroy;
end;

procedure TTlsServerThread.Execute;
var
  Connection: IRtmpConnection;
  RequestBytes: array[0..3] of Byte;
  ResponseBytes: array[0..3] of Byte;
begin
  try
    Connection:=FListener.Accept(5000);
    if Connection = nil then
      raise Exception.Create('TLS server accept timed out');
    if NOT ReceiveExact(Connection, @RequestBytes[0], SizeOf(RequestBytes),
      3000) then
      raise Exception.Create('TLS server did not receive request');
    if (RequestBytes[0] <> Ord('p')) OR (RequestBytes[1] <> Ord('i')) OR
       (RequestBytes[2] <> Ord('n')) OR (RequestBytes[3] <> Ord('g')) then
      raise Exception.Create('TLS server received unexpected request');

    ResponseBytes[0]:=Ord('p');
    ResponseBytes[1]:=Ord('o');
    ResponseBytes[2]:=Ord('n');
    ResponseBytes[3]:=Ord('g');
    if NOT SendExact(Connection, @ResponseBytes[0], SizeOf(ResponseBytes),
      3000) then
      raise Exception.Create('TLS server could not send response');
    Connection.Close;
  except
    on E: Exception do
      FErrorText:=E.Message;
  end;
end;

procedure RunSmoke;
var
  CAFile: string;
  CertificateFile: string;
  CertificatePassword: string;
  ClientOptions: TRtmpTlsClientOptions;
  Connection: IRtmpConnection;
  Listener: IRtmpListener;
  PlatformFactory:
  {$IFDEF MSWINDOWS}
    TRtmpSChannelTransportFactory;
  {$ELSE}
    TRtmpOpenSSLTransportFactory;
  {$ENDIF}
  Port: Integer;
  PrivateKeyFile: string;
  RequestBytes: array[0..3] of Byte;
  ResponseBytes: array[0..3] of Byte;
  ServerName: string;
  ServerOptions: TRtmpTlsServerOptions;
  ServerThread: TTlsServerThread;
  TlsFactory: IRtmpTlsTransportFactory;
begin
  if (ParamCount < 4) OR (ParamCount > 8) then
    raise Exception.Create(
      'Usage: RtmpTlsTransportSmoke <certificate> <private-key> <ca> <port> [password] [verify-peer] [server-name] [minimum-version]');
  CertificateFile:=ParamStr(1);
  PrivateKeyFile:=ParamStr(2);
  CAFile:=ParamStr(3);
  if PrivateKeyFile = '-' then
    PrivateKeyFile:='';
  if CAFile = '-' then
    CAFile:='';
  CertificatePassword:=ParamStr(5);
  ServerName:=ParamStr(7);
  if ServerName = '' then
    ServerName:='127.0.0.1';
  if NOT TryStrToInt(ParamStr(4), Port) OR (Port < 1) OR (Port > 65535) then
    raise Exception.Create('Invalid TLS smoke port');

  PlatformFactory:=
  {$IFDEF MSWINDOWS}
    TRtmpSChannelTransportFactory.Create;
  {$ELSE}
    TRtmpOpenSSLTransportFactory.Create;
  {$ENDIF}
  TlsFactory:=PlatformFactory;
  ServerOptions:=TRtmpTlsServerOptions.CreateDefault;
  ServerOptions.Enabled:=True;
  ServerOptions.CertificateFile:=CertificateFile;
  ServerOptions.CertificatePassword:=CertificatePassword;
  ServerOptions.PrivateKeyFile:=PrivateKeyFile;
  if ParamCount >= 8 then
    if ParamStr(8) = '1.3' then
      ServerOptions.MinimumVersion:=tlsVersion13
    else if ParamStr(8) <> '1.2' then
      raise Exception.Create('Invalid TLS minimum version');
  Listener:=TlsFactory.CreateTlsListener(
    TRtmpSocketEndpoint.Create('127.0.0.1', Word(Port)), 4, ServerOptions);
  ServerThread:=TTlsServerThread.Create(Listener);
  try
    ServerThread.Start;

    ClientOptions:=TRtmpTlsClientOptions.CreateDefault;
    ClientOptions.ServerName:=ServerName;
    ClientOptions.MinimumVersion:=ServerOptions.MinimumVersion;
    {$IFDEF MSWINDOWS}
    ClientOptions.VerifyPeer:=False;
    {$ELSE}
    ClientOptions.CAFile:=CAFile;
    {$ENDIF}
    if ParamCount >= 6 then
      if NOT TryStrToBool(ParamStr(6), ClientOptions.VerifyPeer) then
        raise Exception.Create('Invalid verify-peer value');
    Connection:=TlsFactory.CreateTlsClientConnection(
      TRtmpSocketEndpoint.Create('127.0.0.1', Word(Port)), ClientOptions,
      5000);
    try
      RequestBytes[0]:=Ord('p');
      RequestBytes[1]:=Ord('i');
      RequestBytes[2]:=Ord('n');
      RequestBytes[3]:=Ord('g');
      if NOT SendExact(Connection, @RequestBytes[0], SizeOf(RequestBytes),
        3000) then
        raise Exception.Create('TLS client could not send request');
      if NOT ReceiveExact(Connection, @ResponseBytes[0], SizeOf(ResponseBytes),
        3000) then
        raise Exception.Create('TLS client did not receive response');
      if (ResponseBytes[0] <> Ord('p')) OR
         (ResponseBytes[1] <> Ord('o')) OR
         (ResponseBytes[2] <> Ord('n')) OR
         (ResponseBytes[3] <> Ord('g')) then
        raise Exception.Create('TLS client received unexpected response');
    finally
      Connection.Close;
    end;

    ServerThread.WaitFor;
    if ServerThread.ErrorText <> '' then
      raise Exception.Create('TLS server failed: ' + ServerThread.ErrorText);
  finally
    Listener.Close;
    ServerThread.Free;
  end;

  WriteLn('TLS_TRANSPORT_OK provider=', TlsFactory.TlsDescription,
    ' verify_peer=', BoolToStr(ClientOptions.VerifyPeer, True),
    ' server_name=', ServerName,
    ' minimum=', RtmpTlsVersionName(ClientOptions.MinimumVersion));
end;

begin
  try
    RunSmoke;
  except
    on E: Exception do
    begin
      {$IFDEF FPC}
      WriteLn(StdErr, 'TLS_TRANSPORT_ERROR ', E.Message);
      {$ELSE}
      WriteLn('TLS_TRANSPORT_ERROR ', E.Message);
      {$ENDIF}
      Halt(1);
    end;
  end;
end.

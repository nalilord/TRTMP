program RtmpServerHardeningSmoke;

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
  RtmpBytes,
  RtmpCompat,
  RtmpProtocol,
  RtmpServer,
  RtmpTransport,
  RtmpTransportNative,
  RtmpTypes;

type
  TServerHardeningSmoke = class
  private
    FLogs: TStringList;
    FServer: TRtmpServer;
    FTransportFactory: IRtmpTransportFactory;
    procedure AssertTrue(const AMessage: string; AValue: Boolean);
    procedure HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    function LogContains(const AFragment: string): Boolean;
    function ReadExact(const AConnection: IRtmpConnection; ACount, ATimeoutMS: Integer;
      out ABytes: TBytes): Boolean;
    procedure RestartServer(const AConfig: TRtmpServerConfig);
    procedure SendRawBytes(const AConnection: IRtmpConnection; const ABytes: TBytes);
    procedure SendSetChunkSize(const AConnection: IRtmpConnection; AChunkSize: UInt32);
    procedure StopServer;
    procedure TestMaxChunkSize;
    procedure TestMaxSessions;
    function WaitForActiveSessions(AExpected: Integer; ATimeoutMS: Integer): Boolean;
    function WaitForProtocolErrors(AMinimum: UInt64; ATimeoutMS: Integer): Boolean;
    function WaitForRejectedSessions(AMinimum: UInt64; ATimeoutMS: Integer): Boolean;
    function WaitForServerErrors(AMinimum: UInt64; ATimeoutMS: Integer): Boolean;
    procedure WriteHandshake(const AConnection: IRtmpConnection);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TServerHardeningSmoke.Create;
begin
  inherited Create;
  FLogs := TStringList.Create;
  FTransportFactory := TRtmpNativeTransportFactory.Create;
  FServer := nil;
end;

destructor TServerHardeningSmoke.Destroy;
begin
  StopServer;
  FLogs.Free;
  inherited Destroy;
end;

procedure TServerHardeningSmoke.AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if not AValue then
    raise Exception.Create(AMessage);
end;

procedure TServerHardeningSmoke.HandleServerLog(Sender: TObject;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  FLogs.Add(Format('[%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

function TServerHardeningSmoke.LogContains(const AFragment: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FLogs.Count - 1 do
    if Pos(AFragment, FLogs[I]) > 0 then
      Exit(True);
end;

function TServerHardeningSmoke.ReadExact(const AConnection: IRtmpConnection;
  ACount, ATimeoutMS: Integer; out ABytes: TBytes): Boolean;
var
  Offset: Integer;
  Received: Integer;
begin
  Result := False;
  Offset := 0;
  SetLength(ABytes, ACount);
  while Offset < ACount do
  begin
    Received := AConnection.Receive(ABytes[Offset], ACount - Offset, ATimeoutMS);
    if Received <= 0 then
      Exit(False);
    Inc(Offset, Received);
  end;
  Result := True;
end;

procedure TServerHardeningSmoke.RestartServer(const AConfig: TRtmpServerConfig);
begin
  StopServer;
  FLogs.Clear;
  FServer := TRtmpServer.Create;
  FServer.Config := AConfig;
  FServer.LogSink.OnLog := HandleServerLog;
  FServer.MinLogLevel := llDebug;
  FServer.Start;
end;

procedure TServerHardeningSmoke.Run;
begin
  TestMaxSessions;
  TestMaxChunkSize;
  WriteLn('Server hardening smoke passed.');
end;

procedure TServerHardeningSmoke.SendRawBytes(const AConnection: IRtmpConnection;
  const ABytes: TBytes);
var
  Offset: Integer;
  Sent: Integer;
begin
  Offset := 0;
  while Offset < Length(ABytes) do
  begin
    Sent := AConnection.Send(ABytes[Offset], Length(ABytes) - Offset, 3000);
    if Sent <= 0 then
      raise Exception.Create('Failed to send test bytes');
    Inc(Offset, Sent);
  end;
end;

procedure TServerHardeningSmoke.SendSetChunkSize(const AConnection: IRtmpConnection;
  AChunkSize: UInt32);
var
  Header: TRtmpChunkMessageHeader;
  Payload: TBytes;
  Writer: TRtmpByteWriter;
begin
  Writer := TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AChunkSize);
    Payload := Writer.ToBytes;
    Writer.Clear;

    Header := Default(TRtmpChunkMessageHeader);
    Header.HeaderFormat := hfType0;
    Header.Timestamp := 0;
    Header.MessageLength := Length(Payload);
    Header.MessageTypeID := RtmpMessageTypeID(mtSetChunkSize);
    Header.MessageStreamID := 0;
    Header.HasExtendedTimestamp := False;

    WriteChunkBasicHeader(Writer, hfType0, 2);
    WriteChunkMessageHeader(Writer, Header);
    Writer.WriteBytes(Payload);
    SendRawBytes(AConnection, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TServerHardeningSmoke.StopServer;
begin
  if FServer <> nil then
  begin
    FServer.Stop;
    FreeAndNil(FServer);
  end;
end;

procedure TServerHardeningSmoke.TestMaxChunkSize;
var
  Config: TRtmpServerConfig;
  Connection: IRtmpConnection;
  Endpoint: TRtmpSocketEndpoint;
begin
  Config := DefaultRtmpServerConfig;
  Config.BindAddress := '127.0.0.1';
  Config.Port := 1956;
  Config.MaxSessions := 2;
  Config.MaxChunkSize := 1024;
  RestartServer(Config);

  Endpoint := TRtmpSocketEndpoint.Create('127.0.0.1', Config.Port);
  Connection := FTransportFactory.CreateClientConnection(Endpoint, 3000);
  try
    WriteHandshake(Connection);
    SendSetChunkSize(Connection, 2048);

    AssertTrue('expected chunk-size protocol error',
      WaitForServerErrors(1, 2000));

    AssertTrue('expected oversized chunk-size log entry',
      LogContains('exceeds configured maximum 1024'));
    AssertTrue('expected protocol error counter to increment',
      WaitForProtocolErrors(1, 2000));
    AssertTrue('expected last error category to be protocol',
      FServer.GetStats.LastErrorCategory = 'protocol');
    AssertTrue('expected active sessions to drain after chunk-size rejection',
      WaitForActiveSessions(0, 2000));
  finally
    Connection.Close;
  end;

  StopServer;
end;

procedure TServerHardeningSmoke.TestMaxSessions;
var
  Config: TRtmpServerConfig;
  Connection1: IRtmpConnection;
  Connection2: IRtmpConnection;
  Endpoint: TRtmpSocketEndpoint;
  ReceiveBuffer: array[0..255] of Byte;
  Received: Integer;
begin
  Config := DefaultRtmpServerConfig;
  Config.BindAddress := '127.0.0.1';
  Config.Port := 1955;
  Config.MaxSessions := 1;
  Config.MaxChunkSize := 1024;
  RestartServer(Config);

  Endpoint := TRtmpSocketEndpoint.Create('127.0.0.1', Config.Port);
  Connection1 := FTransportFactory.CreateClientConnection(Endpoint, 3000);
  Connection2 := nil;
  try
    AssertTrue('expected first connection to occupy the only session slot',
      WaitForActiveSessions(1, 2000));

    Connection2 := FTransportFactory.CreateClientConnection(Endpoint, 3000);
    AssertTrue('expected rejected session counter to increment',
      WaitForRejectedSessions(1, 2000));

    Received := Connection2.Receive(ReceiveBuffer, SizeOf(ReceiveBuffer), 1000);
    AssertTrue('expected second connection to be closed by admission control',
      Received <= 0);

    AssertTrue('expected admission rejection log entry',
      LogContains('Rejected connection'));
  finally
    if Connection2 <> nil then
      Connection2.Close;
    Connection1.Close;
    AssertTrue('expected session slot to be released after client close',
      WaitForActiveSessions(0, 2000));
  end;

  StopServer;
end;

function TServerHardeningSmoke.WaitForActiveSessions(AExpected: Integer;
  ATimeoutMS: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := RtmpGetTickCount64 + UInt64(ATimeoutMS);
  repeat
    Result := (FServer <> nil) and (FServer.GetStats.ActiveSessions = AExpected);
    if Result then
      Exit;
    Sleep(20);
  until RtmpGetTickCount64 >= Deadline;
  Result := False;
end;

function TServerHardeningSmoke.WaitForRejectedSessions(AMinimum: UInt64;
  ATimeoutMS: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := RtmpGetTickCount64 + UInt64(ATimeoutMS);
  repeat
    Result := (FServer <> nil) and (FServer.GetStats.RejectedSessions >= AMinimum);
    if Result then
      Exit;
    Sleep(20);
  until RtmpGetTickCount64 >= Deadline;
  Result := False;
end;

function TServerHardeningSmoke.WaitForProtocolErrors(AMinimum: UInt64;
  ATimeoutMS: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := RtmpGetTickCount64 + UInt64(ATimeoutMS);
  repeat
    Result := (FServer <> nil) and (FServer.GetStats.ProtocolErrors >= AMinimum);
    if Result then
      Exit;
    Sleep(20);
  until RtmpGetTickCount64 >= Deadline;
  Result := False;
end;

function TServerHardeningSmoke.WaitForServerErrors(AMinimum: UInt64;
  ATimeoutMS: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := RtmpGetTickCount64 + UInt64(ATimeoutMS);
  repeat
    Result := (FServer <> nil) and (FServer.GetStats.Errors >= AMinimum);
    if Result then
      Exit;
    Sleep(20);
  until RtmpGetTickCount64 >= Deadline;
  Result := False;
end;

procedure TServerHardeningSmoke.WriteHandshake(const AConnection: IRtmpConnection);
var
  C0C1: TBytes;
  C2: TBytes;
  S0S1S2: TBytes;
  S1: TBytes;
begin
  C0C1 := TRtmpHandshake.BuildC0C1;
  SendRawBytes(AConnection, C0C1);

  AssertTrue('expected server handshake response',
    ReadExact(AConnection, 1 + (RTMP_HANDSHAKE_SIZE * 2), 3000, S0S1S2));
  AssertTrue('expected RTMP version in handshake response',
    (Length(S0S1S2) > 0) and (S0S1S2[0] = RTMP_VERSION));

  SetLength(S1, RTMP_HANDSHAKE_SIZE);
  Move(S0S1S2[1], S1[0], RTMP_HANDSHAKE_SIZE);
  C2 := TRtmpHandshake.BuildC2(S1);
  SendRawBytes(AConnection, C2);
end;

var
  Smoke: TServerHardeningSmoke;

begin
  Smoke := TServerHardeningSmoke.Create;
  try
    Smoke.Run;
  finally
    Smoke.Free;
  end;
end.

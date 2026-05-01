unit RtmpTransportNative;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  RtmpTransport;

type
  TRtmpNativeTransportFactory = class(TInterfacedObject, IRtmpTransportFactory)
  public
    function CreateClientConnection(const ARemoteEndpoint: TRtmpSocketEndpoint;
      AConnectTimeoutMS: Integer): IRtmpConnection;
    function CreateListener(const ABindEndpoint: TRtmpSocketEndpoint;
      ABacklog: Integer): IRtmpListener;
    function Description: string;
  end;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows,
  Winapi.Winsock2;
{$ELSE}
uses
  BaseUnix,
  Sockets;
{$ENDIF}

type
  TRtmpSocketHandle =
  {$IFDEF MSWINDOWS}
    TSocket;
  {$ELSE}
    LongInt;
  {$ENDIF}

  TRtmpSockAddrIn =
  {$IFDEF MSWINDOWS}
    sockaddr_in;
  {$ELSE}
    TInetSockAddr;
  {$ENDIF}

  TRtmpSocketLen =
  {$IFDEF MSWINDOWS}
    Integer;
  {$ELSE}
    TSockLen;
  {$ENDIF}

const
  RTMP_INVALID_SOCKET =
  {$IFDEF MSWINDOWS}
    INVALID_SOCKET;
  {$ELSE}
    -1;
  {$ENDIF}

type
  TRtmpNativeConnection = class(TInterfacedObject, IRtmpConnection)
  private
    FConnected: Boolean;
    FLocalEndpoint: TRtmpSocketEndpoint;
    FRemoteEndpoint: TRtmpSocketEndpoint;
    FSocket: TRtmpSocketHandle;
  public
    constructor Create(ASocket: TRtmpSocketHandle;
      const ALocalEndpoint, ARemoteEndpoint: TRtmpSocketEndpoint);
    destructor Destroy; override;

    procedure Close;
    function GetConnected: Boolean;
    function GetLocalEndpoint: TRtmpSocketEndpoint;
    function GetRemoteEndpoint: TRtmpSocketEndpoint;
    function Receive(var ABuffer; ACount: Integer; ATimeoutMS: Integer): Integer;
    function Send(const ABuffer; ACount: Integer; ATimeoutMS: Integer): Integer;
  end;

  TRtmpNativeListener = class(TInterfacedObject, IRtmpListener)
  private
    FBoundEndpoint: TRtmpSocketEndpoint;
    FListening: Boolean;
    FSocket: TRtmpSocketHandle;
  public
    constructor Create(ASocket: TRtmpSocketHandle;
      const ABoundEndpoint: TRtmpSocketEndpoint);
    destructor Destroy; override;

    function Accept(ATimeoutMS: Integer): IRtmpConnection;
    procedure Close;
    function GetBoundEndpoint: TRtmpSocketEndpoint;
    function GetListening: Boolean;
  end;

{$IFDEF MSWINDOWS}
var
  GSocketStartupDone: Boolean = False;
{$ENDIF}

procedure EnsureSocketsInitialized;
{$IFDEF MSWINDOWS}
var
  WsaData: TWSAData;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if not GSocketStartupDone then
  begin
    if WSAStartup($0202, WsaData) <> 0 then
      raise ERtmpTransportError.Create('WSAStartup failed');
    GSocketStartupDone := True;
  end;
  {$ENDIF}
end;

function LastSocketErrorCode: Integer;
begin
  {$IFDEF MSWINDOWS}
  Result := WSAGetLastError;
  {$ELSE}
  Result := SocketError;
  {$ENDIF}
end;

function WouldBlockError(AErrorCode: Integer): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := (AErrorCode = WSAEWOULDBLOCK) or (AErrorCode = WSAEINPROGRESS) or
    (AErrorCode = WSAEALREADY);
  {$ELSE}
  Result := (AErrorCode = ESysEWOULDBLOCK) or (AErrorCode = ESysEINPROGRESS) or
    (AErrorCode = ESysEALREADY) or (AErrorCode = ESysEAGAIN);
  {$ENDIF}
end;

procedure CloseNativeSocket(var ASocket: TRtmpSocketHandle);
begin
  if ASocket = RTMP_INVALID_SOCKET then
    Exit;

  {$IFDEF MSWINDOWS}
  closesocket(ASocket);
  {$ELSE}
  fpclose(ASocket);
  {$ENDIF}
  ASocket := RTMP_INVALID_SOCKET;
end;

procedure SetReuseAddr(ASocket: TRtmpSocketHandle);
var
  OptValue: LongInt;
begin
  OptValue := 1;
  {$IFDEF MSWINDOWS}
  setsockopt(ASocket, SOL_SOCKET, SO_REUSEADDR, @OptValue, SizeOf(OptValue));
  {$ELSE}
  fpsetsockopt(ASocket, SOL_SOCKET, SO_REUSEADDR, @OptValue, SizeOf(OptValue));
  {$ENDIF}
end;

function SetBlockingMode(ASocket: TRtmpSocketHandle; ABlocking: Boolean): Boolean;
{$IFDEF MSWINDOWS}
var
  NonBlocking: u_long;
begin
  if ABlocking then
    NonBlocking := 0
  else
    NonBlocking := 1;
  Result := ioctlsocket(ASocket, FIONBIO, NonBlocking) = 0;
end;
{$ELSE}
var
  Flags: LongInt;
begin
  Flags := fpfcntl(ASocket, F_GETFL, 0);
  if Flags < 0 then
    Exit(False);

  if ABlocking then
    Flags := Flags and not O_NONBLOCK
  else
    Flags := Flags or O_NONBLOCK;

  Result := fpfcntl(ASocket, F_SETFL, Flags) = 0;
end;
{$ENDIF}

function WaitForSocket(ASocket: TRtmpSocketHandle; ARead, AWrite: Boolean;
  ATimeoutMS: Integer): Boolean;
{$IFDEF MSWINDOWS}
var
  ReadSet: TFDSet;
  WriteSet: TFDSet;
  ReadSetPtr: PFdSet;
  WriteSetPtr: PFdSet;
  TimeValue: timeval;
begin
  FD_ZERO(ReadSet);
  FD_ZERO(WriteSet);
  ReadSetPtr := nil;
  WriteSetPtr := nil;

  if ARead then
  begin
    _FD_SET(ASocket, ReadSet);
    ReadSetPtr := @ReadSet;
  end;

  if AWrite then
  begin
    _FD_SET(ASocket, WriteSet);
    WriteSetPtr := @WriteSet;
  end;

  TimeValue.tv_sec := ATimeoutMS div 1000;
  TimeValue.tv_usec := (ATimeoutMS mod 1000) * 1000;
  Result := select(0, ReadSetPtr, WriteSetPtr, nil, @TimeValue) > 0;
end;
{$ELSE}
var
  ReadSet: TFDSet;
  WriteSet: TFDSet;
  ReadSetPtr: PFDSet;
  WriteSetPtr: PFDSet;
  TimeValue: TTimeVal;
begin
  fpFD_ZERO(ReadSet);
  fpFD_ZERO(WriteSet);
  ReadSetPtr := nil;
  WriteSetPtr := nil;

  if ARead then
  begin
    fpFD_SET(ASocket, ReadSet);
    ReadSetPtr := @ReadSet;
  end;

  if AWrite then
  begin
    fpFD_SET(ASocket, WriteSet);
    WriteSetPtr := @WriteSet;
  end;

  TimeValue.tv_sec := ATimeoutMS div 1000;
  TimeValue.tv_usec := (ATimeoutMS mod 1000) * 1000;
  Result := fpselect(ASocket + 1, ReadSetPtr, WriteSetPtr, nil, @TimeValue) > 0;
end;
{$ENDIF}

function GetSocketOptionError(ASocket: TRtmpSocketHandle): Integer;
var
  ErrorCode: Integer;
  OptionLen: TRtmpSocketLen;
begin
  ErrorCode := 0;
  OptionLen := SizeOf(ErrorCode);
  {$IFDEF MSWINDOWS}
  if getsockopt(ASocket, SOL_SOCKET, SO_ERROR, @ErrorCode, OptionLen) <> 0 then
    Result := LastSocketErrorCode
  else
    Result := ErrorCode;
  {$ELSE}
  if fpgetsockopt(ASocket, SOL_SOCKET, SO_ERROR, @ErrorCode, @OptionLen) <> 0 then
    Result := LastSocketErrorCode
  else
    Result := ErrorCode;
  {$ENDIF}
end;

procedure RaiseSocketError(const AOperation: string; AErrorCode: Integer = 0);
begin
  if AErrorCode = 0 then
    AErrorCode := LastSocketErrorCode;
  raise ERtmpTransportError.CreateFmt('%s failed with socket error %d',
    [AOperation, AErrorCode]);
end;

function TryParseIPv4(const AAddress: string; out ABytes: array of Byte): Boolean;
var
  Parts: array[0..3] of string;
  PartIndex: Integer;
  I: Integer;
  Current: string;
  Value: Integer;
begin
  Result := False;
  if Length(ABytes) < 4 then
    Exit;

  if (AAddress = '') or SameText(AAddress, '0.0.0.0') or (AAddress = '*') then
  begin
    ABytes[0] := 0;
    ABytes[1] := 0;
    ABytes[2] := 0;
    ABytes[3] := 0;
    Exit(True);
  end;

  if SameText(AAddress, 'localhost') then
  begin
    ABytes[0] := 127;
    ABytes[1] := 0;
    ABytes[2] := 0;
    ABytes[3] := 1;
    Exit(True);
  end;

  PartIndex := 0;
  Current := '';
  for I := 1 to Length(AAddress) do
  begin
    if AAddress[I] = '.' then
    begin
      if PartIndex > 3 then
        Exit(False);
      Parts[PartIndex] := Current;
      Current := '';
      Inc(PartIndex);
    end
    else
      Current := Current + AAddress[I];
  end;

  if PartIndex <> 3 then
    Exit(False);
  Parts[3] := Current;

  for I := 0 to 3 do
  begin
    if not TryStrToInt(Parts[I], Value) then
      Exit(False);
    if (Value < 0) or (Value > 255) then
      Exit(False);
    ABytes[I] := Byte(Value);
  end;

  Result := True;
end;

function EndpointToSockAddr(const AEndpoint: TRtmpSocketEndpoint;
  out ASockAddr: TRtmpSockAddrIn): Boolean;
var
  AddressBytes: array[0..3] of Byte;
begin
  FillChar(ASockAddr, SizeOf(ASockAddr), 0);
  Result := TryParseIPv4(AEndpoint.Address, AddressBytes);
  if not Result then
    Exit;

  ASockAddr.sin_family := AF_INET;
  ASockAddr.sin_port := htons(AEndpoint.Port);
  Move(AddressBytes[0], ASockAddr.sin_addr, SizeOf(AddressBytes));
end;

function SockAddrToEndpoint(const ASockAddr: TRtmpSockAddrIn): TRtmpSocketEndpoint;
var
  AddressBytes: array[0..3] of Byte;
begin
  Move(ASockAddr.sin_addr, AddressBytes[0], SizeOf(AddressBytes));
  Result.Address := Format('%d.%d.%d.%d',
    [AddressBytes[0], AddressBytes[1], AddressBytes[2], AddressBytes[3]]);
  Result.Port := ntohs(ASockAddr.sin_port);
end;

function CreateNativeSocket: TRtmpSocketHandle;
begin
  EnsureSocketsInitialized;
  {$IFDEF MSWINDOWS}
  Result := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  {$ELSE}
  Result := fpsocket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
  if Result = RTMP_INVALID_SOCKET then
    RaiseSocketError('socket');
end;

function ConnectSocketWithTimeout(ASocket: TRtmpSocketHandle;
  const ARemoteEndpoint: TRtmpSocketEndpoint; ATimeoutMS: Integer): Boolean;
var
  SockAddr: TRtmpSockAddrIn;
  {$IFDEF MSWINDOWS}
  SockAddrAny: TSockAddr absolute SockAddr;
  {$ENDIF}
  ErrorCode: Integer;
begin
  if not EndpointToSockAddr(ARemoteEndpoint, SockAddr) then
    raise ERtmpTransportError.CreateFmt(
      'Only numeric IPv4 addresses or localhost are currently supported by the native backend: %s',
      [ARemoteEndpoint.Address]);

  if not SetBlockingMode(ASocket, False) then
    RaiseSocketError('set non-blocking connect mode');

  {$IFDEF MSWINDOWS}
  Result := Winapi.Winsock2.connect(ASocket, SockAddrAny, SizeOf(SockAddr)) = 0;
  {$ELSE}
  Result := fpconnect(ASocket, @SockAddr, SizeOf(SockAddr)) = 0;
  {$ENDIF}

  if not Result then
  begin
    ErrorCode := LastSocketErrorCode;
    if not WouldBlockError(ErrorCode) then
      RaiseSocketError('connect', ErrorCode);

    if not WaitForSocket(ASocket, False, True, ATimeoutMS) then
      Exit(False);

    ErrorCode := GetSocketOptionError(ASocket);
    if ErrorCode <> 0 then
      RaiseSocketError('connect', ErrorCode);

    Result := True;
  end;

  if not SetBlockingMode(ASocket, True) then
    RaiseSocketError('restore blocking mode after connect');
end;

constructor TRtmpNativeConnection.Create(ASocket: TRtmpSocketHandle;
  const ALocalEndpoint, ARemoteEndpoint: TRtmpSocketEndpoint);
begin
  inherited Create;
  FSocket := ASocket;
  FLocalEndpoint := ALocalEndpoint;
  FRemoteEndpoint := ARemoteEndpoint;
  FConnected := ASocket <> RTMP_INVALID_SOCKET;
end;

destructor TRtmpNativeConnection.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TRtmpNativeConnection.Close;
begin
  if not FConnected then
    Exit;

  FConnected := False;
  CloseNativeSocket(FSocket);
end;

function TRtmpNativeConnection.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TRtmpNativeConnection.GetLocalEndpoint: TRtmpSocketEndpoint;
begin
  Result := FLocalEndpoint;
end;

function TRtmpNativeConnection.GetRemoteEndpoint: TRtmpSocketEndpoint;
begin
  Result := FRemoteEndpoint;
end;

function TRtmpNativeConnection.Receive(var ABuffer; ACount,
  ATimeoutMS: Integer): Integer;
begin
  if not FConnected then
    Exit(0);

  if not WaitForSocket(FSocket, True, False, ATimeoutMS) then
    Exit(0);

  {$IFDEF MSWINDOWS}
  Result := recv(FSocket, ABuffer, ACount, 0);
  {$ELSE}
  Result := fprecv(FSocket, @ABuffer, ACount, 0);
  {$ENDIF}

  if Result = 0 then
    Close
  else if Result < 0 then
  begin
    if WouldBlockError(LastSocketErrorCode) then
      Exit(0);
    Close;
    RaiseSocketError('recv');
  end;
end;

function TRtmpNativeConnection.Send(const ABuffer; ACount,
  ATimeoutMS: Integer): Integer;
begin
  if not FConnected then
    Exit(0);

  if not WaitForSocket(FSocket, False, True, ATimeoutMS) then
    Exit(0);

  {$IFDEF MSWINDOWS}
  Result := Winapi.Winsock2.send(FSocket, ABuffer, ACount, 0);
  {$ELSE}
  Result := fpsend(FSocket, @ABuffer, ACount, 0);
  {$ENDIF}

  if Result < 0 then
  begin
    if WouldBlockError(LastSocketErrorCode) then
      Exit(0);
    Close;
    RaiseSocketError('send');
  end;
end;

constructor TRtmpNativeListener.Create(ASocket: TRtmpSocketHandle;
  const ABoundEndpoint: TRtmpSocketEndpoint);
begin
  inherited Create;
  FSocket := ASocket;
  FBoundEndpoint := ABoundEndpoint;
  FListening := ASocket <> RTMP_INVALID_SOCKET;
end;

destructor TRtmpNativeListener.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TRtmpNativeListener.Accept(ATimeoutMS: Integer): IRtmpConnection;
var
  ClientAddr: TRtmpSockAddrIn;
  ClientLen: TRtmpSocketLen;
  ClientSocket: TRtmpSocketHandle;
begin
  Result := nil;
  if not FListening then
    Exit;

  if not WaitForSocket(FSocket, True, False, ATimeoutMS) then
    Exit;

  FillChar(ClientAddr, SizeOf(ClientAddr), 0);
  ClientLen := SizeOf(ClientAddr);
  {$IFDEF MSWINDOWS}
  ClientSocket := Winapi.Winsock2.accept(FSocket, PSockAddr(@ClientAddr), @ClientLen);
  {$ELSE}
  ClientSocket := fpaccept(FSocket, @ClientAddr, @ClientLen);
  {$ENDIF}
  if ClientSocket = RTMP_INVALID_SOCKET then
    RaiseSocketError('accept');

  Result := TRtmpNativeConnection.Create(ClientSocket, FBoundEndpoint,
    SockAddrToEndpoint(ClientAddr));
end;

procedure TRtmpNativeListener.Close;
begin
  if not FListening then
    Exit;

  FListening := False;
  CloseNativeSocket(FSocket);
end;

function TRtmpNativeListener.GetBoundEndpoint: TRtmpSocketEndpoint;
begin
  Result := FBoundEndpoint;
end;

function TRtmpNativeListener.GetListening: Boolean;
begin
  Result := FListening;
end;

function TRtmpNativeTransportFactory.CreateClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint; AConnectTimeoutMS: Integer): IRtmpConnection;
var
  SocketHandle: TRtmpSocketHandle;
begin
  SocketHandle := CreateNativeSocket;
  try
    if not ConnectSocketWithTimeout(SocketHandle, ARemoteEndpoint, AConnectTimeoutMS) then
      raise ERtmpTransportError.CreateFmt('Connect timeout to %s:%d',
        [ARemoteEndpoint.Address, ARemoteEndpoint.Port]);

    Result := TRtmpNativeConnection.Create(SocketHandle,
      TRtmpSocketEndpoint.Create('0.0.0.0', 0), ARemoteEndpoint);
    SocketHandle := RTMP_INVALID_SOCKET;
  finally
    CloseNativeSocket(SocketHandle);
  end;
end;

function TRtmpNativeTransportFactory.CreateListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer): IRtmpListener;
var
  SocketHandle: TRtmpSocketHandle;
  SockAddr: TRtmpSockAddrIn;
  {$IFDEF MSWINDOWS}
  SockAddrAny: TSockAddr absolute SockAddr;
  {$ENDIF}
begin
  if not EndpointToSockAddr(ABindEndpoint, SockAddr) then
    raise ERtmpTransportError.CreateFmt(
      'Only numeric IPv4 addresses or localhost are currently supported by the native backend: %s',
      [ABindEndpoint.Address]);

  SocketHandle := CreateNativeSocket;
  try
    SetReuseAddr(SocketHandle);

    {$IFDEF MSWINDOWS}
    if Winapi.Winsock2.bind(SocketHandle, SockAddrAny, SizeOf(SockAddr)) <> 0 then
      RaiseSocketError('bind');
    if Winapi.Winsock2.listen(SocketHandle, ABacklog) <> 0 then
      RaiseSocketError('listen');
    {$ELSE}
    if fpbind(SocketHandle, @SockAddr, SizeOf(SockAddr)) <> 0 then
      RaiseSocketError('bind');
    if fplisten(SocketHandle, ABacklog) <> 0 then
      RaiseSocketError('listen');
    {$ENDIF}

    Result := TRtmpNativeListener.Create(SocketHandle, ABindEndpoint);
    SocketHandle := RTMP_INVALID_SOCKET;
  finally
    CloseNativeSocket(SocketHandle);
  end;
end;

function TRtmpNativeTransportFactory.Description: string;
begin
  {$IFDEF MSWINDOWS}
  Result := 'native WinSock transport';
  {$ELSE}
  Result := 'native POSIX transport';
  {$ENDIF}
end;

end.

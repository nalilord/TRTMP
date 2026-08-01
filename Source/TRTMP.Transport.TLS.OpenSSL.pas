unit TRTMP.Transport.TLS.OpenSSL;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  TRTMP.Transport,
  TRTMP.Transport.Native,
  TRTMP.Transport.TLS;

type
  TRtmpOpenSSLTransportFactory = class(TInterfacedObject,
    IRtmpTransportFactory, IRtmpTlsTransportFactory)
  private
    FNativeFactory: IRtmpTransportFactory;
  public
    constructor Create;
    function CreateClientConnection(const ARemoteEndpoint: TRtmpSocketEndpoint;
      AConnectTimeoutMS: Integer): IRtmpConnection;
    function CreateListener(const ABindEndpoint: TRtmpSocketEndpoint;
      ABacklog: Integer): IRtmpListener;
    function CreateTlsClientConnection(
      const ARemoteEndpoint: TRtmpSocketEndpoint;
      const AOptions: TRtmpTlsClientOptions;
      AConnectTimeoutMS: Integer): IRtmpConnection;
    function CreateTlsListener(const ABindEndpoint: TRtmpSocketEndpoint;
      ABacklog: Integer; const AOptions: TRtmpTlsServerOptions): IRtmpListener;
    function Description: string;
    function TlsDescription: string;
  end;

implementation

{$IFDEF MSWINDOWS}

constructor TRtmpOpenSSLTransportFactory.Create;
begin
  inherited Create;
  FNativeFactory:=TRtmpNativeTransportFactory.Create;
end;

function TRtmpOpenSSLTransportFactory.CreateClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Result:=FNativeFactory.CreateClientConnection(ARemoteEndpoint,
    AConnectTimeoutMS);
end;

function TRtmpOpenSSLTransportFactory.CreateListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer): IRtmpListener;
begin
  Result:=FNativeFactory.CreateListener(ABindEndpoint, ABacklog);
end;

function TRtmpOpenSSLTransportFactory.CreateTlsClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  const AOptions: TRtmpTlsClientOptions;
  AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Result:=nil;
  raise ERtmpTransportError.Create(
    'The OpenSSL transport provider is available only on Unix-like systems');
end;

function TRtmpOpenSSLTransportFactory.CreateTlsListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer;
  const AOptions: TRtmpTlsServerOptions): IRtmpListener;
begin
  Result:=nil;
  raise ERtmpTransportError.Create(
    'The OpenSSL transport provider is available only on Unix-like systems');
end;

function TRtmpOpenSSLTransportFactory.Description: string;
begin
  Result:=FNativeFactory.Description;
end;

function TRtmpOpenSSLTransportFactory.TlsDescription: string;
begin
  Result:='OpenSSL TLS transport unavailable on Windows';
end;

{$ELSE}

uses
  BaseUnix,
  Dynlibs,
  Sockets;

type
  PSSL_CTX = Pointer;
  PSSL = Pointer;
  PX509_VERIFY_PARAM = Pointer;

  TTlsMethod = function: Pointer; cdecl;
  TSSLCTXNew = function(AMethod: Pointer): PSSL_CTX; cdecl;
  TSSLCTXFree = procedure(AContext: PSSL_CTX); cdecl;
  TSSLCTXCtrl = function(AContext: PSSL_CTX; ACommand: Integer;
    AArgument: PtrInt; AData: Pointer): PtrInt; cdecl;
  TSSLCTXSetVerify = procedure(AContext: PSSL_CTX; AMode: Integer;
    ACallback: Pointer); cdecl;
  TSSLCTXLoadVerifyLocations = function(AContext: PSSL_CTX;
    ACAFile, ACAPath: PAnsiChar): Integer; cdecl;
  TSSLCTXSetDefaultVerifyPaths = function(AContext: PSSL_CTX): Integer; cdecl;
  TPemPasswordCallback = function(ABuffer: PAnsiChar; ASize, AReadWriteFlag:
    Integer; AUserData: Pointer): Integer; cdecl;
  TSSLCTXSetDefaultPasswordCallback = procedure(AContext: PSSL_CTX;
    ACallback: TPemPasswordCallback); cdecl;
  TSSLCTXSetDefaultPasswordCallbackUserData = procedure(AContext: PSSL_CTX;
    AUserData: Pointer); cdecl;
  TSSLCTXUseCertificateChainFile = function(AContext: PSSL_CTX;
    AFileName: PAnsiChar): Integer; cdecl;
  TSSLCTXUsePrivateKeyFile = function(AContext: PSSL_CTX;
    AFileName: PAnsiChar; AFileType: Integer): Integer; cdecl;
  TSSLCTXCheckPrivateKey = function(AContext: PSSL_CTX): Integer; cdecl;
  TSSLNew = function(AContext: PSSL_CTX): PSSL; cdecl;
  TSSLFree = procedure(ASSL: PSSL); cdecl;
  TSSLSetFD = function(ASSL: PSSL; AFileDescriptor: Integer): Integer; cdecl;
  TSSLCtrl = function(ASSL: PSSL; ACommand: Integer; AArgument: PtrInt;
    AData: Pointer): PtrInt; cdecl;
  TSSLSet1Host = function(ASSL: PSSL; AHostName: PAnsiChar): Integer; cdecl;
  TSSLGet0Param = function(ASSL: PSSL): PX509_VERIFY_PARAM; cdecl;
  TX509VerifyParamSet1IPAsc = function(AParam: PX509_VERIFY_PARAM;
    AIPAddress: PAnsiChar): Integer; cdecl;
  TSSLHandshake = function(ASSL: PSSL): Integer; cdecl;
  TSSLRead = function(ASSL: PSSL; ABuffer: Pointer;
    ACount: Integer): Integer; cdecl;
  TSSLWrite = function(ASSL: PSSL; ABuffer: Pointer;
    ACount: Integer): Integer; cdecl;
  TSSLShutdown = function(ASSL: PSSL): Integer; cdecl;
  TSSLGetError = function(ASSL: PSSL; AResult: Integer): Integer; cdecl;
  TSSLGetVerifyResult = function(ASSL: PSSL): PtrInt; cdecl;
  TERRGetError = function: NativeUInt; cdecl;
  TERRErrorStringN = procedure(AError: NativeUInt; ABuffer: PAnsiChar;
    ALength: NativeUInt); cdecl;

  TRtmpOpenSSLConnection = class(TInterfacedObject, IRtmpConnection)
  private
    FConnection: IRtmpConnection;
    FContext: PSSL_CTX;
    FSSL: PSSL;
    function SocketHandle: LongInt;
  public
    constructor Create(const AConnection: IRtmpConnection;
      AContext: PSSL_CTX; ASSL: PSSL);
    destructor Destroy; override;
    procedure Close;
    function GetConnected: Boolean;
    function GetLocalEndpoint: TRtmpSocketEndpoint;
    function GetRemoteEndpoint: TRtmpSocketEndpoint;
    function Receive(var ABuffer; ACount: Integer; ATimeoutMS: Integer): Integer;
    function Send(const ABuffer; ACount: Integer; ATimeoutMS: Integer): Integer;
  end;

  TRtmpOpenSSLListener = class(TInterfacedObject, IRtmpListener)
  private
    FContext: PSSL_CTX;
    FListener: IRtmpListener;
  public
    constructor Create(const AListener: IRtmpListener; AContext: PSSL_CTX);
    destructor Destroy; override;
    function Accept(ATimeoutMS: Integer): IRtmpConnection;
    procedure Close;
    function GetBoundEndpoint: TRtmpSocketEndpoint;
    function GetListening: Boolean;
  end;

const
  SSL_FILETYPE_PEM = 1;
  SSL_VERIFY_NONE = 0;
  SSL_VERIFY_PEER = 1;
  SSL_VERIFY_FAIL_IF_NO_PEER_CERT = 2;
  SSL_ERROR_NONE = 0;
  SSL_ERROR_WANT_READ = 2;
  SSL_ERROR_WANT_WRITE = 3;
  SSL_ERROR_SYSCALL = 5;
  SSL_ERROR_ZERO_RETURN = 6;
  SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
  TLSEXT_NAMETYPE_HOST_NAME = 0;
  TLS1_2_VERSION = $0303;
  TLS1_3_VERSION = $0304;
  X509_V_OK = 0;

var
  GSSLHandle: TLibHandle = dynlibs.NilHandle;
  GCryptoHandle: TLibHandle = dynlibs.NilHandle;
  GTlsClientMethod: TTlsMethod;
  GTlsServerMethod: TTlsMethod;
  GSSLCTXNew: TSSLCTXNew;
  GSSLCTXFree: TSSLCTXFree;
  GSSLCTXCtrl: TSSLCTXCtrl;
  GSSLCTXSetVerify: TSSLCTXSetVerify;
  GSSLCTXLoadVerifyLocations: TSSLCTXLoadVerifyLocations;
  GSSLCTXSetDefaultVerifyPaths: TSSLCTXSetDefaultVerifyPaths;
  GSSLCTXSetDefaultPasswordCallback: TSSLCTXSetDefaultPasswordCallback;
  GSSLCTXSetDefaultPasswordCallbackUserData:
    TSSLCTXSetDefaultPasswordCallbackUserData;
  GSSLCTXUseCertificateChainFile: TSSLCTXUseCertificateChainFile;
  GSSLCTXUsePrivateKeyFile: TSSLCTXUsePrivateKeyFile;
  GSSLCTXCheckPrivateKey: TSSLCTXCheckPrivateKey;
  GSSLNew: TSSLNew;
  GSSLFree: TSSLFree;
  GSSLSetFD: TSSLSetFD;
  GSSLCtrl: TSSLCtrl;
  GSSLSet1Host: TSSLSet1Host;
  GSSLGet0Param: TSSLGet0Param;
  GX509VerifyParamSet1IPAsc: TX509VerifyParamSet1IPAsc;
  GSSLConnect: TSSLHandshake;
  GSSLAccept: TSSLHandshake;
  GSSLRead: TSSLRead;
  GSSLWrite: TSSLWrite;
  GSSLShutdown: TSSLShutdown;
  GSSLGetError: TSSLGetError;
  GSSLGetVerifyResult: TSSLGetVerifyResult;
  GERRGetError: TERRGetError;
  GERRErrorStringN: TERRErrorStringN;
  GOpenSSLLock: TRTLCriticalSection;
  GOpenSSLLoaded: Boolean = False;

function LoadFirstLibrary(const ANames: array of string): TLibHandle;
var
  I: Integer;
begin
  Result:=dynlibs.NilHandle;
  for I:=Low(ANames) to High(ANames) do
  begin
    Result:=LoadLibrary(ANames[I]);
    if Result <> dynlibs.NilHandle then
      Exit;
  end;
end;

function RequiredProcedure(AHandle: TLibHandle;
  const AName: PAnsiChar): Pointer;
begin
  Result:=GetProcedureAddress(AHandle, AName);
  if Result = nil then
    raise ERtmpTransportError.CreateFmt(
      'System OpenSSL is missing required procedure %s', [string(AName)]);
end;

procedure LoadOpenSSLProcedures;
begin
  GSSLHandle:=LoadFirstLibrary(['libssl.so.3', 'libssl.so.1.1', 'libssl.so']);
  if GSSLHandle = dynlibs.NilHandle then
    raise ERtmpTransportError.Create(
      'System OpenSSL libssl was not found');

  GCryptoHandle:=LoadFirstLibrary(
    ['libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so']);
  if GCryptoHandle = dynlibs.NilHandle then
    raise ERtmpTransportError.Create(
      'System OpenSSL libcrypto was not found');

  GTlsClientMethod:=TTlsMethod(RequiredProcedure(GSSLHandle,
    'TLS_client_method'));
  GTlsServerMethod:=TTlsMethod(RequiredProcedure(GSSLHandle,
    'TLS_server_method'));
  GSSLCTXNew:=TSSLCTXNew(RequiredProcedure(GSSLHandle, 'SSL_CTX_new'));
  GSSLCTXFree:=TSSLCTXFree(RequiredProcedure(GSSLHandle, 'SSL_CTX_free'));
  GSSLCTXCtrl:=TSSLCTXCtrl(RequiredProcedure(GSSLHandle, 'SSL_CTX_ctrl'));
  GSSLCTXSetVerify:=TSSLCTXSetVerify(RequiredProcedure(GSSLHandle,
    'SSL_CTX_set_verify'));
  GSSLCTXLoadVerifyLocations:=TSSLCTXLoadVerifyLocations(
    RequiredProcedure(GSSLHandle, 'SSL_CTX_load_verify_locations'));
  GSSLCTXSetDefaultVerifyPaths:=TSSLCTXSetDefaultVerifyPaths(
    RequiredProcedure(GSSLHandle, 'SSL_CTX_set_default_verify_paths'));
  GSSLCTXSetDefaultPasswordCallback:=TSSLCTXSetDefaultPasswordCallback(
    RequiredProcedure(GSSLHandle, 'SSL_CTX_set_default_passwd_cb'));
  GSSLCTXSetDefaultPasswordCallbackUserData:=
    TSSLCTXSetDefaultPasswordCallbackUserData(
      RequiredProcedure(GSSLHandle,
        'SSL_CTX_set_default_passwd_cb_userdata'));
  GSSLCTXUseCertificateChainFile:=TSSLCTXUseCertificateChainFile(
    RequiredProcedure(GSSLHandle, 'SSL_CTX_use_certificate_chain_file'));
  GSSLCTXUsePrivateKeyFile:=TSSLCTXUsePrivateKeyFile(
    RequiredProcedure(GSSLHandle, 'SSL_CTX_use_PrivateKey_file'));
  GSSLCTXCheckPrivateKey:=TSSLCTXCheckPrivateKey(
    RequiredProcedure(GSSLHandle, 'SSL_CTX_check_private_key'));
  GSSLNew:=TSSLNew(RequiredProcedure(GSSLHandle, 'SSL_new'));
  GSSLFree:=TSSLFree(RequiredProcedure(GSSLHandle, 'SSL_free'));
  GSSLSetFD:=TSSLSetFD(RequiredProcedure(GSSLHandle, 'SSL_set_fd'));
  GSSLCtrl:=TSSLCtrl(RequiredProcedure(GSSLHandle, 'SSL_ctrl'));
  GSSLSet1Host:=TSSLSet1Host(RequiredProcedure(GSSLHandle, 'SSL_set1_host'));
  GSSLGet0Param:=TSSLGet0Param(RequiredProcedure(GSSLHandle,
    'SSL_get0_param'));
  GX509VerifyParamSet1IPAsc:=TX509VerifyParamSet1IPAsc(
    RequiredProcedure(GCryptoHandle, 'X509_VERIFY_PARAM_set1_ip_asc'));
  GSSLConnect:=TSSLHandshake(RequiredProcedure(GSSLHandle, 'SSL_connect'));
  GSSLAccept:=TSSLHandshake(RequiredProcedure(GSSLHandle, 'SSL_accept'));
  GSSLRead:=TSSLRead(RequiredProcedure(GSSLHandle, 'SSL_read'));
  GSSLWrite:=TSSLWrite(RequiredProcedure(GSSLHandle, 'SSL_write'));
  GSSLShutdown:=TSSLShutdown(RequiredProcedure(GSSLHandle, 'SSL_shutdown'));
  GSSLGetError:=TSSLGetError(RequiredProcedure(GSSLHandle, 'SSL_get_error'));
  GSSLGetVerifyResult:=TSSLGetVerifyResult(RequiredProcedure(GSSLHandle,
    'SSL_get_verify_result'));
  GERRGetError:=TERRGetError(RequiredProcedure(GCryptoHandle,
    'ERR_get_error'));
  GERRErrorStringN:=TERRErrorStringN(RequiredProcedure(GCryptoHandle,
    'ERR_error_string_n'));
end;

procedure EnsureOpenSSLLoaded;
begin
  EnterCriticalSection(GOpenSSLLock);
  try
    if GOpenSSLLoaded then
      Exit;
    try
      FpSignal(SIGPIPE, signalhandler(SIG_IGN));
      LoadOpenSSLProcedures;
      GOpenSSLLoaded:=True;
    except
      if GSSLHandle <> dynlibs.NilHandle then
      begin
        UnloadLibrary(GSSLHandle);
        GSSLHandle:=dynlibs.NilHandle;
      end;
      if GCryptoHandle <> dynlibs.NilHandle then
      begin
        UnloadLibrary(GCryptoHandle);
        GCryptoHandle:=dynlibs.NilHandle;
      end;
      raise;
    end;
  finally
    LeaveCriticalSection(GOpenSSLLock);
  end;
end;

function OpenSSLErrorText(const AOperation: string): string;
var
  ErrorCode: NativeUInt;
  ErrorBuffer: array[0..255] of AnsiChar;
begin
  ErrorCode:=GERRGetError();
  if ErrorCode = 0 then
    Exit(AOperation + ' failed');

  FillChar(ErrorBuffer, SizeOf(ErrorBuffer), 0);
  GERRErrorStringN(ErrorCode, @ErrorBuffer[0], SizeOf(ErrorBuffer));
  Result:=Format('%s failed: %s', [AOperation, string(ErrorBuffer)]);
end;

procedure RaiseOpenSSLError(const AOperation: string);
begin
  raise ERtmpTransportError.Create(OpenSSLErrorText(AOperation));
end;

function NativeAccess(const AConnection: IRtmpConnection):
  IRtmpNativeConnectionAccess;
begin
  if NOT Supports(AConnection, IRtmpNativeConnectionAccess, Result) then
    raise ERtmpTransportError.Create(
      'OpenSSL TLS requires a native socket connection');
end;

function ConnectionSocket(const AConnection: IRtmpConnection): LongInt;
begin
  Result:=LongInt(NativeAccess(AConnection).NativeHandle);
end;

procedure SetSocketTimeout(ASocket: LongInt; ATimeoutMS: Integer);
var
  TimeValue: TTimeVal;
begin
  if ATimeoutMS < 0 then
  begin
    TimeValue.tv_sec:=0;
    TimeValue.tv_usec:=0;
  end
  else
  begin
    TimeValue.tv_sec:=ATimeoutMS DIV 1000;
    TimeValue.tv_usec:=(ATimeoutMS MOD 1000) * 1000;
  end;
  fpSetSockOpt(ASocket, SOL_SOCKET, SO_RCVTIMEO, @TimeValue,
    SizeOf(TimeValue));
  fpSetSockOpt(ASocket, SOL_SOCKET, SO_SNDTIMEO, @TimeValue,
    SizeOf(TimeValue));
end;

function IsSocketTimeoutError: Boolean;
var
  ErrorCode: Integer;
begin
  ErrorCode:=fpGetErrno;
  Result:=(ErrorCode = ESysEAGAIN) OR (ErrorCode = ESysEWOULDBLOCK) OR
    (ErrorCode = ESysEINTR);
end;

function IsNumericIPv4(const AValue: string): Boolean;
var
  DotCount: Integer;
  I: Integer;
begin
  Result:=AValue <> '';
  DotCount:=0;
  for I:=1 to Length(AValue) do
  begin
    if AValue[I] = '.' then
      Inc(DotCount)
    else if NOT CharInSet(AValue[I], ['0'..'9']) then
      Exit(False);
  end;
  Result:=Result AND (DotCount = 3);
end;

function MinimumProtocolValue(AVersion: TRtmpTlsVersion): Integer;
begin
  case AVersion of
    tlsVersion13: Result:=TLS1_3_VERSION;
    else Result:=TLS1_2_VERSION;
  end;
end;

procedure ConfigureMinimumVersion(AContext: PSSL_CTX;
  AVersion: TRtmpTlsVersion);
begin
  if GSSLCTXCtrl(AContext, SSL_CTRL_SET_MIN_PROTO_VERSION,
    MinimumProtocolValue(AVersion), nil) <> 1 then
    RaiseOpenSSLError('setting minimum TLS version');
end;

function OptionalPath(const AValue: string; out AEncoded: UTF8String): PAnsiChar;
begin
  AEncoded:=UTF8Encode(AValue);
  if AEncoded = '' then
    Result:=nil
  else
    Result:=PAnsiChar(AEncoded);
end;

procedure ConfigureTrust(AContext: PSSL_CTX; const ACAFile,
  ACAPath: string);
var
  CAFileUtf8: UTF8String;
  CAPathUtf8: UTF8String;
begin
  if (ACAFile <> '') OR (ACAPath <> '') then
  begin
    if GSSLCTXLoadVerifyLocations(AContext,
      OptionalPath(ACAFile, CAFileUtf8), OptionalPath(ACAPath, CAPathUtf8)) <> 1 then
      RaiseOpenSSLError('loading TLS trust locations');
  end
  else if GSSLCTXSetDefaultVerifyPaths(AContext) <> 1 then
    RaiseOpenSSLError('loading system TLS trust locations');
end;

function OpenSSLPasswordCallback(ABuffer: PAnsiChar; ASize,
  AReadWriteFlag: Integer; AUserData: Pointer): Integer; cdecl;
var
  PasswordLength: Integer;
begin
  Result:=0;
  if (ABuffer = nil) OR (ASize <= 0) OR (AUserData = nil) then
    Exit;
  PasswordLength:=StrLen(PAnsiChar(AUserData));
  if PasswordLength >= ASize then
    PasswordLength:=ASize - 1;
  if PasswordLength > 0 then
    Move(AUserData^, ABuffer^, PasswordLength);
  ABuffer[PasswordLength]:=#0;
  Result:=PasswordLength;
end;

procedure ConfigureCertificate(AContext: PSSL_CTX;
  const ACertificateFile, APrivateKeyFile, ACertificatePassword: string;
  ARequired: Boolean);
var
  CertificateUtf8: UTF8String;
  PasswordUtf8: UTF8String;
  PrivateKeyUtf8: UTF8String;
begin
  if (ACertificateFile = '') AND (APrivateKeyFile = '') AND NOT ARequired then
    Exit;
  if (ACertificateFile = '') OR (APrivateKeyFile = '') then
    raise ERtmpTransportError.Create(
      'Both TLS certificate and private-key files are required');
  CertificateUtf8:=UTF8Encode(ACertificateFile);
  PrivateKeyUtf8:=UTF8Encode(APrivateKeyFile);
  PasswordUtf8:=UTF8Encode(ACertificatePassword);
  if GSSLCTXUseCertificateChainFile(AContext,
    PAnsiChar(CertificateUtf8)) <> 1 then
    RaiseOpenSSLError('loading TLS certificate chain');
  if PasswordUtf8 <> '' then
  begin
    GSSLCTXSetDefaultPasswordCallback(AContext, OpenSSLPasswordCallback);
    GSSLCTXSetDefaultPasswordCallbackUserData(AContext,
      PAnsiChar(PasswordUtf8));
  end;
  try
    if GSSLCTXUsePrivateKeyFile(AContext, PAnsiChar(PrivateKeyUtf8),
      SSL_FILETYPE_PEM) <> 1 then
      RaiseOpenSSLError('loading TLS private key');
  finally
    if PasswordUtf8 <> '' then
    begin
      GSSLCTXSetDefaultPasswordCallbackUserData(AContext, nil);
      GSSLCTXSetDefaultPasswordCallback(AContext, nil);
      FillChar(PasswordUtf8[1], Length(PasswordUtf8), 0);
    end;
  end;
  if GSSLCTXCheckPrivateKey(AContext) <> 1 then
    RaiseOpenSSLError('checking TLS private key');
end;

function CreateClientContext(const AOptions: TRtmpTlsClientOptions): PSSL_CTX;
begin
  Result:=GSSLCTXNew(GTlsClientMethod());
  if Result = nil then
    RaiseOpenSSLError('creating OpenSSL client context');
  try
    ConfigureMinimumVersion(Result, AOptions.MinimumVersion);
    if AOptions.VerifyPeer then
    begin
      GSSLCTXSetVerify(Result, SSL_VERIFY_PEER, nil);
      ConfigureTrust(Result, AOptions.CAFile, AOptions.CAPath);
    end
    else
      GSSLCTXSetVerify(Result, SSL_VERIFY_NONE, nil);
    ConfigureCertificate(Result, AOptions.CertificateFile,
      AOptions.PrivateKeyFile, AOptions.CertificatePassword, False);
  except
    GSSLCTXFree(Result);
    Result:=nil;
    raise;
  end;
end;

function CreateServerContext(const AOptions: TRtmpTlsServerOptions): PSSL_CTX;
var
  VerifyMode: Integer;
begin
  Result:=GSSLCTXNew(GTlsServerMethod());
  if Result = nil then
    RaiseOpenSSLError('creating OpenSSL server context');
  try
    ConfigureMinimumVersion(Result, AOptions.MinimumVersion);
    ConfigureCertificate(Result, AOptions.CertificateFile,
      AOptions.PrivateKeyFile, AOptions.CertificatePassword, True);
    if AOptions.RequireClientCertificate then
    begin
      ConfigureTrust(Result, AOptions.CAFile, AOptions.CAPath);
      VerifyMode:=SSL_VERIFY_PEER OR SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
      GSSLCTXSetVerify(Result, VerifyMode, nil);
    end
    else
      GSSLCTXSetVerify(Result, SSL_VERIFY_NONE, nil);
  except
    GSSLCTXFree(Result);
    Result:=nil;
    raise;
  end;
end;

procedure ConfigureClientIdentity(ASSL: PSSL;
  const AOptions: TRtmpTlsClientOptions);
var
  HostUtf8: UTF8String;
  Param: PX509_VERIFY_PARAM;
begin
  HostUtf8:=UTF8Encode(AOptions.ServerName);
  if HostUtf8 = '' then
    raise ERtmpTransportError.Create(
      'TLS server name must not be empty');

  if NOT IsNumericIPv4(AOptions.ServerName) then
  begin
    if GSSLCtrl(ASSL, SSL_CTRL_SET_TLSEXT_HOSTNAME,
      TLSEXT_NAMETYPE_HOST_NAME, PAnsiChar(HostUtf8)) <> 1 then
      RaiseOpenSSLError('setting TLS SNI server name');
  end;

  if NOT AOptions.VerifyPeer then
    Exit;
  if IsNumericIPv4(AOptions.ServerName) then
  begin
    Param:=GSSLGet0Param(ASSL);
    if (Param = nil) OR
       (GX509VerifyParamSet1IPAsc(Param, PAnsiChar(HostUtf8)) <> 1) then
      RaiseOpenSSLError('setting TLS peer IP verification');
  end
  else if GSSLSet1Host(ASSL, PAnsiChar(HostUtf8)) <> 1 then
    RaiseOpenSSLError('setting TLS peer hostname verification');
end;

procedure RunHandshake(ASSL: PSSL; AServer: Boolean;
  ASocket, ATimeoutMS: Integer);
var
  ErrorCode: Integer;
  HandshakeResult: Integer;
begin
  SetSocketTimeout(ASocket, ATimeoutMS);
  if AServer then
    HandshakeResult:=GSSLAccept(ASSL)
  else
    HandshakeResult:=GSSLConnect(ASSL);
  if HandshakeResult = 1 then
    Exit;

  ErrorCode:=GSSLGetError(ASSL, HandshakeResult);
  if ((ErrorCode = SSL_ERROR_WANT_READ) OR
      (ErrorCode = SSL_ERROR_WANT_WRITE) OR
      ((ErrorCode = SSL_ERROR_SYSCALL) AND IsSocketTimeoutError)) then
    raise ERtmpTransportError.Create('TLS handshake timed out');
  RaiseOpenSSLError('TLS handshake');
end;

constructor TRtmpOpenSSLConnection.Create(const AConnection: IRtmpConnection;
  AContext: PSSL_CTX; ASSL: PSSL);
begin
  inherited Create;
  FConnection:=AConnection;
  FContext:=AContext;
  FSSL:=ASSL;
end;

destructor TRtmpOpenSSLConnection.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TRtmpOpenSSLConnection.SocketHandle: LongInt;
begin
  Result:=ConnectionSocket(FConnection);
end;

procedure TRtmpOpenSSLConnection.Close;
begin
  if FSSL <> nil then
  begin
    SetSocketTimeout(SocketHandle, 1000);
    GSSLShutdown(FSSL);
    GSSLFree(FSSL);
    FSSL:=nil;
  end;
  if FContext <> nil then
  begin
    GSSLCTXFree(FContext);
    FContext:=nil;
  end;
  if FConnection <> nil then
  begin
    FConnection.Close;
    FConnection:=nil;
  end;
end;

function TRtmpOpenSSLConnection.GetConnected: Boolean;
begin
  Result:=(FSSL <> nil) AND (FConnection <> nil) AND
    FConnection.Connected;
end;

function TRtmpOpenSSLConnection.GetLocalEndpoint: TRtmpSocketEndpoint;
begin
  if FConnection = nil then
    Result:=Default(TRtmpSocketEndpoint)
  else
    Result:=FConnection.LocalEndpoint;
end;

function TRtmpOpenSSLConnection.GetRemoteEndpoint: TRtmpSocketEndpoint;
begin
  if FConnection = nil then
    Result:=Default(TRtmpSocketEndpoint)
  else
    Result:=FConnection.RemoteEndpoint;
end;

function TRtmpOpenSSLConnection.Receive(var ABuffer; ACount,
  ATimeoutMS: Integer): Integer;
var
  ErrorCode: Integer;
begin
  if NOT GetConnected then
    Exit(0);
  SetSocketTimeout(SocketHandle, ATimeoutMS);
  Result:=GSSLRead(FSSL, @ABuffer, ACount);
  if Result > 0 then
    Exit;

  ErrorCode:=GSSLGetError(FSSL, Result);
  if (ErrorCode = SSL_ERROR_WANT_READ) OR
     (ErrorCode = SSL_ERROR_WANT_WRITE) OR
     ((ErrorCode = SSL_ERROR_SYSCALL) AND IsSocketTimeoutError) then
    Exit(0);
  if (ErrorCode = SSL_ERROR_ZERO_RETURN) OR
     ((ErrorCode = SSL_ERROR_SYSCALL) AND (Result = 0)) then
  begin
    Close;
    Exit(0);
  end;
  Close;
  RaiseOpenSSLError('receiving TLS data');
end;

function TRtmpOpenSSLConnection.Send(const ABuffer; ACount,
  ATimeoutMS: Integer): Integer;
var
  ErrorCode: Integer;
begin
  if NOT GetConnected then
    Exit(0);
  SetSocketTimeout(SocketHandle, ATimeoutMS);
  Result:=GSSLWrite(FSSL, @ABuffer, ACount);
  if Result > 0 then
    Exit;

  ErrorCode:=GSSLGetError(FSSL, Result);
  if (ErrorCode = SSL_ERROR_WANT_READ) OR
     (ErrorCode = SSL_ERROR_WANT_WRITE) OR
     ((ErrorCode = SSL_ERROR_SYSCALL) AND IsSocketTimeoutError) then
    Exit(0);
  Close;
  RaiseOpenSSLError('sending TLS data');
end;

constructor TRtmpOpenSSLListener.Create(const AListener: IRtmpListener;
  AContext: PSSL_CTX);
begin
  inherited Create;
  FListener:=AListener;
  FContext:=AContext;
end;

destructor TRtmpOpenSSLListener.Destroy;
begin
  Close;
  if FContext <> nil then
  begin
    GSSLCTXFree(FContext);
    FContext:=nil;
  end;
  inherited Destroy;
end;

function TRtmpOpenSSLListener.Accept(ATimeoutMS: Integer): IRtmpConnection;
var
  Connection: IRtmpConnection;
  SSL: PSSL;
begin
  Result:=nil;
  Connection:=FListener.Accept(ATimeoutMS);
  if Connection = nil then
    Exit;

  SSL:=GSSLNew(FContext);
  if SSL = nil then
  begin
    Connection.Close;
    RaiseOpenSSLError('creating OpenSSL server connection');
  end;
  try
    if GSSLSetFD(SSL, ConnectionSocket(Connection)) <> 1 then
      RaiseOpenSSLError('attaching TLS server socket');
    RunHandshake(SSL, True, ConnectionSocket(Connection), ATimeoutMS);
    Result:=TRtmpOpenSSLConnection.Create(Connection, nil, SSL);
    SSL:=nil;
  finally
    if SSL <> nil then
    begin
      GSSLFree(SSL);
      Connection.Close;
    end;
  end;
end;

procedure TRtmpOpenSSLListener.Close;
begin
  if FListener <> nil then
  begin
    FListener.Close;
    FListener:=nil;
  end;
end;

function TRtmpOpenSSLListener.GetBoundEndpoint: TRtmpSocketEndpoint;
begin
  if FListener = nil then
    Result:=Default(TRtmpSocketEndpoint)
  else
    Result:=FListener.BoundEndpoint;
end;

function TRtmpOpenSSLListener.GetListening: Boolean;
begin
  Result:=(FListener <> nil) AND FListener.Listening;
end;

constructor TRtmpOpenSSLTransportFactory.Create;
begin
  inherited Create;
  FNativeFactory:=TRtmpNativeTransportFactory.Create;
end;

function TRtmpOpenSSLTransportFactory.CreateClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Result:=FNativeFactory.CreateClientConnection(ARemoteEndpoint,
    AConnectTimeoutMS);
end;

function TRtmpOpenSSLTransportFactory.CreateListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer): IRtmpListener;
begin
  Result:=FNativeFactory.CreateListener(ABindEndpoint, ABacklog);
end;

function TRtmpOpenSSLTransportFactory.CreateTlsClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  const AOptions: TRtmpTlsClientOptions;
  AConnectTimeoutMS: Integer): IRtmpConnection;
var
  Connection: IRtmpConnection;
  Context: PSSL_CTX;
  SSL: PSSL;
begin
  Result:=nil;
  EnsureOpenSSLLoaded;
  Context:=CreateClientContext(AOptions);
  SSL:=nil;
  Connection:=nil;
  try
    Connection:=FNativeFactory.CreateClientConnection(ARemoteEndpoint,
      AConnectTimeoutMS);
    SSL:=GSSLNew(Context);
    if SSL = nil then
      RaiseOpenSSLError('creating OpenSSL client connection');
    if GSSLSetFD(SSL, ConnectionSocket(Connection)) <> 1 then
      RaiseOpenSSLError('attaching TLS client socket');
    ConfigureClientIdentity(SSL, AOptions);
    RunHandshake(SSL, False, ConnectionSocket(Connection), AConnectTimeoutMS);
    if AOptions.VerifyPeer AND (GSSLGetVerifyResult(SSL) <> X509_V_OK) then
      raise ERtmpTransportError.CreateFmt(
        'TLS peer certificate verification failed with code %d',
        [GSSLGetVerifyResult(SSL)]);

    Result:=TRtmpOpenSSLConnection.Create(Connection, Context, SSL);
    Connection:=nil;
    Context:=nil;
    SSL:=nil;
  finally
    if SSL <> nil then
      GSSLFree(SSL);
    if Context <> nil then
      GSSLCTXFree(Context);
    if Connection <> nil then
      Connection.Close;
  end;
end;

function TRtmpOpenSSLTransportFactory.CreateTlsListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer;
  const AOptions: TRtmpTlsServerOptions): IRtmpListener;
var
  Context: PSSL_CTX;
  Listener: IRtmpListener;
begin
  EnsureOpenSSLLoaded;
  Context:=CreateServerContext(AOptions);
  Listener:=nil;
  try
    Listener:=FNativeFactory.CreateListener(ABindEndpoint, ABacklog);
    Result:=TRtmpOpenSSLListener.Create(Listener, Context);
    Listener:=nil;
    Context:=nil;
  finally
    if Listener <> nil then
      Listener.Close;
    if Context <> nil then
      GSSLCTXFree(Context);
  end;
end;

function TRtmpOpenSSLTransportFactory.Description: string;
begin
  Result:=FNativeFactory.Description;
end;

function TRtmpOpenSSLTransportFactory.TlsDescription: string;
begin
  Result:='system OpenSSL TLS transport';
end;

initialization
  InitCriticalSection(GOpenSSLLock);

finalization
  DoneCriticalSection(GOpenSSLLock);

{$ENDIF}

end.

unit TRTMP.Transport.TLS.SChannel;

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
  TRtmpSChannelTransportFactory = class(TInterfacedObject,
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

{$IFNDEF MSWINDOWS}

constructor TRtmpSChannelTransportFactory.Create;
begin
  inherited Create;
  FNativeFactory:=TRtmpNativeTransportFactory.Create;
end;

function TRtmpSChannelTransportFactory.CreateClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Result:=FNativeFactory.CreateClientConnection(ARemoteEndpoint,
    AConnectTimeoutMS);
end;

function TRtmpSChannelTransportFactory.CreateListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer): IRtmpListener;
begin
  Result:=FNativeFactory.CreateListener(ABindEndpoint, ABacklog);
end;

function TRtmpSChannelTransportFactory.CreateTlsClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  const AOptions: TRtmpTlsClientOptions;
  AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Result:=nil;
  raise ERtmpTransportError.Create(
    'The Schannel transport provider is available only on Windows');
end;

function TRtmpSChannelTransportFactory.CreateTlsListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer;
  const AOptions: TRtmpTlsServerOptions): IRtmpListener;
begin
  Result:=nil;
  raise ERtmpTransportError.Create(
    'The Schannel transport provider is available only on Windows');
end;

function TRtmpSChannelTransportFactory.Description: string;
begin
  Result:=FNativeFactory.Description;
end;

function TRtmpSChannelTransportFactory.TlsDescription: string;
begin
  Result:='Windows Schannel TLS transport unavailable on this platform';
end;

{$ELSE}

uses
  Classes,
  {$IFDEF FPC}
  Windows;
  {$ELSE}
  Winapi.Windows;
  {$ENDIF}

type
  TSecurityStatus = LongInt;

  TSecHandle = record
    Lower: NativeUInt;
    Upper: NativeUInt;
  end;
  PSecHandle = ^TSecHandle;

  TSecBuffer = record
    Size: Cardinal;
    BufferType: Cardinal;
    Buffer: Pointer;
  end;
  PSecBuffer = ^TSecBuffer;

  TSecBufferDesc = record
    Version: Cardinal;
    BufferCount: Cardinal;
    Buffers: PSecBuffer;
  end;
  PSecBufferDesc = ^TSecBufferDesc;

  TSecPkgContextStreamSizes = record
    HeaderSize: Cardinal;
    TrailerSize: Cardinal;
    MaximumMessageSize: Cardinal;
    BufferCount: Cardinal;
    BlockSize: Cardinal;
  end;

  TSecPkgContextConnectionInfo = record
    Protocol: Cardinal;
    CipherAlgorithm: Cardinal;
    CipherStrength: Cardinal;
    HashAlgorithm: Cardinal;
    HashStrength: Cardinal;
    ExchangeAlgorithm: Cardinal;
    ExchangeStrength: Cardinal;
  end;

  TTlsParameters = record
    AlpnIDCount: Cardinal;
    AlpnIDs: Pointer;
    DisabledProtocols: Cardinal;
    DisabledCryptoCount: Cardinal;
    DisabledCrypto: Pointer;
    Flags: Cardinal;
  end;
  PTlsParameters = ^TTlsParameters;

  TSChannelCredentials = record
    Version: Cardinal;
    CredentialFormat: Cardinal;
    CredentialCount: Cardinal;
    Credentials: Pointer;
    RootStore: Pointer;
    MapperCount: Cardinal;
    Mappers: Pointer;
    SessionLifespan: Cardinal;
    Flags: Cardinal;
    TlsParameterCount: Cardinal;
    TlsParameters: PTlsParameters;
  end;

  TCryptoDataBlob = record
    Size: Cardinal;
    Data: PByte;
  end;
  PCryptoDataBlob = ^TCryptoDataBlob;

  ISChannelCredential = interface(IInterface)
    ['{7CF99E41-0D1C-4D64-B68F-C12273FA861F}']
    function GetHandle: PSecHandle;
  end;

  TSChannelCredential = class(TInterfacedObject, ISChannelCredential)
  private
    FCertificate: Pointer;
    FCredential: TSecHandle;
    FCredentialValid: Boolean;
    FImportedKey: NativeUInt;
    FStore: Pointer;
  public
    constructor CreateClient(const AOptions: TRtmpTlsClientOptions);
    constructor CreateServer(const AOptions: TRtmpTlsServerOptions);
    destructor Destroy; override;
    function GetHandle: PSecHandle;
  end;

  TRtmpSChannelConnection = class(TInterfacedObject, IRtmpConnection)
  private
    FConnection: IRtmpConnection;
    FContext: TSecHandle;
    FContextValid: Boolean;
    FCredential: ISChannelCredential;
    FEncryptedInput: TBytes;
    FPlainInput: TBytes;
    FServer: Boolean;
    FServerName: string;
    FStreamSizes: TSecPkgContextStreamSizes;
    function PopPlain(var ABuffer; ACount: Integer): Integer;
    procedure RefreshStreamSizes;
  public
    constructor Create(const AConnection: IRtmpConnection;
      const ACredential: ISChannelCredential; const AContext: TSecHandle;
      AServer: Boolean; const AServerName: string;
      const AEncryptedInput: TBytes);
    destructor Destroy; override;
    procedure Close;
    function GetConnected: Boolean;
    function GetLocalEndpoint: TRtmpSocketEndpoint;
    function GetRemoteEndpoint: TRtmpSocketEndpoint;
    function Receive(var ABuffer; ACount: Integer; ATimeoutMS: Integer): Integer;
    function Send(const ABuffer; ACount: Integer; ATimeoutMS: Integer): Integer;
  end;

  TRtmpSChannelListener = class(TInterfacedObject, IRtmpListener)
  private
    FCredential: ISChannelCredential;
    FListener: IRtmpListener;
    FMinimumVersion: TRtmpTlsVersion;
  public
    constructor Create(const AListener: IRtmpListener;
      const ACredential: ISChannelCredential;
      AMinimumVersion: TRtmpTlsVersion);
    destructor Destroy; override;
    function Accept(ATimeoutMS: Integer): IRtmpConnection;
    procedure Close;
    function GetBoundEndpoint: TRtmpSocketEndpoint;
    function GetListening: Boolean;
  end;

const
  SEC_E_OK: TSecurityStatus = 0;
  SEC_I_CONTINUE_NEEDED: TSecurityStatus = $00090312;
  SEC_I_COMPLETE_NEEDED: TSecurityStatus = $00090313;
  SEC_I_COMPLETE_AND_CONTINUE: TSecurityStatus = $00090314;
  SEC_I_CONTEXT_EXPIRED: TSecurityStatus = $00090317;
  SEC_E_INCOMPLETE_MESSAGE: TSecurityStatus = TSecurityStatus($80090318);
  SEC_I_RENEGOTIATE: TSecurityStatus = $00090321;
  SECPKG_CRED_INBOUND = 1;
  SECPKG_CRED_OUTBOUND = 2;
  SECURITY_NATIVE_DREP = $10;
  SECBUFFER_VERSION = 0;
  SECBUFFER_EMPTY = 0;
  SECBUFFER_DATA = 1;
  SECBUFFER_TOKEN = 2;
  SECBUFFER_EXTRA = 5;
  SECBUFFER_STREAM_TRAILER = 6;
  SECBUFFER_STREAM_HEADER = 7;
  ISC_REQ_REPLAY_DETECT = $00000004;
  ISC_REQ_SEQUENCE_DETECT = $00000008;
  ISC_REQ_CONFIDENTIALITY = $00000010;
  ISC_REQ_ALLOCATE_MEMORY = $00000100;
  ISC_REQ_EXTENDED_ERROR = $00004000;
  ISC_REQ_STREAM = $00008000;
  ASC_REQ_REPLAY_DETECT = $00000004;
  ASC_REQ_SEQUENCE_DETECT = $00000008;
  ASC_REQ_CONFIDENTIALITY = $00000010;
  ASC_REQ_ALLOCATE_MEMORY = $00000100;
  ASC_REQ_EXTENDED_ERROR = $00008000;
  ASC_REQ_STREAM = $00010000;
  SECPKG_ATTR_STREAM_SIZES = 4;
  SECPKG_ATTR_CONNECTION_INFO = $5A;
  SCH_CREDENTIALS_VERSION = 5;
  SCH_CRED_MANUAL_CRED_VALIDATION = $00000008;
  SCH_CRED_NO_DEFAULT_CREDS = $00000010;
  SCH_CRED_AUTO_CRED_VALIDATION = $00000020;
  SCH_CRED_MEMORY_STORE_CERT = $00010000;
  SCH_USE_STRONG_CRYPTO = $00400000;
  SP_PROT_SSL2_SERVER = $00000004;
  SP_PROT_SSL2_CLIENT = $00000008;
  SP_PROT_SSL3_SERVER = $00000010;
  SP_PROT_SSL3_CLIENT = $00000020;
  SP_PROT_TLS1_SERVER = $00000040;
  SP_PROT_TLS1_CLIENT = $00000080;
  SP_PROT_TLS1_1_SERVER = $00000100;
  SP_PROT_TLS1_1_CLIENT = $00000200;
  SP_PROT_TLS1_2_SERVER = $00000400;
  SP_PROT_TLS1_2_CLIENT = $00000800;
  SP_PROT_TLS1_3_SERVER = $00001000;
  SP_PROT_TLS1_3_CLIENT = $00002000;
  PKCS12_INCLUDE_EXTENDED_PROPERTIES = $0010;
  PKCS12_ALWAYS_CNG_KSP = $00000200;
  CRYPT_ACQUIRE_SILENT_FLAG = $00000040;
  CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG = $00040000;
  CERT_NCRYPT_KEY_SPEC = $FFFFFFFF;
  CERT_FIND_HAS_PRIVATE_KEY = $00150000;
  X509_ASN_ENCODING = $00000001;
  PKCS_7_ASN_ENCODING = $00010000;
  UNISP_NAME = 'Microsoft Unified Security Protocol Provider';

function AcquireCredentialsHandleW(APrincipal, APackageName: PWideChar;
  ACredentialUse: Cardinal; ALogonID, AAuthData, AGetKeyFunction,
  AGetKeyArgument: Pointer; ACredential: PSecHandle;
  AExpiry: Pointer): TSecurityStatus; stdcall; external 'secur32.dll';
function FreeCredentialsHandle(ACredential: PSecHandle): TSecurityStatus;
  stdcall; external 'secur32.dll';
function InitializeSecurityContextW(ACredential, AContext: PSecHandle;
  ATargetName: PWideChar; AContextRequirements, AReserved1,
  ADataRepresentation: Cardinal; AInput: PSecBufferDesc; AReserved2: Cardinal;
  ANewContext: PSecHandle; AOutput: PSecBufferDesc; AContextAttributes: PCardinal;
  AExpiry: Pointer): TSecurityStatus; stdcall; external 'secur32.dll';
function AcceptSecurityContext(ACredential, AContext: PSecHandle;
  AInput: PSecBufferDesc; AContextRequirements,
  ADataRepresentation: Cardinal; ANewContext: PSecHandle;
  AOutput: PSecBufferDesc; AContextAttributes: PCardinal;
  AExpiry: Pointer): TSecurityStatus; stdcall; external 'secur32.dll';
function CompleteAuthToken(AContext: PSecHandle;
  AToken: PSecBufferDesc): TSecurityStatus; stdcall; external 'secur32.dll';
function DeleteSecurityContext(AContext: PSecHandle): TSecurityStatus;
  stdcall; external 'secur32.dll';
function QueryContextAttributesW(AContext: PSecHandle; AAttribute: Cardinal;
  ABuffer: Pointer): TSecurityStatus; stdcall; external 'secur32.dll';
function FreeContextBuffer(ABuffer: Pointer): TSecurityStatus;
  stdcall; external 'secur32.dll';
function EncryptMessage(AContext: PSecHandle; AQualityOfProtection: Cardinal;
  AMessage: PSecBufferDesc; ASequenceNumber: Cardinal): TSecurityStatus;
  stdcall; external 'secur32.dll';
function DecryptMessage(AContext: PSecHandle; AMessage: PSecBufferDesc;
  ASequenceNumber: Cardinal; AQualityOfProtection: PCardinal): TSecurityStatus;
  stdcall; external 'secur32.dll';
function PFXImportCertStore(APFX: PCryptoDataBlob; APassword: PWideChar;
  AFlags: Cardinal): Pointer; stdcall; external 'crypt32.dll';
function CertFindCertificateInStore(AStore: Pointer; AEncodingType,
  AFindFlags, AFindType: Cardinal; AFindParameter,
  APreviousContext: Pointer): Pointer; stdcall; external 'crypt32.dll';
function CertFreeCertificateContext(ACertificate: Pointer): BOOL;
  stdcall; external 'crypt32.dll';
function CertCloseStore(AStore: Pointer; AFlags: Cardinal): BOOL;
  stdcall; external 'crypt32.dll';
function CryptAcquireCertificatePrivateKey(ACertificate: Pointer;
  AFlags: Cardinal; AParameters: Pointer; out AKey: NativeUInt;
  out AKeySpec: Cardinal; out ACallerMustFree: BOOL): BOOL;
  stdcall; external 'crypt32.dll';
function NCryptDeleteKey(AKey: NativeUInt; AFlags: Cardinal): LongInt;
  stdcall; external 'ncrypt.dll';
function NCryptFreeObject(AObject: NativeUInt): LongInt;
  stdcall; external 'ncrypt.dll';

function SChannelStatusText(const AOperation: string;
  AStatus: TSecurityStatus): string;
var
  MessageText: string;
begin
  MessageText:=SysErrorMessage(Cardinal(AStatus));
  if MessageText = '' then
    Result:=Format('%s failed with Schannel status 0x%.8x',
      [AOperation, Cardinal(AStatus)])
  else
    Result:=Format('%s failed with Schannel status 0x%.8x: %s',
      [AOperation, Cardinal(AStatus), MessageText]);
end;

procedure CheckSChannelStatus(const AOperation: string;
  AStatus: TSecurityStatus);
begin
  if AStatus <> SEC_E_OK then
    raise ERtmpTransportError.Create(SChannelStatusText(AOperation, AStatus));
end;

function ReadBinaryFile(const AFileName: string): TBytes;
var
  Stream: TFileStream;
begin
  Stream:=TFileStream.Create(AFileName, fmOpenRead OR fmShareDenyWrite);
  try
    if Stream.Size > MaxInt then
      raise ERtmpTransportError.Create('TLS certificate file is too large');
    SetLength(Result, Integer(Stream.Size));
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure LoadPFXCertificate(const AFileName, APassword: string;
  out AStore, ACertificate: Pointer; out AKey: NativeUInt);
var
  Blob: TCryptoDataBlob;
  CallerMustFree: BOOL;
  FileBytes: TBytes;
  KeySpec: Cardinal;
  Password: UnicodeString;
begin
  AStore:=nil;
  ACertificate:=nil;
  AKey:=0;
  FileBytes:=ReadBinaryFile(AFileName);
  if Length(FileBytes) = 0 then
    raise ERtmpTransportError.Create('TLS PFX certificate file is empty');

  Blob.Size:=Length(FileBytes);
  Blob.Data:=@FileBytes[0];
  Password:=UnicodeString(APassword);
  AStore:=PFXImportCertStore(@Blob, PWideChar(Password),
    PKCS12_INCLUDE_EXTENDED_PROPERTIES OR PKCS12_ALWAYS_CNG_KSP);
  if AStore = nil then
    raise ERtmpTransportError.CreateFmt('Could not import TLS PFX file: %s',
      [SysErrorMessage(GetLastError)]);

  ACertificate:=CertFindCertificateInStore(AStore,
    X509_ASN_ENCODING OR PKCS_7_ASN_ENCODING, 0,
    CERT_FIND_HAS_PRIVATE_KEY, nil, nil);
  if ACertificate = nil then
  begin
    CertCloseStore(AStore, 0);
    AStore:=nil;
    raise ERtmpTransportError.Create(
      'TLS PFX file contains no certificate with a private key');
  end;

  CallerMustFree:=False;
  KeySpec:=0;
  if NOT CryptAcquireCertificatePrivateKey(ACertificate,
    CRYPT_ACQUIRE_SILENT_FLAG OR CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG, nil,
    AKey, KeySpec, CallerMustFree) OR (KeySpec <> CERT_NCRYPT_KEY_SPEC) then
  begin
    CertFreeCertificateContext(ACertificate);
    CertCloseStore(AStore, 0);
    ACertificate:=nil;
    AStore:=nil;
    AKey:=0;
    raise ERtmpTransportError.Create(
      'Could not acquire the CNG private key imported from the TLS PFX file');
  end;
end;

procedure DeleteImportedKey(var AKey: NativeUInt;
  ARaiseOnFailure: Boolean = False);
var
  Status: LongInt;
begin
  if AKey = 0 then
    Exit;
  Status:=NCryptDeleteKey(AKey, 0);
  if Status <> 0 then
    NCryptFreeObject(AKey);
  AKey:=0;
  if (Status <> 0) AND ARaiseOnFailure then
    raise ERtmpTransportError.CreateFmt(
      'Could not delete temporary CNG TLS private key: 0x%.8x',
      [Cardinal(Status)]);
end;

function DisabledProtocols(AServer: Boolean;
  AMinimumVersion: TRtmpTlsVersion): Cardinal;
begin
  if AServer then
    Result:=SP_PROT_SSL2_SERVER OR SP_PROT_SSL3_SERVER OR
      SP_PROT_TLS1_SERVER OR SP_PROT_TLS1_1_SERVER
  else
    Result:=SP_PROT_SSL2_CLIENT OR SP_PROT_SSL3_CLIENT OR
      SP_PROT_TLS1_CLIENT OR SP_PROT_TLS1_1_CLIENT;
  if AMinimumVersion = tlsVersion13 then
  begin
    if AServer then
      Result:=Result OR SP_PROT_TLS1_2_SERVER
    else
      Result:=Result OR SP_PROT_TLS1_2_CLIENT;
  end;
end;

procedure InitializeCredential(out ACredential: TSecHandle;
  out ACredentialValid: Boolean; AServer, AVerifyPeer: Boolean;
  AMinimumVersion: TRtmpTlsVersion; ACertificate: Pointer);
var
  CertificateArray: Pointer;
  CredentialConfig: TSChannelCredentials;
  CredentialUse: Cardinal;
  Status: TSecurityStatus;
  TlsConfig: TTlsParameters;
begin
  FillChar(ACredential, SizeOf(ACredential), 0);
  ACredentialValid:=False;
  FillChar(TlsConfig, SizeOf(TlsConfig), 0);
  TlsConfig.DisabledProtocols:=DisabledProtocols(AServer, AMinimumVersion);

  FillChar(CredentialConfig, SizeOf(CredentialConfig), 0);
  CredentialConfig.Version:=SCH_CREDENTIALS_VERSION;
  CredentialConfig.Flags:=SCH_USE_STRONG_CRYPTO;
  CredentialConfig.TlsParameterCount:=1;
  CredentialConfig.TlsParameters:=@TlsConfig;
  if AServer then
    CredentialUse:=SECPKG_CRED_INBOUND
  else
  begin
    CredentialUse:=SECPKG_CRED_OUTBOUND;
    if AVerifyPeer then
      CredentialConfig.Flags:=CredentialConfig.Flags OR
        SCH_CRED_AUTO_CRED_VALIDATION
    else
      CredentialConfig.Flags:=CredentialConfig.Flags OR
        SCH_CRED_MANUAL_CRED_VALIDATION;
    if ACertificate = nil then
      CredentialConfig.Flags:=CredentialConfig.Flags OR
        SCH_CRED_NO_DEFAULT_CREDS;
  end;

  if ACertificate <> nil then
  begin
    CertificateArray:=ACertificate;
    CredentialConfig.CredentialCount:=1;
    CredentialConfig.Credentials:=@CertificateArray;
    CredentialConfig.Flags:=CredentialConfig.Flags OR
      SCH_CRED_MEMORY_STORE_CERT;
  end;

  Status:=AcquireCredentialsHandleW(nil, PWideChar(UnicodeString(UNISP_NAME)),
    CredentialUse, nil, @CredentialConfig, nil, nil, @ACredential, nil);
  CheckSChannelStatus('acquiring Schannel credentials', Status);
  ACredentialValid:=True;
end;

constructor TSChannelCredential.CreateClient(
  const AOptions: TRtmpTlsClientOptions);
begin
  inherited Create;
  FStore:=nil;
  FCertificate:=nil;
  FCredentialValid:=False;
  FImportedKey:=0;
  if (AOptions.CAFile <> '') OR (AOptions.CAPath <> '') then
    raise ERtmpTransportError.Create(
      'Schannel uses the Windows trust store; custom CA files are not yet supported');
  if AOptions.PrivateKeyFile <> '' then
    raise ERtmpTransportError.Create(
      'Schannel client certificates must be supplied as a PFX/P12 CertificateFile');
  if AOptions.CertificateFile <> '' then
    LoadPFXCertificate(AOptions.CertificateFile,
      AOptions.CertificatePassword, FStore, FCertificate, FImportedKey);
  try
    InitializeCredential(FCredential, FCredentialValid, False,
      AOptions.VerifyPeer, AOptions.MinimumVersion, FCertificate);
    DeleteImportedKey(FImportedKey, True);
  except
    DeleteImportedKey(FImportedKey, True);
    if FCertificate <> nil then
      CertFreeCertificateContext(FCertificate);
    if FStore <> nil then
      CertCloseStore(FStore, 0);
    FCertificate:=nil;
    FStore:=nil;
    raise;
  end;
end;

constructor TSChannelCredential.CreateServer(
  const AOptions: TRtmpTlsServerOptions);
begin
  inherited Create;
  FStore:=nil;
  FCertificate:=nil;
  FCredentialValid:=False;
  FImportedKey:=0;
  if AOptions.RequireClientCertificate then
    raise ERtmpTransportError.Create(
      'Schannel mutual TLS validation is not yet supported');
  if (AOptions.CAFile <> '') OR (AOptions.CAPath <> '') then
    raise ERtmpTransportError.Create(
      'Schannel uses the Windows trust store; custom CA files are not yet supported');
  if AOptions.PrivateKeyFile <> '' then
    raise ERtmpTransportError.Create(
      'Schannel server certificates must be supplied as a PFX/P12 CertificateFile');
  if AOptions.CertificateFile = '' then
    raise ERtmpTransportError.Create(
      'Schannel server TLS requires a PFX/P12 CertificateFile');

  LoadPFXCertificate(AOptions.CertificateFile,
    AOptions.CertificatePassword, FStore, FCertificate, FImportedKey);
  try
    InitializeCredential(FCredential, FCredentialValid, True, False,
      AOptions.MinimumVersion, FCertificate);
    DeleteImportedKey(FImportedKey);
  except
    DeleteImportedKey(FImportedKey);
    if FCertificate <> nil then
      CertFreeCertificateContext(FCertificate);
    if FStore <> nil then
      CertCloseStore(FStore, 0);
    FCertificate:=nil;
    FStore:=nil;
    raise;
  end;
end;

destructor TSChannelCredential.Destroy;
begin
  if FCredentialValid then
    FreeCredentialsHandle(@FCredential);
  DeleteImportedKey(FImportedKey);
  if FCertificate <> nil then
    CertFreeCertificateContext(FCertificate);
  if FStore <> nil then
    CertCloseStore(FStore, 0);
  inherited Destroy;
end;

function TSChannelCredential.GetHandle: PSecHandle;
begin
  Result:=@FCredential;
end;

function SendAll(const AConnection: IRtmpConnection; AData: Pointer;
  ACount, ATimeoutMS: Integer): Boolean;
var
  Offset: Integer;
  SentCount: Integer;
begin
  Offset:=0;
  while Offset < ACount do
  begin
    SentCount:=AConnection.Send(PByte(AData)[Offset], ACount - Offset,
      ATimeoutMS);
    if SentCount <= 0 then
      Exit(False);
    Inc(Offset, SentCount);
  end;
  Result:=True;
end;

function ReceiveMore(const AConnection: IRtmpConnection; var AData: TBytes;
  ATimeoutMS: Integer): Boolean;
var
  OldLength: Integer;
  ReadCount: Integer;
begin
  OldLength:=Length(AData);
  SetLength(AData, OldLength + 16384);
  ReadCount:=AConnection.Receive(AData[OldLength], 16384, ATimeoutMS);
  if ReadCount <= 0 then
  begin
    SetLength(AData, OldLength);
    Exit(False);
  end;
  SetLength(AData, OldLength + ReadCount);
  Result:=True;
end;

procedure KeepExtraBuffer(var AData: TBytes;
  const ABuffers: array of TSecBuffer);
var
  ExtraCount: Integer;
  I: Integer;
begin
  ExtraCount:=0;
  for I:=Low(ABuffers) to High(ABuffers) do
    if ABuffers[I].BufferType = SECBUFFER_EXTRA then
    begin
      ExtraCount:=ABuffers[I].Size;
      Break;
    end;
  if ExtraCount <= 0 then
  begin
    SetLength(AData, 0);
    Exit;
  end;
  if ExtraCount > Length(AData) then
    raise ERtmpTransportError.Create('Schannel returned invalid extra data');
  Move(AData[Length(AData) - ExtraCount], AData[0], ExtraCount);
  SetLength(AData, ExtraCount);
end;

procedure PerformSChannelHandshake(const AConnection: IRtmpConnection;
  const ACredential: ISChannelCredential; AServer: Boolean;
  const AServerName: string; var AContext: TSecHandle;
  var AContextValid: Boolean; var AInput: TBytes; ATimeoutMS: Integer);
var
  ContextAttributes: Cardinal;
  ContextPointer: PSecHandle;
  InputBuffers: array[0..1] of TSecBuffer;
  InputDescription: TSecBufferDesc;
  InputDescriptionPointer: PSecBufferDesc;
  OutputBuffer: TSecBuffer;
  OutputDescription: TSecBufferDesc;
  Status: TSecurityStatus;
  TargetName: UnicodeString;
begin
  TargetName:=UnicodeString(AServerName);
  repeat
    if AServer AND (Length(AInput) = 0) then
      if NOT ReceiveMore(AConnection, AInput, ATimeoutMS) then
        raise ERtmpTransportError.Create('Schannel server handshake timed out');

    FillChar(InputBuffers, SizeOf(InputBuffers), 0);
    FillChar(InputDescription, SizeOf(InputDescription), 0);
    if Length(AInput) > 0 then
    begin
      InputBuffers[0].Size:=Length(AInput);
      InputBuffers[0].BufferType:=SECBUFFER_TOKEN;
      InputBuffers[0].Buffer:=@AInput[0];
      InputBuffers[1].BufferType:=SECBUFFER_EMPTY;
      InputDescription.Version:=SECBUFFER_VERSION;
      InputDescription.BufferCount:=Length(InputBuffers);
      InputDescription.Buffers:=@InputBuffers[0];
      InputDescriptionPointer:=@InputDescription;
    end
    else
      InputDescriptionPointer:=nil;

    FillChar(OutputBuffer, SizeOf(OutputBuffer), 0);
    OutputBuffer.BufferType:=SECBUFFER_TOKEN;
    OutputDescription.Version:=SECBUFFER_VERSION;
    OutputDescription.BufferCount:=1;
    OutputDescription.Buffers:=@OutputBuffer;
    if AContextValid then
      ContextPointer:=@AContext
    else
      ContextPointer:=nil;

    if AServer then
      Status:=AcceptSecurityContext(ACredential.GetHandle, ContextPointer,
        InputDescriptionPointer, ASC_REQ_SEQUENCE_DETECT OR
        ASC_REQ_REPLAY_DETECT OR ASC_REQ_CONFIDENTIALITY OR
        ASC_REQ_ALLOCATE_MEMORY OR ASC_REQ_EXTENDED_ERROR OR ASC_REQ_STREAM,
        SECURITY_NATIVE_DREP, @AContext, @OutputDescription,
        @ContextAttributes, nil)
    else
      Status:=InitializeSecurityContextW(ACredential.GetHandle,
        ContextPointer, PWideChar(TargetName), ISC_REQ_SEQUENCE_DETECT OR
        ISC_REQ_REPLAY_DETECT OR ISC_REQ_CONFIDENTIALITY OR
        ISC_REQ_ALLOCATE_MEMORY OR ISC_REQ_EXTENDED_ERROR OR ISC_REQ_STREAM,
        0, SECURITY_NATIVE_DREP, InputDescriptionPointer, 0, @AContext,
        @OutputDescription, @ContextAttributes, nil);
    if Status <> SEC_E_INCOMPLETE_MESSAGE then
      AContextValid:=True;

    try
      if (Status = SEC_I_COMPLETE_NEEDED) OR
         (Status = SEC_I_COMPLETE_AND_CONTINUE) then
        CheckSChannelStatus('completing Schannel authentication token',
          CompleteAuthToken(@AContext, @OutputDescription));
      if (OutputBuffer.Buffer <> nil) AND (OutputBuffer.Size > 0) then
        if NOT SendAll(AConnection, OutputBuffer.Buffer, OutputBuffer.Size,
          ATimeoutMS) then
          raise ERtmpTransportError.Create('Sending Schannel handshake failed');
    finally
      if OutputBuffer.Buffer <> nil then
        FreeContextBuffer(OutputBuffer.Buffer);
    end;

    if Status = SEC_E_INCOMPLETE_MESSAGE then
    begin
      if NOT ReceiveMore(AConnection, AInput, ATimeoutMS) then
        raise ERtmpTransportError.Create('Schannel handshake timed out');
      Continue;
    end;

    if (Status = SEC_I_CONTINUE_NEEDED) OR
       (Status = SEC_I_COMPLETE_AND_CONTINUE) then
    begin
      KeepExtraBuffer(AInput, InputBuffers);
      if Length(AInput) = 0 then
        if NOT ReceiveMore(AConnection, AInput, ATimeoutMS) then
          raise ERtmpTransportError.Create('Schannel handshake timed out');
      Continue;
    end;

    if (Status = SEC_E_OK) OR (Status = SEC_I_COMPLETE_NEEDED) then
    begin
      KeepExtraBuffer(AInput, InputBuffers);
      Exit;
    end;
    raise ERtmpTransportError.Create(
      SChannelStatusText('Schannel handshake', Status));
  until False;
end;

procedure VerifyNegotiatedVersion(const AContext: TSecHandle;
  AMinimumVersion: TRtmpTlsVersion);
var
  ConnectionInfo: TSecPkgContextConnectionInfo;
  Status: TSecurityStatus;
begin
  FillChar(ConnectionInfo, SizeOf(ConnectionInfo), 0);
  Status:=QueryContextAttributesW(@AContext, SECPKG_ATTR_CONNECTION_INFO,
    @ConnectionInfo);
  CheckSChannelStatus('querying Schannel connection information', Status);
  if (AMinimumVersion = tlsVersion13) AND
     ((ConnectionInfo.Protocol AND
       (SP_PROT_TLS1_3_CLIENT OR SP_PROT_TLS1_3_SERVER)) = 0) then
    raise ERtmpTransportError.Create(
      'Schannel negotiated a protocol below required TLS 1.3');
end;

constructor TRtmpSChannelConnection.Create(
  const AConnection: IRtmpConnection;
  const ACredential: ISChannelCredential; const AContext: TSecHandle;
  AServer: Boolean; const AServerName: string;
  const AEncryptedInput: TBytes);
begin
  inherited Create;
  FConnection:=AConnection;
  FCredential:=ACredential;
  FContext:=AContext;
  FContextValid:=True;
  FServer:=AServer;
  FServerName:=AServerName;
  FEncryptedInput:=Copy(AEncryptedInput);
  FPlainInput:=nil;
  RefreshStreamSizes;
end;

destructor TRtmpSChannelConnection.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TRtmpSChannelConnection.Close;
begin
  if FContextValid then
  begin
    DeleteSecurityContext(@FContext);
    FContextValid:=False;
  end;
  if FConnection <> nil then
  begin
    FConnection.Close;
    FConnection:=nil;
  end;
  FCredential:=nil;
  FEncryptedInput:=nil;
  FPlainInput:=nil;
end;

function TRtmpSChannelConnection.GetConnected: Boolean;
begin
  Result:=FContextValid AND (FConnection <> nil) AND
    FConnection.Connected;
end;

function TRtmpSChannelConnection.GetLocalEndpoint: TRtmpSocketEndpoint;
begin
  if FConnection = nil then
    Result:=Default(TRtmpSocketEndpoint)
  else
    Result:=FConnection.LocalEndpoint;
end;

function TRtmpSChannelConnection.GetRemoteEndpoint: TRtmpSocketEndpoint;
begin
  if FConnection = nil then
    Result:=Default(TRtmpSocketEndpoint)
  else
    Result:=FConnection.RemoteEndpoint;
end;

procedure TRtmpSChannelConnection.RefreshStreamSizes;
begin
  FillChar(FStreamSizes, SizeOf(FStreamSizes), 0);
  CheckSChannelStatus('querying Schannel stream sizes',
    QueryContextAttributesW(@FContext, SECPKG_ATTR_STREAM_SIZES,
      @FStreamSizes));
end;

function TRtmpSChannelConnection.PopPlain(var ABuffer;
  ACount: Integer): Integer;
begin
  Result:=Length(FPlainInput);
  if Result > ACount then
    Result:=ACount;
  if Result <= 0 then
    Exit;
  Move(FPlainInput[0], ABuffer, Result);
  if Result < Length(FPlainInput) then
    Move(FPlainInput[Result], FPlainInput[0], Length(FPlainInput) - Result);
  SetLength(FPlainInput, Length(FPlainInput) - Result);
end;

function TRtmpSChannelConnection.Receive(var ABuffer; ACount,
  ATimeoutMS: Integer): Integer;
var
  Buffers: array[0..3] of TSecBuffer;
  Description: TSecBufferDesc;
  I: Integer;
  QualityOfProtection: Cardinal;
  Status: TSecurityStatus;
begin
  Result:=PopPlain(ABuffer, ACount);
  if Result > 0 then
    Exit;
  if NOT GetConnected then
    Exit(0);

  repeat
    if Length(FEncryptedInput) = 0 then
      if NOT ReceiveMore(FConnection, FEncryptedInput, ATimeoutMS) then
        Exit(0);

    FillChar(Buffers, SizeOf(Buffers), 0);
    Buffers[0].Size:=Length(FEncryptedInput);
    Buffers[0].BufferType:=SECBUFFER_DATA;
    Buffers[0].Buffer:=@FEncryptedInput[0];
    for I:=1 to High(Buffers) do
      Buffers[I].BufferType:=SECBUFFER_EMPTY;
    Description.Version:=SECBUFFER_VERSION;
    Description.BufferCount:=Length(Buffers);
    Description.Buffers:=@Buffers[0];
    QualityOfProtection:=0;
    Status:=DecryptMessage(@FContext, @Description, 0,
      @QualityOfProtection);

    if Status = SEC_E_INCOMPLETE_MESSAGE then
    begin
      if NOT ReceiveMore(FConnection, FEncryptedInput, ATimeoutMS) then
        Exit(0);
      Continue;
    end;
    if Status = SEC_I_CONTEXT_EXPIRED then
    begin
      Close;
      Exit(0);
    end;
    if Status = SEC_I_RENEGOTIATE then
    begin
      KeepExtraBuffer(FEncryptedInput, Buffers);
      PerformSChannelHandshake(FConnection, FCredential, FServer,
        FServerName, FContext, FContextValid, FEncryptedInput, ATimeoutMS);
      RefreshStreamSizes;
      Continue;
    end;
    if Status <> SEC_E_OK then
    begin
      Close;
      raise ERtmpTransportError.Create(
        SChannelStatusText('decrypting TLS data', Status));
    end;

    FPlainInput:=nil;
    for I:=Low(Buffers) to High(Buffers) do
      if (Buffers[I].BufferType = SECBUFFER_DATA) AND
         (Buffers[I].Size > 0) then
      begin
        SetLength(FPlainInput, Buffers[I].Size);
        Move(Buffers[I].Buffer^, FPlainInput[0], Buffers[I].Size);
        Break;
      end;
    KeepExtraBuffer(FEncryptedInput, Buffers);
    Result:=PopPlain(ABuffer, ACount);
    if Result > 0 then
      Exit;
  until False;
end;

function TRtmpSChannelConnection.Send(const ABuffer; ACount,
  ATimeoutMS: Integer): Integer;
var
  Buffers: array[0..3] of TSecBuffer;
  Description: TSecBufferDesc;
  Encrypted: TBytes;
  PlainCount: Integer;
  Status: TSecurityStatus;
begin
  if NOT GetConnected OR (ACount <= 0) then
    Exit(0);
  PlainCount:=ACount;
  if Cardinal(PlainCount) > FStreamSizes.MaximumMessageSize then
    PlainCount:=Integer(FStreamSizes.MaximumMessageSize);
  SetLength(Encrypted, Integer(FStreamSizes.HeaderSize) + PlainCount +
    Integer(FStreamSizes.TrailerSize));
  Move(ABuffer, Encrypted[Integer(FStreamSizes.HeaderSize)], PlainCount);

  FillChar(Buffers, SizeOf(Buffers), 0);
  Buffers[0].Size:=FStreamSizes.HeaderSize;
  Buffers[0].BufferType:=SECBUFFER_STREAM_HEADER;
  Buffers[0].Buffer:=@Encrypted[0];
  Buffers[1].Size:=PlainCount;
  Buffers[1].BufferType:=SECBUFFER_DATA;
  Buffers[1].Buffer:=@Encrypted[FStreamSizes.HeaderSize];
  Buffers[2].Size:=FStreamSizes.TrailerSize;
  Buffers[2].BufferType:=SECBUFFER_STREAM_TRAILER;
  Buffers[2].Buffer:=@Encrypted[Integer(FStreamSizes.HeaderSize) + PlainCount];
  Buffers[3].BufferType:=SECBUFFER_EMPTY;
  Description.Version:=SECBUFFER_VERSION;
  Description.BufferCount:=Length(Buffers);
  Description.Buffers:=@Buffers[0];

  Status:=EncryptMessage(@FContext, 0, @Description, 0);
  if Status <> SEC_E_OK then
  begin
    Close;
    raise ERtmpTransportError.Create(
      SChannelStatusText('encrypting TLS data', Status));
  end;
  if NOT SendAll(FConnection, @Encrypted[0], Buffers[0].Size +
    Buffers[1].Size + Buffers[2].Size, ATimeoutMS) then
    Exit(0);
  Result:=PlainCount;
end;

constructor TRtmpSChannelListener.Create(const AListener: IRtmpListener;
  const ACredential: ISChannelCredential;
  AMinimumVersion: TRtmpTlsVersion);
begin
  inherited Create;
  FListener:=AListener;
  FCredential:=ACredential;
  FMinimumVersion:=AMinimumVersion;
end;

destructor TRtmpSChannelListener.Destroy;
begin
  Close;
  FCredential:=nil;
  inherited Destroy;
end;

function TRtmpSChannelListener.Accept(ATimeoutMS: Integer): IRtmpConnection;
var
  Connection: IRtmpConnection;
  Context: TSecHandle;
  ContextValid: Boolean;
  Input: TBytes;
begin
  Result:=nil;
  Connection:=FListener.Accept(ATimeoutMS);
  if Connection = nil then
    Exit;
  FillChar(Context, SizeOf(Context), 0);
  ContextValid:=False;
  Input:=nil;
  try
    PerformSChannelHandshake(Connection, FCredential, True, '', Context,
      ContextValid, Input, ATimeoutMS);
    VerifyNegotiatedVersion(Context, FMinimumVersion);
    Result:=TRtmpSChannelConnection.Create(Connection, FCredential, Context,
      True, '', Input);
    Connection:=nil;
    ContextValid:=False;
  finally
    if ContextValid then
      DeleteSecurityContext(@Context);
    if Connection <> nil then
      Connection.Close;
  end;
end;

procedure TRtmpSChannelListener.Close;
begin
  if FListener <> nil then
  begin
    FListener.Close;
    FListener:=nil;
  end;
end;

function TRtmpSChannelListener.GetBoundEndpoint: TRtmpSocketEndpoint;
begin
  if FListener = nil then
    Result:=Default(TRtmpSocketEndpoint)
  else
    Result:=FListener.BoundEndpoint;
end;

function TRtmpSChannelListener.GetListening: Boolean;
begin
  Result:=(FListener <> nil) AND FListener.Listening;
end;

constructor TRtmpSChannelTransportFactory.Create;
begin
  inherited Create;
  FNativeFactory:=TRtmpNativeTransportFactory.Create;
end;

function TRtmpSChannelTransportFactory.CreateClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Result:=FNativeFactory.CreateClientConnection(ARemoteEndpoint,
    AConnectTimeoutMS);
end;

function TRtmpSChannelTransportFactory.CreateListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer): IRtmpListener;
begin
  Result:=FNativeFactory.CreateListener(ABindEndpoint, ABacklog);
end;

function TRtmpSChannelTransportFactory.CreateTlsClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint;
  const AOptions: TRtmpTlsClientOptions;
  AConnectTimeoutMS: Integer): IRtmpConnection;
var
  Connection: IRtmpConnection;
  Context: TSecHandle;
  ContextValid: Boolean;
  Credential: ISChannelCredential;
  Input: TBytes;
begin
  if AOptions.ServerName = '' then
    raise ERtmpTransportError.Create('TLS server name must not be empty');
  Credential:=TSChannelCredential.CreateClient(AOptions);
  Connection:=FNativeFactory.CreateClientConnection(ARemoteEndpoint,
    AConnectTimeoutMS);
  FillChar(Context, SizeOf(Context), 0);
  ContextValid:=False;
  Input:=nil;
  try
    PerformSChannelHandshake(Connection, Credential, False,
      AOptions.ServerName, Context, ContextValid, Input, AConnectTimeoutMS);
    VerifyNegotiatedVersion(Context, AOptions.MinimumVersion);
    Result:=TRtmpSChannelConnection.Create(Connection, Credential, Context,
      False, AOptions.ServerName, Input);
    Connection:=nil;
    Credential:=nil;
    ContextValid:=False;
  finally
    if ContextValid then
      DeleteSecurityContext(@Context);
    if Connection <> nil then
      Connection.Close;
  end;
end;

function TRtmpSChannelTransportFactory.CreateTlsListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer;
  const AOptions: TRtmpTlsServerOptions): IRtmpListener;
var
  Credential: ISChannelCredential;
  Listener: IRtmpListener;
begin
  Credential:=TSChannelCredential.CreateServer(AOptions);
  Listener:=FNativeFactory.CreateListener(ABindEndpoint, ABacklog);
  Result:=TRtmpSChannelListener.Create(Listener, Credential,
    AOptions.MinimumVersion);
end;

function TRtmpSChannelTransportFactory.Description: string;
begin
  Result:=FNativeFactory.Description;
end;

function TRtmpSChannelTransportFactory.TlsDescription: string;
begin
  Result:='Windows Schannel TLS transport';
end;

{$ENDIF}

end.

unit TRTMP.RTMP.Server.Session;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  SyncObjs,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Auth,
  TRTMP.RTMP.Protocol.Chunk,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Media.Packet,
  TRTMP.Transport,
  TRTMP.RTMP.Types;

type
  TRtmpServerSession = class;

  TRtmpSessionPacketEvent = procedure(Session: TRtmpServerSession;
    Packet: TRtmpPacket) of object;
  TRtmpSessionLogEvent = procedure(Session: TRtmpServerSession;
    ALevel: TRtmpLogLevel; const ACategory, AMessage: string) of object;

  TRtmpServerSession = class
  private
    FLock: TCriticalSection;
    FRemoteAddress: string;
    FRemotePort: Word;
    FAppName: string;
    FAuthorizer: IRtmpServerAuthorizer;
    FTcUrl: string;
    FFlashVersion: string;
    FBuffer: TRtmpCircularBuffer;
    FHasActivePublish: Boolean;
    FHasActivePlay: Boolean;
    FLastPublishedStreamName: string;
    FStreamName: string;
    FEnhancedCodecs: string;
    FEnhancedCapabilities: UInt32;
    FSupportedEnhancedCapabilities: UInt32;
    FStartedAt: TRtmpTick;
    FHandshakeCompleted: Boolean;
    FInChunkSize: UInt32;
    FOutChunkSize: UInt32;
    FAckWindowSize: UInt32;
    FMessageStreamID: UInt32;
    FState: TRtmpSessionState;
    FStats: TRtmpSessionStats;
    FConnection: IRtmpConnection;
    FReassembler: TRtmpChunkReassembler;
    FSequenceNo: UInt64;
    FActiveLogHandler: TRtmpSessionLogEvent;
    FRawBytesReceived: UInt64;
    FNextAckAt: UInt64;
    FPlayBootstrapPending: Boolean;
    FPlayBufferLengthMS: UInt32;
    FPlaySequenceNo: UInt64;
    FMinLogLevel: TRtmpLogLevel;
    FMaxInChunkSize: Integer;
    FMaxInMessageSize: Integer;
    FMaxInChunkStreams: Integer;
    FProtocolDefaultsSent: Boolean;
    FReconnectRequestDescription: string;
    FReconnectRequestPending: Boolean;
    FReconnectRequestTcUrl: string;
    FReadTimeoutMS: Integer;
    FWriteTimeoutMS: Integer;
    function GetStreamName: string;
    function StreamNameForLog: string;
    function IsLogEnabled(ALevel: TRtmpLogLevel): Boolean;
    procedure MaybeSendAck;
    procedure MaybeSendReconnectRequest;
    procedure NoteRawBytesReceived(ACount: Integer);
    procedure NoteMalformedMessage;
    procedure EmitLog(AOnLog: TRtmpSessionLogEvent; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    procedure ClearPlayState(AClearMessageStream: Boolean = False);
    function EnsureCommandState(const ACommandName: string;
      const AAllowedStates: array of TRtmpSessionState; ATransactionID: Double;
      AMessageStreamID: UInt32; const AErrorCode, ADescription: string;
      AOnLog: TRtmpSessionLogEvent): Boolean;
    function HandleChunkMessage(const AMessage: TRtmpChunkMessage;
      AOnPacket: TRtmpSessionPacketEvent; AOnLog: TRtmpSessionLogEvent): Boolean;
    function HandleCommandMessage(const AMessage: TRtmpChunkMessage;
      AOnLog: TRtmpSessionLogEvent): Boolean;
    function HandleUserControlMessage(const AMessage: TRtmpChunkMessage;
      AOnLog: TRtmpSessionLogEvent): Boolean;
    function PerformHandshake(AOnLog: TRtmpSessionLogEvent): Boolean;
    function ReadExact(ACount: Integer; out ABytes: TBytes): Boolean;
    procedure SendBuffer(ABuffer: Pointer; ACount: Integer);
    procedure SendBytes(const ABytes: TBytes);
    procedure SendCommandMessage(AChunkStreamID, AMessageStreamID: UInt32;
      const AValues: array of TObject);
    procedure SendCommandError(ATransactionID: Double; const ACode,
      ADescription: string);
    procedure SendConnectSuccess(ATransactionID: Double);
    procedure SendCreateStreamResult(ATransactionID: Double);
    procedure SendOnStatusError(AMessageStreamID: UInt32; const ACode,
      ADescription: string);
    procedure PumpPlayPackets(AOnLog: TRtmpSessionLogEvent);
    procedure SendProtocolDefaults;
    procedure SendPlayPacket(APacket: TRtmpPacket);
    procedure SendPlayReset;
    procedure SendPlayStart;
    procedure SendPublishStart;
    procedure SendRtmpMessage(AChunkStreamID, AMessageStreamID: UInt32;
      AMessageTypeID: Byte; ATimestamp: UInt32; const APayload: TBytes);
    procedure SendSetChunkSize(AChunkSize: UInt32);
    procedure SendSetPeerBandwidth(AWindowSize: UInt32; ALimitType: Byte);
    procedure SendAcknowledgement(ASequence: UInt32);
    procedure SendUserControl(AEventType: Word; AValue1: UInt32); overload;
    procedure SendUserControl(AEventType: Word; AValue1, AValue2: UInt32); overload;
    procedure SendUserControlStreamBegin(AStreamID: UInt32);
    procedure SendWindowAckSize(AWindowSize: UInt32);
    procedure SetMaxInChunkStreams(AValue: Integer);
    procedure SetMaxInMessageSize(AValue: Integer);
  public
    constructor Create(const AConnection: IRtmpConnection); overload;
    constructor Create(const ARemoteAddress: string; ARemotePort: Word); overload;
    destructor Destroy; override;

    procedure AttachBuffer(ABuffer: TRtmpCircularBuffer);
    function GetStats: TRtmpSessionStats;
    procedure NotePacket(const APacket: TRtmpPacket);
    procedure ResetStats;
    function RequestReconnect(const ATcUrl: string = '';
      const ADescription: string = ''): Boolean;
    function Run(AOnPacket: TRtmpSessionPacketEvent;
      AOnLog: TRtmpSessionLogEvent = nil): Boolean;

    property Connection: IRtmpConnection read FConnection;
    property RemoteAddress: string read FRemoteAddress;
    property RemotePort: Word read FRemotePort;
    property AppName: string read FAppName write FAppName;
    property Authorizer: IRtmpServerAuthorizer read FAuthorizer write FAuthorizer;
    property TcUrl: string read FTcUrl write FTcUrl;
    property FlashVersion: string read FFlashVersion write FFlashVersion;
    property EnhancedCodecs: string read FEnhancedCodecs;
    property EnhancedCapabilities: UInt32 read FEnhancedCapabilities;
    property SupportedEnhancedCapabilities: UInt32
      read FSupportedEnhancedCapabilities write FSupportedEnhancedCapabilities;
    property HasActivePublish: Boolean read FHasActivePublish;
    property LastPublishedStreamName: string read FLastPublishedStreamName;
    property StreamName: string read GetStreamName write FStreamName;
    property HandshakeCompleted: Boolean read FHandshakeCompleted write FHandshakeCompleted;
    property InChunkSize: UInt32 read FInChunkSize write FInChunkSize;
    property OutChunkSize: UInt32 read FOutChunkSize write FOutChunkSize;
    property AckWindowSize: UInt32 read FAckWindowSize write FAckWindowSize;
    property MessageStreamID: UInt32 read FMessageStreamID write FMessageStreamID;
    property MaxInChunkSize: Integer read FMaxInChunkSize write FMaxInChunkSize;
    property MaxInChunkStreams: Integer read FMaxInChunkStreams write SetMaxInChunkStreams;
    property MaxInMessageSize: Integer read FMaxInMessageSize write SetMaxInMessageSize;
    property MinLogLevel: TRtmpLogLevel read FMinLogLevel write FMinLogLevel;
    property ReadTimeoutMS: Integer read FReadTimeoutMS write FReadTimeoutMS;
    property State: TRtmpSessionState read FState write FState;
    property StartedAt: TRtmpTick read FStartedAt;
    property WriteTimeoutMS: Integer read FWriteTimeoutMS write FWriteTimeoutMS;
  end;

implementation

uses
  TRTMP.RTMP.Protocol.AMF0,
  TRTMP.Core.Bytes,
  TRTMP.RTMP.Protocol.Command,
  TRTMP.RTMP.Protocol.FLV,
  TRTMP.RTMP.Protocol.Core;

type
  TObjectArray = array of TObject;

function MessageTypeName(AType: TRtmpMessageType): string;
begin
  case AType of
    mtSetChunkSize: Result:='SetChunkSize';
    mtAbort: Result:='Abort';
    mtAck: Result:='Ack';
    mtUserControl: Result:='UserControl';
    mtWindowAckSize: Result:='WindowAckSize';
    mtSetPeerBandwidth: Result:='SetPeerBandwidth';
    mtAudio: Result:='Audio';
    mtVideo: Result:='Video';
    mtDataAMF3: Result:='DataAMF3';
    mtSharedObjectAMF3: Result:='SharedObjectAMF3';
    mtCommandAMF3: Result:='CommandAMF3';
    mtDataAMF0: Result:='DataAMF0';
    mtSharedObjectAMF0: Result:='SharedObjectAMF0';
    mtCommandAMF0: Result:='CommandAMF0';
    mtAggregate: Result:='Aggregate';
  else
    Result:='Unknown';
  end;
end;

function PacketFlagsToString(AFlags: TRtmpPacketFlags): string;
const
  FLAG_NAMES: array[TRtmpPacketFlag] of string = (
    'audio',
    'video',
    'metadata',
    'codec-config',
    'keyframe',
    'sequence-header',
    'extended-ts',
    'dropped',
    'reconstructed'
  );
var
  Flag: TRtmpPacketFlag;
begin
  Result:='';
  for Flag:=Low(TRtmpPacketFlag) to High(TRtmpPacketFlag) do
    if Flag IN AFlags then
    begin
      if Result <> '' then
        Result:=Result + ',';
      Result:=Result + FLAG_NAMES[Flag];
    end;

  if Result = '' then
    Result:='none';
end;

function UserControlEventName(AEventType: Word): string;
begin
  case AEventType of
    Ord(ucStreamBegin): Result:='StreamBegin';
    Ord(ucStreamEOF): Result:='StreamEOF';
    Ord(ucStreamDry): Result:='StreamDry';
    Ord(ucSetBufferLength): Result:='SetBufferLength';
    Ord(ucStreamIsRecorded): Result:='StreamIsRecorded';
    Ord(ucPingRequest): Result:='PingRequest';
    Ord(ucPingResponse): Result:='PingResponse';
    Ord(ucBufferEmpty): Result:='BufferEmpty';
    Ord(ucBufferReady): Result:='BufferReady';
  else
    Result:='Unknown';
  end;
end;

function PeerBandwidthLimitTypeName(ALimitType: Byte): string;
begin
  case ALimitType of
    0: Result:='Hard';
    1: Result:='Soft';
    2: Result:='Dynamic';
  else
    Result:='Unknown';
  end;
end;

function TRtmpServerSession.GetStreamName: string;
begin
  Result:=FStreamName;
  if Result = '' then
    Result:=FLastPublishedStreamName;
end;

function TRtmpServerSession.StreamNameForLog: string;
begin
  Result:=GetStreamName;
end;

function BytesToHexPreview(const ABytes: TBytes; AMaxBytes: Integer = 32): string;
var
  Count: Integer;
  I: Integer;
begin
  Result:='';
  Count:=Length(ABytes);
  if Count > AMaxBytes then
    Count:=AMaxBytes;

  for I:=0 to Count - 1 do
  begin
    if Result <> '' then
      Result:=Result + ' ';
    Result:=Result + IntToHex(ABytes[I], 2);
  end;

  if Length(ABytes) > Count then
    Result:=Result + ' ...';
end;

procedure NormalizeAppAndStream(var AAppName, ATcUrl, AStreamName: string);
var
  SlashPos: Integer;
begin
  if (AStreamName = '') AND (AAppName <> '') then
  begin
    SlashPos:=LastDelimiter('/', AAppName);
    if (SlashPos > 0) AND (SlashPos < Length(AAppName)) then
    begin
      AStreamName:=Copy(AAppName, SlashPos + 1, MaxInt);
      AAppName:=Copy(AAppName, 1, SlashPos - 1);
    end;
  end;

  if (AStreamName <> '') AND (ATcUrl <> '') AND
    (Copy(ATcUrl, Length(ATcUrl) - Length(AStreamName), Length(AStreamName) + 1) =
      '/' + AStreamName) then
    Delete(ATcUrl, Length(ATcUrl) - Length(AStreamName), Length(AStreamName) + 1);
end;

function BuildObject(const APairs: array of const): TRtmpAmf0Object;
var
  I: Integer;
  KeyName: string;
begin
  if (Length(APairs) MOD 2) <> 0 then
    raise Exception.Create('BuildObject expects name/value pairs');

  Result:=TRtmpAmf0Object.Create;
  I:=0;
  while I < Length(APairs) do
  begin
    case APairs[I].VType of
      vtAnsiString:
        KeyName:=string(AnsiString(APairs[I].VAnsiString));
      vtPChar:
        KeyName:=string(APairs[I].VPChar);
      vtChar:
        KeyName:=string(APairs[I].VChar);
      vtString:
        KeyName:=string(APairs[I].VString^);
      vtUnicodeString:
        KeyName:=string(UnicodeString(APairs[I].VUnicodeString));
    else
      raise Exception.Create('BuildObject key must be a string');
    end;

    case APairs[I + 1].VType of
      vtAnsiString:
        Result.Add(KeyName, TRtmpAmf0String.Create(string(AnsiString(APairs[I + 1].VAnsiString))));
      vtPChar:
        Result.Add(KeyName, TRtmpAmf0String.Create(string(APairs[I + 1].VPChar)));
      vtChar:
        Result.Add(KeyName, TRtmpAmf0String.Create(string(APairs[I + 1].VChar)));
      vtString:
        Result.Add(KeyName, TRtmpAmf0String.Create(string(APairs[I + 1].VString^)));
      vtUnicodeString:
        Result.Add(KeyName, TRtmpAmf0String.Create(
          string(UnicodeString(APairs[I + 1].VUnicodeString))));
      vtInteger:
        Result.Add(KeyName, TRtmpAmf0Number.Create(APairs[I + 1].VInteger));
      vtInt64:
        Result.Add(KeyName, TRtmpAmf0Number.Create(APairs[I + 1].VInt64^));
      vtExtended:
        Result.Add(KeyName, TRtmpAmf0Number.Create(APairs[I + 1].VExtended^));
      vtBoolean:
        Result.Add(KeyName, TRtmpAmf0Boolean.Create(APairs[I + 1].VBoolean));
      vtObject:
        if TObject(APairs[I + 1].VObject) IS TRtmpAmf0Value then
          Result.Add(KeyName, TRtmpAmf0Value(TObject(APairs[I + 1].VObject)).Clone)
        else
          raise Exception.Create('BuildObject only accepts TRtmpAmf0Value objects');
    else
      raise Exception.Create('Unsupported BuildObject value type');
    end;

    Inc(I, 2);
  end;
end;

function BuildCommandValueArray(const AValues: array of TObject): TObjectArray;
var
  I: Integer;
begin
  Result:=nil;
  SetLength(Result, Length(AValues));
  for I:=0 to High(AValues) do
    Result[I]:=AValues[I];
end;

constructor TRtmpServerSession.Create(const AConnection: IRtmpConnection);
begin
  inherited Create;
  FLock:=TCriticalSection.Create;
  FConnection:=AConnection;
  if Assigned(AConnection) then
  begin
    FRemoteAddress:=AConnection.RemoteEndpoint.Address;
    FRemotePort:=AConnection.RemoteEndpoint.Port;
  end;
  FStartedAt:=RtmpGetTickCount64;
  FInChunkSize:=128;
  FOutChunkSize:=4096;
  FAckWindowSize:=5000000;
  FHasActivePublish:=False;
  FHasActivePlay:=False;
  FLastPublishedStreamName:='';
  FEnhancedCodecs:='';
  FEnhancedCapabilities:=0;
  FSupportedEnhancedCapabilities:=RTMP_DEFAULT_ENHANCED_CAPABILITIES;
  FState:=ssDisconnected;
  FPlayBootstrapPending:=False;
  FPlayBufferLengthMS:=0;
  FPlaySequenceNo:=0;
  FMinLogLevel:=llInfo;
  FMaxInChunkSize:=131072;
  FMaxInMessageSize:=8 * 1024 * 1024;
  FMaxInChunkStreams:=64;
  FProtocolDefaultsSent:=False;
  FReconnectRequestDescription:='';
  FReconnectRequestPending:=False;
  FReconnectRequestTcUrl:='';
  FReadTimeoutMS:=10000;
  FWriteTimeoutMS:=10000;
  FRawBytesReceived:=0;
  FNextAckAt:=FAckWindowSize;
  FReassembler:=TRtmpChunkReassembler.Create(FInChunkSize);
  FReassembler.MaxMessageSize:=FMaxInMessageSize;
  FReassembler.MaxChunkStreams:=FMaxInChunkStreams;
  ResetStats;
end;

constructor TRtmpServerSession.Create(const ARemoteAddress: string; ARemotePort: Word);
begin
  Create(nil);
  FRemoteAddress:=ARemoteAddress;
  FRemotePort:=ARemotePort;
end;

destructor TRtmpServerSession.Destroy;
begin
  FReassembler.Free;
  FLock.Free;
  inherited Destroy;
end;

function TRtmpServerSession.IsLogEnabled(ALevel: TRtmpLogLevel): Boolean;
begin
  Result:=Assigned(FActiveLogHandler) AND (ALevel >= FMinLogLevel);
end;

procedure TRtmpServerSession.EmitLog(AOnLog: TRtmpSessionLogEvent;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
begin
  if Assigned(AOnLog) AND (ALevel >= FMinLogLevel) then
    AOnLog(Self, ALevel, ACategory, AMessage);
end;

procedure TRtmpServerSession.ClearPlayState(AClearMessageStream: Boolean);
begin
  FHasActivePlay:=False;
  FPlayBootstrapPending:=False;
  FPlaySequenceNo:=0;
  FPlayBufferLengthMS:=0;
  if AClearMessageStream then
    FMessageStreamID:=0;
end;

procedure TRtmpServerSession.AttachBuffer(ABuffer: TRtmpCircularBuffer);
begin
  FBuffer:=ABuffer;
end;

function TRtmpServerSession.EnsureCommandState(const ACommandName: string;
  const AAllowedStates: array of TRtmpSessionState; ATransactionID: Double;
  AMessageStreamID: UInt32; const AErrorCode, ADescription: string;
  AOnLog: TRtmpSessionLogEvent): Boolean;
var
  Allowed: Boolean;
  I: Integer;
  PreviousState: TRtmpSessionState;
begin
  Allowed:=False;
  for I:=Low(AAllowedStates) to High(AAllowedStates) do
    if FState = AAllowedStates[I] then
    begin
      Allowed:=True;
      Break;
    end;

  if Allowed then
    Exit(True);

  NoteMalformedMessage;
  PreviousState:=FState;
  FState:=ssError;
  if AMessageStreamID <> 0 then
    SendOnStatusError(AMessageStreamID, AErrorCode, ADescription)
  else
    SendCommandError(ATransactionID, AErrorCode, ADescription);
  EmitLog(AOnLog, llWarning, 'session',
    Format('Rejected command %s in state=%d: %s',
      [ACommandName, Ord(PreviousState), ADescription]));
  Result:=False;
end;

procedure TRtmpServerSession.MaybeSendAck;
begin
  if (FAckWindowSize = 0) OR (FRawBytesReceived < FNextAckAt) then
    Exit;

  SendAcknowledgement(UInt32(FRawBytesReceived AND High(UInt32)));
  while FNextAckAt <= FRawBytesReceived do
    Inc(FNextAckAt, FAckWindowSize);

  if IsLogEnabled(llDebug) then
    EmitLog(FActiveLogHandler, llDebug, 'ack',
      Format('Sent acknowledgement totalBytes=%d nextAckAt=%d',
        [FRawBytesReceived, FNextAckAt]));
end;

procedure TRtmpServerSession.MaybeSendReconnectRequest;
var
  Description: string;
  StatusInfo: TRtmpAmf0Object;
  TcUrl: string;
begin
  FLock.Acquire;
  try
    if NOT FReconnectRequestPending then
      Exit;
    Description:=FReconnectRequestDescription;
    TcUrl:=FReconnectRequestTcUrl;
    FReconnectRequestPending:=False;
    FReconnectRequestDescription:='';
    FReconnectRequestTcUrl:='';
  finally
    FLock.Release;
  end;

  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetConnection.Connect.ReconnectRequest'
  ]);
  if TcUrl <> '' then
    StatusInfo.Add('tcUrl', TRtmpAmf0String.Create(TcUrl));
  if Description <> '' then
    StatusInfo.Add('description', TRtmpAmf0String.Create(Description));
  try
    SendCommandMessage(3, 0, BuildCommandValueArray([
      TRtmpAmf0String.Create('onStatus'),
      TRtmpAmf0Number.Create(0),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]));
  finally
    StatusInfo.Free;
  end;
  EmitLog(FActiveLogHandler, llInfo, 'session', Format(
    'Sent reconnect request tcUrl=%s description=%s', [TcUrl, Description]));
end;

procedure TRtmpServerSession.NoteMalformedMessage;
begin
  FLock.Acquire;
  try
    Inc(FStats.MalformedMessages);
  finally
    FLock.Release;
  end;
end;

function TRtmpServerSession.GetStats: TRtmpSessionStats;
begin
  FLock.Acquire;
  try
    Result:=FStats;
  finally
    FLock.Release;
  end;
end;

function TRtmpServerSession.HandleChunkMessage(const AMessage: TRtmpChunkMessage;
  AOnPacket: TRtmpSessionPacketEvent; AOnLog: TRtmpSessionLogEvent): Boolean;
var
  LimitTypeName: string;
  Packet: TRtmpPacket;
  NewChunkSize: UInt32;
  Reader: TRtmpByteReader;
begin
  Result:=True;

  if IsLogEnabled(llDebug) then
    EmitLog(AOnLog, llDebug, 'rx-message',
      Format('csid=%d msid=%d type=%s(%d) ts=%d delta=%d size=%d ext=%s',
        [AMessage.ChunkStreamID, AMessage.MessageStreamID,
         MessageTypeName(AMessage.MessageType), AMessage.MessageTypeID,
         AMessage.Timestamp, AMessage.TimestampDelta, Length(AMessage.Payload),
         BoolToStr(AMessage.HasExtendedTimestamp, True)]));

  case AMessage.MessageType of
    mtAbort:
      begin
        Reader:=TRtmpByteReader.Create(AMessage.Payload);
        try
          if Reader.Remaining < 4 then
            raise ERtmpProtocolError.Create('Abort payload is shorter than 4 bytes');

          NewChunkSize:=Reader.ReadUInt32BE;
          FReassembler.AbortChunkStream(NewChunkSize);
          EmitLog(AOnLog, llInfo, 'protocol',
            Format('Abort received for chunk stream %d', [NewChunkSize]));
        finally
          Reader.Free;
        end;
      end;
    mtSetChunkSize:
      begin
        Reader:=TRtmpByteReader.Create(AMessage.Payload);
        try
          if Reader.Remaining < 4 then
            raise ERtmpProtocolError.Create('SetChunkSize payload is shorter than 4 bytes');

          NewChunkSize:=Reader.ReadUInt32BE;
          if NewChunkSize = 0 then
            raise ERtmpProtocolError.Create('SetChunkSize payload requested chunk size 0');

          if (FMaxInChunkSize > 0) AND (Integer(NewChunkSize) > FMaxInChunkSize) then
            raise ERtmpProtocolError.CreateFmt(
              'Inbound chunk size %d exceeds configured maximum %d',
              [NewChunkSize, FMaxInChunkSize]);

          InChunkSize:=NewChunkSize;
          FReassembler.InChunkSize:=InChunkSize;
          EmitLog(AOnLog, llInfo, 'protocol',
            Format('Inbound chunk size changed to %d', [InChunkSize]));
        finally
          Reader.Free;
        end;
      end;
    mtAck:
      begin
        if IsLogEnabled(llDebug) then
          EmitLog(AOnLog, llDebug, 'protocol', 'Peer acknowledgement received');
      end;
    mtUserControl:
      Result:=HandleUserControlMessage(AMessage, AOnLog);
    mtWindowAckSize:
      begin
        Reader:=TRtmpByteReader.Create(AMessage.Payload);
        try
          if Reader.Remaining >= 4 then
          begin
            FAckWindowSize:=Reader.ReadUInt32BE;
            if FNextAckAt < FRawBytesReceived + FAckWindowSize then
              FNextAckAt:=FRawBytesReceived + FAckWindowSize;
            EmitLog(AOnLog, llInfo, 'protocol',
              Format('Peer window acknowledgement size set to %d', [FAckWindowSize]));
          end;
        finally
          Reader.Free;
        end;
      end;
    mtSetPeerBandwidth:
      begin
        Reader:=TRtmpByteReader.Create(AMessage.Payload);
        try
          if Reader.Remaining >= 5 then
          begin
            NewChunkSize:=Reader.ReadUInt32BE;
            LimitTypeName:=PeerBandwidthLimitTypeName(Reader.ReadUInt8);
            EmitLog(AOnLog, llInfo, 'protocol',
              Format('Peer bandwidth window=%d limit=%s', [NewChunkSize, LimitTypeName]));
          end;
        finally
          Reader.Free;
        end;
      end;
    mtCommandAMF3:
      raise ERtmpProtocolError.Create(
        'AMF3 command messages are not supported; use objectEncoding=0');
    mtCommandAMF0:
      Result:=HandleCommandMessage(AMessage, AOnLog);
    mtAudio, mtVideo, mtDataAMF0, mtDataAMF3:
      begin
        if NOT FHasActivePublish then
        begin
          NoteMalformedMessage;
          FState:=ssError;
          SendOnStatusError(AMessage.MessageStreamID, 'NetStream.Failed',
            'media/data received before publish was accepted.');
          EmitLog(AOnLog, llWarning, 'session',
            Format('Rejected %s before publish acceptance',
              [MessageTypeName(AMessage.MessageType)]));
          Exit(False);
        end;

        Packet:=RtmpCreatePacketFromChunkMessage(AMessage, FSequenceNo);
        try
          if IsLogEnabled(llDebug) then
            EmitLog(AOnLog, llDebug, 'packet',
              Format('seq=%d type=%s ts=%d size=%d flags=%s',
                [FSequenceNo, MessageTypeName(Packet.MessageType), Packet.Timestamp,
                 Packet.PayloadSize, PacketFlagsToString(Packet.Flags)]));
          Inc(FSequenceNo);
          if Assigned(AOnPacket) then
            AOnPacket(Self, Packet);
        finally
          Packet.Free;
        end;
      end;
  else
    if IsLogEnabled(llDebug) then
      EmitLog(AOnLog, llDebug, 'protocol',
        Format('Ignoring RTMP message type id %d', [AMessage.MessageTypeID]));
  end;
end;

function TRtmpServerSession.HandleCommandMessage(const AMessage: TRtmpChunkMessage;
  AOnLog: TRtmpSessionLogEvent): Boolean;
var
  AuthorizationCode: string;
  AuthorizationDescription: string;
  AuthorizationDecision: TRtmpAuthorizationDecision;
  Command: TRtmpCommandMessage;
  CommandPayload: TBytes;
  AppName: string;
  TcUrl: string;
  FlashVer: string;
  PlayName: string;
  PublishName: string;
  PublishType: string;
  EnhancedCodecs: string;
  EnhancedCapabilities: UInt32;
  ConnectAuthorization: TRtmpConnectAuthorizationContext;
  PublishAuthorization: TRtmpPublishAuthorizationContext;
  StreamName: string;
begin
  Result:=True;
  CommandPayload:=AMessage.Payload;

  Command:=TRtmpCommandMessage.Create(CommandPayload);
  try
    if Command.IsCommand('connect') then
    begin
      if NOT EnsureCommandState('connect', [ssConnected], Command.TransactionID, 0,
        'NetConnection.Connect.BadSequence',
        'connect is only valid immediately after handshake.', AOnLog) then
        Exit(False);

      if Command.TryGetConnectInfo(AppName, TcUrl, FlashVer) then
      begin
        FAppName:=AppName;
        FTcUrl:=TcUrl;
        FFlashVersion:=FlashVer;
      end;
      if Command.TryGetConnectEnhancedCodecs(EnhancedCodecs) then
        FEnhancedCodecs:=EnhancedCodecs
      else
        FEnhancedCodecs:='';
      if Command.TryGetConnectCapsEx(EnhancedCapabilities) then
        FEnhancedCapabilities:=EnhancedCapabilities
      else
        FEnhancedCapabilities:=0;

      if FAuthorizer <> nil then
      begin
        ConnectAuthorization:=Default(TRtmpConnectAuthorizationContext);
        ConnectAuthorization.RemoteAddress:=FRemoteAddress;
        ConnectAuthorization.RemotePort:=FRemotePort;
        ConnectAuthorization.App:=FAppName;
        ConnectAuthorization.TcUrl:=FTcUrl;
        ConnectAuthorization.FlashVersion:=FFlashVersion;
        ConnectAuthorization.EnhancedCodecs:=FEnhancedCodecs;
        ConnectAuthorization.EnhancedCapabilities:=FEnhancedCapabilities;
        try
          AuthorizationDecision:=FAuthorizer.AuthorizeConnect(ConnectAuthorization);
        except
          on E: Exception do
          begin
            EmitLog(AOnLog, llError, 'authorization',
              Format('Connect authorizer failed: %s', [E.Message]));
            AuthorizationDecision:=TRtmpAuthorizationDecision.Deny('',
              'Connection authorization failed.');
          end;
        end;
        if NOT AuthorizationDecision.Allowed then
        begin
          AuthorizationCode:=AuthorizationDecision.Code;
          if AuthorizationCode = '' then
            AuthorizationCode:='NetConnection.Connect.Rejected';
          AuthorizationDescription:=AuthorizationDecision.Description;
          if AuthorizationDescription = '' then
            AuthorizationDescription:='Connection authorization denied.';
          FState:=ssError;
          SendCommandError(Command.TransactionID, AuthorizationCode,
            AuthorizationDescription);
          EmitLog(AOnLog, llWarning, 'authorization', Format(
            'Denied connect app=%s remote=%s:%d code=%s description=%s',
            [FAppName, FRemoteAddress, FRemotePort, AuthorizationCode,
             AuthorizationDescription]));
          Exit(False);
        end;
      end;

      FState:=ssConnectedCommand;
      SendProtocolDefaults;
      SendUserControlStreamBegin(0);
      SendConnectSuccess(Command.TransactionID);
      EmitLog(AOnLog, llInfo, 'session',
        Format('connect app=%s tcUrl=%s flashVer=%s enhancedCodecs=%s capsEx=0x%s',
          [FAppName, FTcUrl, FFlashVersion, FEnhancedCodecs,
           IntToHex(FEnhancedCapabilities, 8)]));
    end
    else if Command.IsCommand('createStream') then
    begin
      if NOT EnsureCommandState('createStream', [ssConnectedCommand],
        Command.TransactionID, AMessage.MessageStreamID,
        'NetConnection.Call.BadSequence',
        'createStream requires a successful connect first.', AOnLog) then
        Exit(False);

      FMessageStreamID:=1;
      SendCreateStreamResult(Command.TransactionID);
      EmitLog(AOnLog, llInfo, 'session', 'createStream accepted');
    end
    else if Command.TryGetPlayInfo(PlayName) then
    begin
      if NOT EnsureCommandState('play', [ssConnectedCommand],
        Command.TransactionID, AMessage.MessageStreamID,
        'NetStream.Play.BadConnection',
        'play requires connect and createStream before media flow.', AOnLog) then
        Exit(False);
      if FMessageStreamID = 0 then
      begin
        NoteMalformedMessage;
        FState:=ssError;
        SendOnStatusError(AMessage.MessageStreamID, 'NetStream.Play.BadConnection',
          'play requires a created message stream.');
        EmitLog(AOnLog, llWarning, 'session',
          'Rejected play before createStream established a message stream');
        Exit(False);
      end;

      FStreamName:=PlayName;
      NormalizeAppAndStream(FAppName, FTcUrl, FStreamName);
      FHasActivePlay:=True;
      FPlayBootstrapPending:=True;
      FPlaySequenceNo:=0;
      FState:=ssStreaming;
      SendPlayReset;
      SendPlayStart;
      EmitLog(AOnLog, llInfo, 'session',
        Format('play stream=%s bufferMS=%d', [FStreamName, FPlayBufferLengthMS]));
    end
    else if Command.IsCommand('publish') then
    begin
      if NOT EnsureCommandState('publish', [ssConnectedCommand],
        Command.TransactionID, AMessage.MessageStreamID,
        'NetStream.Publish.BadConnection',
        'publish requires connect and createStream before media flow.', AOnLog) then
        Exit(False);
      if FMessageStreamID = 0 then
      begin
        NoteMalformedMessage;
        FState:=ssError;
        SendOnStatusError(AMessage.MessageStreamID, 'NetStream.Publish.BadConnection',
          'publish requires a created message stream.');
        EmitLog(AOnLog, llWarning, 'session',
          'Rejected publish before createStream established a message stream');
        Exit(False);
      end;

      if Command.TryGetPublishInfo(PublishName, PublishType) then
        FStreamName:=PublishName;
      NormalizeAppAndStream(FAppName, FTcUrl, FStreamName);
      if PublishType = '' then
        PublishType:='live';

      if FAuthorizer <> nil then
      begin
        PublishAuthorization:=Default(TRtmpPublishAuthorizationContext);
        PublishAuthorization.RemoteAddress:=FRemoteAddress;
        PublishAuthorization.RemotePort:=FRemotePort;
        PublishAuthorization.App:=FAppName;
        PublishAuthorization.TcUrl:=FTcUrl;
        PublishAuthorization.StreamName:=FStreamName;
        PublishAuthorization.PublishType:=PublishType;
        try
          AuthorizationDecision:=FAuthorizer.AuthorizePublish(PublishAuthorization);
        except
          on E: Exception do
          begin
            EmitLog(AOnLog, llError, 'authorization',
              Format('Publish authorizer failed: %s', [E.Message]));
            AuthorizationDecision:=TRtmpAuthorizationDecision.Deny('',
              'Publish authorization failed.');
          end;
        end;
        if NOT AuthorizationDecision.Allowed then
        begin
          AuthorizationCode:=AuthorizationDecision.Code;
          if AuthorizationCode = '' then
            AuthorizationCode:='NetStream.Publish.Rejected';
          AuthorizationDescription:=AuthorizationDecision.Description;
          if AuthorizationDescription = '' then
            AuthorizationDescription:='Publish authorization denied.';
          FState:=ssError;
          SendOnStatusError(AMessage.MessageStreamID, AuthorizationCode,
            AuthorizationDescription);
          EmitLog(AOnLog, llWarning, 'authorization', Format(
            'Denied publish app=%s stream=%s remote=%s:%d code=%s description=%s',
            [FAppName, FStreamName, FRemoteAddress, FRemotePort,
             AuthorizationCode, AuthorizationDescription]));
          Exit(False);
        end;
      end;

      FHasActivePublish:=True;
      FLastPublishedStreamName:=FStreamName;
      FState:=ssPublishing;
      SendPublishStart;
      FState:=ssStreaming;
      EmitLog(AOnLog, llInfo, 'session',
        Format('publish stream=%s type=%s', [FStreamName, PublishType]));
    end
    else if Command.TryGetReleaseStreamInfo(StreamName) then
    begin
      FStreamName:=StreamName;
      if IsLogEnabled(llDebug) then
        EmitLog(AOnLog, llDebug, 'session',
          Format('stream control command %s stream=%s',
            [Command.CommandName, FStreamName]));
    end
    else if Command.IsCommand('FCUnpublish') then
    begin
      EmitLog(AOnLog, llInfo, 'session',
        Format('FCUnpublish stream=%s', [StreamNameForLog]));
      FHasActivePublish:=False;
      ClearPlayState(False);
      FState:=ssConnectedCommand;
      FStreamName:='';
    end
    else if Command.IsCommand('deleteStream') OR Command.IsCommand('closeStream') then
    begin
      EmitLog(AOnLog, llInfo, 'session',
        Format('%s received for stream=%s', [Command.CommandName, StreamNameForLog]));
      FHasActivePublish:=False;
      ClearPlayState(True);
      FState:=ssConnectedCommand;
      FStreamName:='';
      Result:=False;
    end
    else
      if IsLogEnabled(llDebug) then
        EmitLog(AOnLog, llDebug, 'session',
          Format('Unhandled AMF command %s', [Command.CommandName]));
  finally
    Command.Free;
  end;
end;

function TRtmpServerSession.HandleUserControlMessage(
  const AMessage: TRtmpChunkMessage; AOnLog: TRtmpSessionLogEvent): Boolean;
var
  BufferLength: UInt32;
  EventType: Word;
  Reader: TRtmpByteReader;
  Value1: UInt32;
  Value2: UInt32;
begin
  Result:=True;
  Reader:=TRtmpByteReader.Create(AMessage.Payload);
  try
    if Reader.Remaining < 2 then
      Exit;

    EventType:=Reader.ReadUInt16BE;
    Value1:=0;
    Value2:=0;
    if Reader.Remaining >= 4 then
      Value1:=Reader.ReadUInt32BE;
    if Reader.Remaining >= 4 then
      Value2:=Reader.ReadUInt32BE;

    case EventType of
      Ord(ucPingRequest):
        begin
          SendUserControl(Ord(ucPingResponse), Value1);
          EmitLog(AOnLog, llInfo, 'protocol',
            Format('Responded to ping request timestamp=%d', [Value1]));
        end;
      Ord(ucPingResponse):
        begin
          if IsLogEnabled(llDebug) then
            EmitLog(AOnLog, llDebug, 'protocol',
              Format('Received ping response timestamp=%d', [Value1]));
        end;
      Ord(ucSetBufferLength):
        begin
          BufferLength:=Value2;
          if (Value1 = 0) OR (Value1 = FMessageStreamID) then
            FPlayBufferLengthMS:=BufferLength;
          if IsLogEnabled(llDebug) then
            EmitLog(AOnLog, llDebug, 'protocol',
              Format('Peer set buffer length streamId=%d bufferMS=%d',
                [Value1, BufferLength]));
        end;
    else
      if IsLogEnabled(llDebug) then
        EmitLog(AOnLog, llDebug, 'protocol',
          Format('UserControl %s(%d) value1=%d value2=%d',
            [UserControlEventName(EventType), EventType, Value1, Value2]));
    end;
  finally
    Reader.Free;
  end;
end;

procedure TRtmpServerSession.NotePacket(const APacket: TRtmpPacket);
begin
  if APacket = nil then
    Exit;

  FLock.Acquire;
  try
    Inc(FStats.PacketsReceived);
    Inc(FStats.BytesReceived, UInt64(APacket.PayloadSize));
    FStats.LastPacketTimestamp:=APacket.Timestamp;
    FStats.LastArrivalTick:=APacket.ArrivalTick;

    if APacket.HasFlag(pfIsAudio) OR (APacket.MessageType = mtAudio) then
      Inc(FStats.AudioPackets)
    else if APacket.HasFlag(pfIsVideo) OR (APacket.MessageType = mtVideo) then
      Inc(FStats.VideoPackets)
    else if APacket.HasFlag(pfIsMetadata) then
      Inc(FStats.MetadataPackets);
  finally
    FLock.Release;
  end;
end;

function TRtmpServerSession.PerformHandshake(AOnLog: TRtmpSessionLogEvent): Boolean;
var
  C0: TBytes;
  C1: TBytes;
  C2: TBytes;
  Reply: TBytes;
begin
  Result:=False;
  if IsLogEnabled(llDebug) then
    EmitLog(AOnLog, llDebug, 'handshake', 'Waiting for C0');
  if NOT ReadExact(1, C0) then
    Exit;
  if C0[0] <> RTMP_VERSION then
    raise ERtmpProtocolError.CreateFmt('Unsupported RTMP version %d', [C0[0]]);
  if IsLogEnabled(llDebug) then
    EmitLog(AOnLog, llDebug, 'handshake',
      Format('Received C0 version=%d', [C0[0]]));

  if IsLogEnabled(llDebug) then
    EmitLog(AOnLog, llDebug, 'handshake', 'Waiting for C1');
  if NOT ReadExact(RTMP_HANDSHAKE_SIZE, C1) then
    Exit;
  if IsLogEnabled(llDebug) then
    EmitLog(AOnLog, llDebug, 'handshake',
      Format('Received C1 bytes=%d', [Length(C1)]));

  Reply:=TRtmpHandshake.BuildS0S1S2(C1);
  SendBytes(Reply);
  if IsLogEnabled(llDebug) then
    EmitLog(AOnLog, llDebug, 'handshake',
      Format('Sent S0/S1/S2 bytes=%d', [Length(Reply)]));

  if IsLogEnabled(llDebug) then
    EmitLog(AOnLog, llDebug, 'handshake', 'Waiting for C2');
  if NOT ReadExact(RTMP_HANDSHAKE_SIZE, C2) then
    Exit;
  if IsLogEnabled(llDebug) then
    EmitLog(AOnLog, llDebug, 'handshake',
      Format('Received C2 bytes=%d', [Length(C2)]));

  FHandshakeCompleted:=True;
  FState:=ssConnected;
  EmitLog(AOnLog, llInfo, 'handshake', 'Simple RTMP handshake completed');
  Result:=True;
end;

function TRtmpServerSession.ReadExact(ACount: Integer; out ABytes: TBytes): Boolean;
var
  Offset: Integer;
  Received: Integer;
begin
  Result:=False;
  Offset:=0;
  SetLength(ABytes, ACount);

  while Offset < ACount do
  begin
    Received:=FConnection.Receive(ABytes[Offset], ACount - Offset, FReadTimeoutMS);
    if Received <= 0 then
    begin
      if NOT FConnection.Connected then
        Exit(False);
      Continue;
    end;
    NoteRawBytesReceived(Received);
    Inc(Offset, Received);
  end;

  Result:=True;
end;

procedure TRtmpServerSession.NoteRawBytesReceived(ACount: Integer);
begin
  if ACount <= 0 then
    Exit;

  Inc(FRawBytesReceived, UInt64(ACount));
  MaybeSendAck;
end;

procedure TRtmpServerSession.ResetStats;
begin
  FLock.Acquire;
  try
    FillChar(FStats, SizeOf(FStats), 0);
  finally
    FLock.Release;
  end;
end;

function TRtmpServerSession.RequestReconnect(const ATcUrl,
  ADescription: string): Boolean;
begin
  Result:=False;
  if (FEnhancedCapabilities AND RTMP_CAPS_EX_RECONNECT) = 0 then
  begin
    EmitLog(FActiveLogHandler, llWarning, 'session',
      'Cannot request reconnect: peer did not advertise reconnect support');
    Exit;
  end;

  FLock.Acquire;
  try
    FReconnectRequestTcUrl:=Trim(ATcUrl);
    FReconnectRequestDescription:=ADescription;
    FReconnectRequestPending:=True;
    Result:=True;
  finally
    FLock.Release;
  end;
end;

function TRtmpServerSession.Run(AOnPacket: TRtmpSessionPacketEvent;
  AOnLog: TRtmpSessionLogEvent): Boolean;
var
  Buffer: array[0..8191] of Byte;
  ChunkMessage: TRtmpChunkMessage;
  ContinueProcessing: Boolean;
  MessagesRead: Integer;
  ReadTimeout: Integer;
  Received: Integer;
begin
  Result:=False;
  if FConnection = nil then
    Exit;

  FActiveLogHandler:=AOnLog;
  EmitLog(AOnLog, llInfo, 'session',
    Format('Starting session local=%s:%d remote=%s:%d readTimeout=%d writeTimeout=%d',
      [FConnection.LocalEndpoint.Address, FConnection.LocalEndpoint.Port,
       FRemoteAddress, FRemotePort, FReadTimeoutMS, FWriteTimeoutMS]));

  if NOT PerformHandshake(AOnLog) then
    Exit;

  ContinueProcessing:=True;
  while FConnection.Connected do
  begin
    MaybeSendReconnectRequest;
    if FHasActivePlay then
      PumpPlayPackets(AOnLog);

    ReadTimeout:=FReadTimeoutMS;
    if FHasActivePlay AND ((ReadTimeout <= 0) OR (ReadTimeout > 50)) then
      ReadTimeout:=50;

    Received:=FConnection.Receive(Buffer, SizeOf(Buffer), ReadTimeout);
    if Received < 0 then
      Break;

    if Received = 0 then
    begin
      if NOT FConnection.Connected then
        Break;
      Continue;
    end;

    NoteRawBytesReceived(Received);

    if IsLogEnabled(llDebug) then
      EmitLog(AOnLog, llDebug, 'socket',
        Format('Received raw bytes=%d', [Received]));

    FReassembler.AppendBytes(Buffer, Received);
    MessagesRead:=0;

    try
      while FReassembler.TryReadMessage(ChunkMessage) do
      begin
        Inc(MessagesRead);
        if NOT HandleChunkMessage(ChunkMessage, AOnPacket, AOnLog) then
        begin
          ContinueProcessing:=False;
          Break;
        end;
      end;

      if IsLogEnabled(llDebug) AND (MessagesRead = 0) AND
        (FReassembler.PendingBytes > 0) AND (FReassembler.PendingBytes <= 256) then
        EmitLog(AOnLog, llDebug, 'reassembler',
          Format('Buffered %d bytes awaiting more data preview=%s',
            [FReassembler.PendingBytes,
             BytesToHexPreview(FReassembler.GetPendingPreview(48), 48)]));
    except
      on E: Exception do
      begin
        NoteMalformedMessage;
        FState:=ssError;
        EmitLog(AOnLog, llError, 'protocol', E.Message);
        Break;
      end;
    end;

    MaybeSendReconnectRequest;

    if NOT ContinueProcessing then
      Break;
  end;

  EmitLog(AOnLog, llInfo, 'session',
    Format('Session finished stream=%s packets=%d bytes=%d audio=%d video=%d metadata=%d state=%d',
      [StreamNameForLog, FStats.PacketsReceived, FStats.BytesReceived,
       FStats.AudioPackets, FStats.VideoPackets, FStats.MetadataPackets, Ord(FState)]));
  FActiveLogHandler:=nil;
  Result:=True;
end;

procedure TRtmpServerSession.SendBytes(const ABytes: TBytes);
begin
  if Length(ABytes) = 0 then
    Exit;
  SendBuffer(@ABytes[0], Length(ABytes));
end;

procedure TRtmpServerSession.SetMaxInChunkStreams(AValue: Integer);
begin
  if AValue < 0 then
    raise ERtmpProtocolError.CreateFmt('Invalid maximum inbound chunk stream count %d', [AValue]);

  FMaxInChunkStreams:=AValue;
  if FReassembler <> nil then
    FReassembler.MaxChunkStreams:=AValue;
end;

procedure TRtmpServerSession.SetMaxInMessageSize(AValue: Integer);
begin
  if AValue < 0 then
    raise ERtmpProtocolError.CreateFmt('Invalid maximum inbound message size %d', [AValue]);

  FMaxInMessageSize:=AValue;
  if FReassembler <> nil then
    FReassembler.MaxMessageSize:=AValue;
end;

procedure TRtmpServerSession.SendBuffer(ABuffer: Pointer; ACount: Integer);
var
  Cursor: PByte;
  Offset: Integer;
  Sent: Integer;
begin
  if ACount <= 0 then
    Exit;

  if ABuffer = nil then
    raise ERtmpTransportError.Create('Cannot send nil buffer');

  Cursor:=PByte(ABuffer);
  Offset:=0;
  if IsLogEnabled(llDebug) then
    EmitLog(FActiveLogHandler, llDebug, 'socket',
      Format('Sending raw bytes=%d', [ACount]));
  while Offset < ACount do
  begin
    Sent:=FConnection.Send(Cursor^, ACount - Offset, FWriteTimeoutMS);
    if Sent <= 0 then
      raise ERtmpTransportError.Create('Socket send timed out or failed');
    Inc(Cursor, Sent);
    Inc(Offset, Sent);
  end;
end;

procedure TRtmpServerSession.SendCommandMessage(AChunkStreamID,
  AMessageStreamID: UInt32; const AValues: array of TObject);
var
  I: Integer;
  Payload: TBytes;
  Values: TRtmpAmf0ValueList;
begin
  if IsLogEnabled(llDebug) then
    EmitLog(FActiveLogHandler, llDebug, 'tx-command',
      Format('csid=%d msid=%d values=%d', [AChunkStreamID, AMessageStreamID,
        Length(AValues)]));
  Values:=TRtmpAmf0ValueList.Create(True);
  try
    for I:=0 to High(AValues) do
    begin
      if AValues[I] IS TRtmpAmf0Value then
        Values.AddValue(TRtmpAmf0Value(AValues[I]).Clone)
      else
        raise Exception.Create('SendCommandMessage only accepts TRtmpAmf0Value objects');
    end;
    Payload:=TRtmpAmf0.EncodeValues(Values);
  finally
    Values.Free;
  end;

  SendRtmpMessage(AChunkStreamID, AMessageStreamID, RtmpMessageTypeID(mtCommandAMF0), 0, Payload);
end;

procedure TRtmpServerSession.SendCommandError(ATransactionID: Double; const ACode,
  ADescription: string);
var
  StatusInfo: TRtmpAmf0Object;
begin
  StatusInfo:=BuildObject([
    'level', 'error',
    'code', ACode,
    'description', ADescription
  ]);
  try
    SendCommandMessage(3, 0, BuildCommandValueArray([
      TRtmpAmf0String.Create('_error'),
      TRtmpAmf0Number.Create(ATransactionID),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]));
  finally
    StatusInfo.Free;
  end;
end;

procedure TRtmpServerSession.SendConnectSuccess(ATransactionID: Double);
var
  ServerInfo: TRtmpAmf0Object;
  StatusInfo: TRtmpAmf0Object;
begin
  ServerInfo:=BuildObject([
    'fmsVer', 'FMS/3,5,1,516',
    'capabilities', 31
  ]);
  if FSupportedEnhancedCapabilities <> 0 then
    ServerInfo.Add('capsEx',
      TRtmpAmf0Number.Create(FSupportedEnhancedCapabilities));
  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetConnection.Connect.Success',
    'description', 'Connection succeeded.',
    'objectEncoding', 0
  ]);
  try
    SendCommandMessage(3, 0, BuildCommandValueArray([
      TRtmpAmf0String.Create('_result'),
      TRtmpAmf0Number.Create(ATransactionID),
      ServerInfo,
      StatusInfo
    ]));
  finally
    ServerInfo.Free;
    StatusInfo.Free;
  end;
end;

procedure TRtmpServerSession.SendCreateStreamResult(ATransactionID: Double);
begin
  SendCommandMessage(3, 0, BuildCommandValueArray([
    TRtmpAmf0String.Create('_result'),
    TRtmpAmf0Number.Create(ATransactionID),
    TRtmpAmf0Null.Create,
    TRtmpAmf0Number.Create(1)
  ]));
end;

procedure TRtmpServerSession.SendOnStatusError(AMessageStreamID: UInt32;
  const ACode, ADescription: string);
var
  StatusInfo: TRtmpAmf0Object;
  StreamID: UInt32;
begin
  StreamID:=AMessageStreamID;
  if StreamID = 0 then
    StreamID:=FMessageStreamID;
  if StreamID = 0 then
    StreamID:=1;

  StatusInfo:=BuildObject([
    'level', 'error',
    'code', ACode,
    'description', ADescription
  ]);
  try
    SendCommandMessage(5, StreamID, BuildCommandValueArray([
      TRtmpAmf0String.Create('onStatus'),
      TRtmpAmf0Number.Create(0),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]));
  finally
    StatusInfo.Free;
  end;
end;

procedure TRtmpServerSession.SendProtocolDefaults;
begin
  if FProtocolDefaultsSent then
    Exit;

  if IsLogEnabled(llDebug) then
    EmitLog(FActiveLogHandler, llDebug, 'protocol',
      Format('Sending protocol defaults ackWindow=%d outChunkSize=%d',
        [FAckWindowSize, FOutChunkSize]));
  SendWindowAckSize(FAckWindowSize);
  SendSetPeerBandwidth(FAckWindowSize, 2);
  SendSetChunkSize(FOutChunkSize);
  FProtocolDefaultsSent:=True;
end;

procedure TRtmpServerSession.SendPlayReset;
var
  StreamID: UInt32;
  StatusInfo: TRtmpAmf0Object;
begin
  StreamID:=FMessageStreamID;
  if StreamID = 0 then
    StreamID:=1;
  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetStream.Play.Reset',
    'description', 'Resetting and playing stream'
  ]);
  try
    SendCommandMessage(5, StreamID, BuildCommandValueArray([
      TRtmpAmf0String.Create('onStatus'),
      TRtmpAmf0Number.Create(0),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]));
  finally
    StatusInfo.Free;
  end;
end;

procedure TRtmpServerSession.SendPlayStart;
var
  StreamID: UInt32;
  StatusInfo: TRtmpAmf0Object;
begin
  StreamID:=FMessageStreamID;
  if StreamID = 0 then
    StreamID:=1;

  SendUserControlStreamBegin(StreamID);

  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetStream.Play.Start',
    'description', 'Started playing stream'
  ]);
  try
    SendCommandMessage(5, StreamID, BuildCommandValueArray([
      TRtmpAmf0String.Create('onStatus'),
      TRtmpAmf0Number.Create(0),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]));
  finally
    StatusInfo.Free;
  end;
end;

procedure TRtmpServerSession.SendPlayPacket(APacket: TRtmpPacket);
var
  ChunkStreamID: UInt32;
begin
  if (APacket = nil) OR (APacket.Payload = nil) then
    Exit;

  case APacket.MessageType of
    mtAudio:
      ChunkStreamID:=4;
    mtVideo:
      ChunkStreamID:=6;
  else
    ChunkStreamID:=5;
  end;

  SendRtmpMessage(ChunkStreamID, FMessageStreamID, RtmpMessageTypeID(APacket.MessageType),
    APacket.Timestamp, APacket.Payload.Bytes);
end;

procedure TRtmpServerSession.SendPublishStart;
var
  StatusInfo: TRtmpAmf0Object;
begin
  SendUserControlStreamBegin(1);

  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetStream.Publish.Start',
    'description', 'Start publishing'
  ]);
  try
    SendCommandMessage(5, 1, BuildCommandValueArray([
      TRtmpAmf0String.Create('onStatus'),
      TRtmpAmf0Number.Create(0),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]));
  finally
    StatusInfo.Free;
  end;
end;

procedure TRtmpServerSession.SendRtmpMessage(AChunkStreamID, AMessageStreamID: UInt32;
  AMessageTypeID: Byte; ATimestamp: UInt32; const APayload: TBytes);
var
  ChunkOffset: Integer;
  ChunkSize: Integer;
  Header: TRtmpChunkMessageHeader;
  Writer: TRtmpByteWriter;
begin
  Header:=Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat:=hfType0;
  Header.Timestamp:=ATimestamp;
  Header.MessageLength:=Length(APayload);
  Header.MessageTypeID:=AMessageTypeID;
  Header.MessageStreamID:=AMessageStreamID;
  Header.HasExtendedTimestamp:=ATimestamp >= RTMP_TIMESTAMP_EXTENDED;

  Writer:=TRtmpByteWriter.Create(Integer(FOutChunkSize) + 32);
  try
    if IsLogEnabled(llDebug) then
      EmitLog(FActiveLogHandler, llDebug, 'tx-message',
        Format('csid=%d msid=%d type=%d ts=%d size=%d',
          [AChunkStreamID, AMessageStreamID, AMessageTypeID, ATimestamp, Length(APayload)]));
    ChunkOffset:=0;
    while ChunkOffset < Length(APayload) do
    begin
      Writer.Clear;
      if ChunkOffset = 0 then
      begin
        WriteChunkBasicHeader(Writer, hfType0, AChunkStreamID);
        WriteChunkMessageHeader(Writer, Header);
      end
      else
      begin
        WriteChunkBasicHeader(Writer, hfType3, AChunkStreamID);
        if Header.HasExtendedTimestamp then
          WriteChunkMessageHeader(Writer, TRtmpChunkMessageHeader(Header));
      end;

      ChunkSize:=Length(APayload) - ChunkOffset;
      if ChunkSize > Integer(FOutChunkSize) then
        ChunkSize:=FOutChunkSize;

      Writer.WriteBytesRange(APayload, ChunkOffset, ChunkSize);
      SendBuffer(Writer.Data, Writer.Size);
      Inc(ChunkOffset, ChunkSize);
    end;

    if Length(APayload) = 0 then
    begin
      Writer.Clear;
      WriteChunkBasicHeader(Writer, hfType0, AChunkStreamID);
      WriteChunkMessageHeader(Writer, Header);
      SendBuffer(Writer.Data, Writer.Size);
    end;
  finally
    Writer.Free;
  end;
end;

procedure TRtmpServerSession.SendSetChunkSize(AChunkSize: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AChunkSize);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtSetChunkSize), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TRtmpServerSession.SendSetPeerBandwidth(AWindowSize: UInt32;
  ALimitType: Byte);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AWindowSize);
    Writer.WriteUInt8(ALimitType);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtSetPeerBandwidth), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TRtmpServerSession.SendAcknowledgement(ASequence: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(ASequence);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtAck), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TRtmpServerSession.SendUserControl(AEventType: Word; AValue1: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt16BE(AEventType);
    Writer.WriteUInt32BE(AValue1);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtUserControl), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TRtmpServerSession.SendUserControl(AEventType: Word; AValue1,
  AValue2: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt16BE(AEventType);
    Writer.WriteUInt32BE(AValue1);
    Writer.WriteUInt32BE(AValue2);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtUserControl), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TRtmpServerSession.SendUserControlStreamBegin(AStreamID: UInt32);
begin
  SendUserControl(Ord(ucStreamBegin), AStreamID);
end;

procedure TRtmpServerSession.PumpPlayPackets(AOnLog: TRtmpSessionLogEvent);
var
  I: Integer;
  Packet: TRtmpPacket;
  Packets: TRtmpPacketArray;
  SkipBootstrapHeaders: Boolean;
  StartSequence: UInt64;
begin
  if (NOT FHasActivePlay) OR (FBuffer = nil) OR (FMessageStreamID = 0) then
    Exit;

  SkipBootstrapHeaders:=False;
  if FPlayBootstrapPending then
  begin
    Packets:=FBuffer.GetCodecHeadersSnapshot;
    try
      for I:=0 to High(Packets) do
        SendPlayPacket(Packets[I]);
    finally
      for I:=0 to High(Packets) do
        Packets[I].Free;
    end;

    Packet:=FBuffer.GetLatestKeyframe;
    if Packet <> nil then
      StartSequence:=Packet.SequenceNo
    else
      StartSequence:=0;
    FPlaySequenceNo:=StartSequence;
    FPlayBootstrapPending:=False;
    SkipBootstrapHeaders:=True;

    if IsLogEnabled(llDebug) then
      EmitLog(AOnLog, llDebug, 'play',
        Format('Bootstrapping play stream=%s startSequence=%d',
          [FStreamName, FPlaySequenceNo]));
  end;

  Packets:=FBuffer.GetSinceSequenceSnapshot(FPlaySequenceNo);
  try
    for I:=0 to High(Packets) do
    begin
      Packet:=Packets[I];
      if (Packet = nil) OR (Packet.SequenceNo < FPlaySequenceNo) then
        Continue;

      if SkipBootstrapHeaders AND
        (Packet.HasFlag(pfIsMetadata) OR
        (Packet.HasFlag(pfIsCodecConfig) AND
          (Packet.HasFlag(pfIsAudio) OR Packet.HasFlag(pfIsVideo)))) then
      begin
        FPlaySequenceNo:=Packet.SequenceNo + 1;
        Continue;
      end;

      SendPlayPacket(Packet);
      FPlaySequenceNo:=Packet.SequenceNo + 1;
    end;
  finally
    for I:=0 to High(Packets) do
      Packets[I].Free;
  end;
end;

procedure TRtmpServerSession.SendWindowAckSize(AWindowSize: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AWindowSize);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtWindowAckSize), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

end.

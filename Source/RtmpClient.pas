unit RtmpClient;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  RtmpBuffer,
  RtmpCompat,
  RtmpLog,
  RtmpPacket,
  RtmpTransport,
  RtmpTypes;

type
  TRtmpClientEvent = procedure(Sender: TObject) of object;

  TRtmpClient = class
  private
    FLock: TCriticalSection;
    FBuffer: TRtmpCircularBuffer;
    FConfig: TRtmpClientConfig;
    FConnection: IRtmpConnection;
    FLog: TRtmpLogSink;
    FOnConnected: TRtmpClientEvent;
    FOnDisconnected: TRtmpClientEvent;
    FOnReconnect: TRtmpClientEvent;
    FRelayThread: TThread;
    FState: TRtmpClientState;
    FStartedAt: TRtmpTick;
    FStats: TRtmpClientStats;
    FTransactionID: Double;
    FTransportFactory: IRtmpTransportFactory;
    FLastBitrateBytes: UInt64;
    FLastBitrateTick: TRtmpTick;
    FOutChunkSize: UInt32;
    procedure ChangeState(AState: TRtmpClientState);
    procedure CloseConnection;
    function CurrentState: TRtmpClientState;
    procedure Log(ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
    procedure NoteReconnect;
    procedure NoteSentPacket(const APacket: TRtmpPacket);
    procedure RecalculateBitrate;
    procedure ResetStats;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AttachBuffer(ABuffer: TRtmpCircularBuffer);
    function GetStats: TRtmpClientStats;
    procedure SendPacket(const APacket: TRtmpPacket);
    procedure Start;
    procedure Stop;

    property Config: TRtmpClientConfig read FConfig write FConfig;
    property LogSink: TRtmpLogSink read FLog;
    property Stats: TRtmpClientStats read GetStats;
    property TransportFactory: IRtmpTransportFactory read FTransportFactory write FTransportFactory;
    property OnConnected: TRtmpClientEvent read FOnConnected write FOnConnected;
    property OnDisconnected: TRtmpClientEvent read FOnDisconnected write FOnDisconnected;
    property OnReconnect: TRtmpClientEvent read FOnReconnect write FOnReconnect;
    property State: TRtmpClientState read FState;
  end;

implementation

uses
  Math,
  RtmpAmf0,
  RtmpBytes,
  RtmpChunkReassembler,
  RtmpCommand,
  RtmpProtocol,
  RtmpTransportNative;

type
  TObjectArray = array of TObject;

  TRtmpClientResponseState = record
    ConnectAccepted: Boolean;
    CreateStreamAccepted: Boolean;
    Failed: Boolean;
    FailureCode: string;
    FailureDescription: string;
    FailureStage: string;
    PublishAccepted: Boolean;
    StreamID: UInt32;
  end;

  TRtmpTargetInfo = record
    Endpoint: TRtmpSocketEndpoint;
    AppName: string;
    StreamKey: string;
    TcUrl: string;
  end;

  TRtmpClientRelayThread = class(TThread)
  private
    FBytesReceived: UInt64;
    FClient: TRtmpClient;
    FIncomingChunkSize: UInt32;
    FInboundAckWindowSize: UInt32;
    FLastOutboundTimestamp: UInt32;
    FLastSentWindowAckSize: UInt32;
    FLastSourceTimestamp: UInt32;
    FMessageStreamID: UInt32;
    FNextAcknowledgementAt: UInt64;
    FNextSequenceNo: UInt64;
    FSessionEstablished: Boolean;
    FTimestampBaseSource: UInt32;
    FTimestampStateInitialized: Boolean;
    function BuildPublishInfo(out ATarget: TRtmpTargetInfo): Boolean;
    procedure CloseConnection;
    function EstablishPublishSession(out ATarget: TRtmpTargetInfo): Boolean;
    function HandleIncomingCommand(const AMessage: TRtmpChunkMessage;
      var AResponseState: TRtmpClientResponseState): Boolean;
    function HandleIncomingMessage(const AMessage: TRtmpChunkMessage;
      AReassembler: TRtmpChunkReassembler;
      var AResponseState: TRtmpClientResponseState): Boolean;
    function HandleIncomingUserControl(const AMessage: TRtmpChunkMessage): Boolean;
    function IsStreamingFailureCode(const ACode: string): Boolean;
    function MapPacketTimestamp(const APacket: TRtmpPacket): UInt32;
    procedure MaybeSendAcknowledgement;
    procedure NoteBytesReceived(ACount: Integer);
    function PerformHandshake: Boolean;
    procedure PumpIncomingMessages(AReassembler: TRtmpChunkReassembler;
      ATimeoutMS: Integer; var AResponseState: TRtmpClientResponseState);
    procedure RaiseResponseFailure(const AResponseState: TRtmpClientResponseState;
      const ADefaultStage: string);
    procedure ResetTimestampState;
    procedure SetResponseFailure(var AResponseState: TRtmpClientResponseState;
      const AStage, ACode, ADescription: string);
    function RunStreamingSession: Boolean;
    function ReadExact(ACount: Integer; out ABytes: TBytes): Boolean;
    function ReadOneOrMoreBytes(ATimeoutMS: Integer; out ABytes: TBytes): Boolean;
    procedure SendBuffer(ABuffer: Pointer; ACount: Integer);
    procedure SendBytes(const ABytes: TBytes);
    procedure SendCommandMessage(AChunkStreamID, AMessageStreamID: UInt32;
      const AValues: array of TObject);
    procedure SendInitialSnapshot;
    procedure SendPacketNow(const APacket: TRtmpPacket);
    procedure SendProtocolDefaults;
    procedure SendRtmpMessage(AChunkStreamID, AMessageStreamID: UInt32;
      AMessageTypeID: Byte; ATimestamp: UInt32; const APayload: TBytes);
    procedure SendSetChunkSize(AChunkSize: UInt32);
    procedure SendUserControl(AEventType: Word; AValue1: UInt32);
    procedure SendWindowAckSize(AWindowSize: UInt32);
    procedure SendWindowAcknowledgement(ASequence: UInt32);
    function WaitForSessionReady(AReassembler: TRtmpChunkReassembler;
      var AResponseState: TRtmpClientResponseState; ATimeoutMS: Integer): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TRtmpClient);
  end;

function BuildObject(const APairs: array of const): TRtmpAmf0Object;
var
  I: Integer;
  KeyName: string;
begin
  if (Length(APairs) mod 2) <> 0 then
    raise Exception.Create('BuildObject expects name/value pairs');

  Result := TRtmpAmf0Object.Create;
  I := 0;
  while I < Length(APairs) do
  begin
    case APairs[I].VType of
      vtAnsiString:
        KeyName := string(AnsiString(APairs[I].VAnsiString));
      vtPChar:
        KeyName := string(APairs[I].VPChar);
      vtChar:
        KeyName := string(APairs[I].VChar);
      vtString:
        KeyName := string(APairs[I].VString^);
      vtUnicodeString:
        KeyName := string(UnicodeString(APairs[I].VUnicodeString));
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
        if TObject(APairs[I + 1].VObject) is TRtmpAmf0Value then
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
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

function ExtractUrlPath(const AUrl: string): string;
var
  HostStart: Integer;
  PathPos: Integer;
begin
  Result := '';
  HostStart := Pos('://', AUrl);
  if HostStart > 0 then
    HostStart := HostStart + 3
  else
    HostStart := 1;

  PathPos := Pos('/', Copy(AUrl, HostStart, MaxInt));
  if PathPos > 0 then
    Result := Copy(AUrl, HostStart + PathPos - 1, MaxInt);
end;

function ParseRtmpTarget(const AUrl, AAppOverride, AStreamOverride: string;
  out ATarget: TRtmpTargetInfo): Boolean;
var
  ColonPos: Integer;
  HostPart: string;
  PathPart: string;
  SchemePos: Integer;
  SlashPos: Integer;
begin
  Result := False;
  ATarget := Default(TRtmpTargetInfo);
  ATarget.Endpoint.Port := 1935;

  if AUrl = '' then
    Exit;

  SchemePos := Pos('://', AUrl);
  if SchemePos > 0 then
    HostPart := Copy(AUrl, SchemePos + 3, MaxInt)
  else
    HostPart := AUrl;

  SlashPos := Pos('/', HostPart);
  if SlashPos > 0 then
  begin
    PathPart := Copy(HostPart, SlashPos + 1, MaxInt);
    HostPart := Copy(HostPart, 1, SlashPos - 1);
  end
  else
    PathPart := '';

  ColonPos := LastDelimiter(':', HostPart);
  if (ColonPos > 0) and (ColonPos < Length(HostPart)) then
  begin
    ATarget.Endpoint.Address := Copy(HostPart, 1, ColonPos - 1);
    ATarget.Endpoint.Port := Word(StrToIntDef(Copy(HostPart, ColonPos + 1, MaxInt),
      ATarget.Endpoint.Port));
  end
  else
    ATarget.Endpoint.Address := HostPart;

  if ATarget.Endpoint.Address = '' then
    Exit;

  if AAppOverride <> '' then
    ATarget.AppName := AAppOverride
  else if PathPart <> '' then
  begin
    SlashPos := LastDelimiter('/', PathPart);
    if SlashPos > 0 then
      ATarget.AppName := Copy(PathPart, 1, SlashPos - 1)
    else
      ATarget.AppName := PathPart;
  end;

  if AStreamOverride <> '' then
    ATarget.StreamKey := AStreamOverride
  else if PathPart <> '' then
  begin
    SlashPos := LastDelimiter('/', PathPart);
    if SlashPos > 0 then
      ATarget.StreamKey := Copy(PathPart, SlashPos + 1, MaxInt);
  end;

  ATarget.TcUrl := Format('rtmp://%s:%d/%s',
    [ATarget.Endpoint.Address, ATarget.Endpoint.Port, ATarget.AppName]);
  Result := (ATarget.AppName <> '') and (ATarget.StreamKey <> '');
end;

function UserControlEventName(AEventType: Word): string;
begin
  case AEventType of
    Ord(ucStreamBegin): Result := 'StreamBegin';
    Ord(ucStreamEOF): Result := 'StreamEOF';
    Ord(ucStreamDry): Result := 'StreamDry';
    Ord(ucSetBufferLength): Result := 'SetBufferLength';
    Ord(ucStreamIsRecorded): Result := 'StreamIsRecorded';
    Ord(ucPingRequest): Result := 'PingRequest';
    Ord(ucPingResponse): Result := 'PingResponse';
    Ord(ucBufferEmpty): Result := 'BufferEmpty';
    Ord(ucBufferReady): Result := 'BufferReady';
  else
    Result := 'Unknown';
  end;
end;

function PeerBandwidthLimitTypeName(ALimitType: Byte): string;
begin
  case ALimitType of
    0: Result := 'Hard';
    1: Result := 'Soft';
    2: Result := 'Dynamic';
  else
    Result := 'Unknown';
  end;
end;

function TimestampModeName(AMode: TRtmpTimestampMode): string;
begin
  case AMode of
    tmPassThrough: Result := 'pass-through';
    tmRebased: Result := 'rebased';
    tmSmoothed: Result := 'smoothed';
  else
    Result := 'unknown';
  end;
end;

function IsCodeInList(const ACode: string; const APrefixes: array of string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(APrefixes) do
    if SameText(Copy(ACode, 1, Length(APrefixes[I])), APrefixes[I]) then
      Exit(True);
end;

procedure FreePacketArray(var APackets: TRtmpPacketArray);
var
  I: Integer;
begin
  for I := 0 to High(APackets) do
    APackets[I].Free;
  APackets := nil;
end;

constructor TRtmpClientRelayThread.Create(AClient: TRtmpClient);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBytesReceived := 0;
  FClient := AClient;
  FIncomingChunkSize := 128;
  FInboundAckWindowSize := 0;
  FLastOutboundTimestamp := 0;
  FLastSentWindowAckSize := 0;
  FLastSourceTimestamp := 0;
  FMessageStreamID := 1;
  FNextAcknowledgementAt := 0;
  FNextSequenceNo := 0;
  FSessionEstablished := False;
  FTimestampBaseSource := 0;
  FTimestampStateInitialized := False;
end;

function TRtmpClientRelayThread.BuildPublishInfo(out ATarget: TRtmpTargetInfo): Boolean;
begin
  Result := ParseRtmpTarget(FClient.Config.TargetURL, FClient.Config.App,
    FClient.Config.StreamKey, ATarget);
end;

procedure TRtmpClientRelayThread.CloseConnection;
begin
  if Assigned(FClient) then
    FClient.CloseConnection;
end;

function TRtmpClientRelayThread.EstablishPublishSession(
  out ATarget: TRtmpTargetInfo): Boolean;
var
  ConnectInfo: TRtmpAmf0Object;
  ResponseState: TRtmpClientResponseState;
  Reassembler: TRtmpChunkReassembler;
  WaitDeadline: UInt64;
begin
  Result := False;
  if not BuildPublishInfo(ATarget) then
    raise Exception.Create('Client target URL, app, or stream key is incomplete');

  FBytesReceived := 0;
  FInboundAckWindowSize := 0;
  FLastSentWindowAckSize := 0;
  FNextAcknowledgementAt := 0;
  FClient.ChangeState(csConnecting);
  FClient.Log(llInfo, 'client',
    Format('Connecting to %s:%d app=%s stream=%s',
      [ATarget.Endpoint.Address, ATarget.Endpoint.Port, ATarget.AppName,
       ATarget.StreamKey]));

  FClient.FConnection := FClient.TransportFactory.CreateClientConnection(
    ATarget.Endpoint, FClient.Config.ConnectTimeoutMS);

  if not PerformHandshake then
    Exit;

  FClient.ChangeState(csPublishing);
  SendProtocolDefaults;

  ConnectInfo := BuildObject([
    'app', ATarget.AppName,
    'flashVer', 'TRTMP/0.1',
    'tcUrl', ATarget.TcUrl,
    'fpad', False,
    'capabilities', 15,
    'audioCodecs', 4071,
    'videoCodecs', 252,
    'videoFunction', 1,
    'objectEncoding', 0
  ]);
  try
    SendCommandMessage(3, 0, BuildCommandValueArray([
      TRtmpAmf0String.Create('connect'),
      TRtmpAmf0Number.Create(1),
      ConnectInfo
    ]));
  finally
    ConnectInfo.Free;
  end;

  Reassembler := TRtmpChunkReassembler.Create(FIncomingChunkSize);
  try
    ResponseState := Default(TRtmpClientResponseState);

    SendCommandMessage(3, 0, BuildCommandValueArray([
      TRtmpAmf0String.Create('releaseStream'),
      TRtmpAmf0Number.Create(2),
      TRtmpAmf0Null.Create,
      TRtmpAmf0String.Create(ATarget.StreamKey)
    ]));

    SendCommandMessage(3, 0, BuildCommandValueArray([
      TRtmpAmf0String.Create('FCPublish'),
      TRtmpAmf0Number.Create(3),
      TRtmpAmf0Null.Create,
      TRtmpAmf0String.Create(ATarget.StreamKey)
    ]));

    SendCommandMessage(3, 0, BuildCommandValueArray([
      TRtmpAmf0String.Create('createStream'),
      TRtmpAmf0Number.Create(4),
      TRtmpAmf0Null.Create
    ]));

    WaitDeadline := RtmpGetTickCount64 + 1500;
    while (not Terminated) and (RtmpGetTickCount64 < WaitDeadline) do
    begin
      PumpIncomingMessages(Reassembler, 100, ResponseState);
      if ResponseState.Failed then
        RaiseResponseFailure(ResponseState, 'session setup');
      if ResponseState.ConnectAccepted and ResponseState.CreateStreamAccepted then
        Break;
    end;

    if ResponseState.Failed then
      RaiseResponseFailure(ResponseState, 'session setup');
    if not (ResponseState.ConnectAccepted and ResponseState.CreateStreamAccepted) then
      raise Exception.Create('RTMP target did not complete connect/createStream handshake');

    if ResponseState.StreamID <> 0 then
      FMessageStreamID := ResponseState.StreamID;
    if FMessageStreamID = 0 then
      FMessageStreamID := 1;

    SendCommandMessage(8, FMessageStreamID, BuildCommandValueArray([
      TRtmpAmf0String.Create('publish'),
      TRtmpAmf0Number.Create(0),
      TRtmpAmf0Null.Create,
      TRtmpAmf0String.Create(ATarget.StreamKey),
      TRtmpAmf0String.Create('live')
    ]));

    WaitDeadline := RtmpGetTickCount64 + 1500;
    while (not Terminated) and (RtmpGetTickCount64 < WaitDeadline) and
      (not ResponseState.PublishAccepted) do
    begin
      PumpIncomingMessages(Reassembler, 1000, ResponseState);
      if ResponseState.Failed then
        RaiseResponseFailure(ResponseState, 'publish');
    end;

    if ResponseState.Failed then
      RaiseResponseFailure(ResponseState, 'publish');
    if not ResponseState.PublishAccepted then
      raise Exception.Create('RTMP target did not confirm publish');

    Result := True;
  finally
    Reassembler.Free;
  end;
end;

function TRtmpClientRelayThread.RunStreamingSession: Boolean;
var
  I: Integer;
  Packets: TRtmpPacketArray;
  Reassembler: TRtmpChunkReassembler;
  ResponseState: TRtmpClientResponseState;
  Target: TRtmpTargetInfo;
begin
  Result := False;
  FSessionEstablished := False;
  ResetTimestampState;
  if not EstablishPublishSession(Target) then
    Exit(False);

  FClient.ChangeState(csStreaming);
  FClient.Log(llInfo, 'client',
    Format('Publish established target=%s app=%s stream=%s tsMode=%s',
      [Target.Endpoint.Address, Target.AppName, Target.StreamKey,
       TimestampModeName(FClient.Config.TimestampMode)]));
  FSessionEstablished := True;
  if Assigned(FClient.FOnConnected) then
    FClient.FOnConnected(FClient);

  Reassembler := TRtmpChunkReassembler.Create(FIncomingChunkSize);
  try
    ResponseState := Default(TRtmpClientResponseState);
    SendInitialSnapshot;
    while not Terminated do
    begin
      if FClient.CurrentState <> csStreaming then
        Break;

      PumpIncomingMessages(Reassembler, 20, ResponseState);

      if FClient.FBuffer <> nil then
      begin
        Packets := FClient.FBuffer.GetSinceSequenceSnapshot(FNextSequenceNo);
        try
          for I := 0 to High(Packets) do
          begin
            SendPacketNow(Packets[I]);
            FNextSequenceNo := Packets[I].SequenceNo + 1;
          end;
        finally
          FreePacketArray(Packets);
        end;
      end;

      RtmpSleepMS(10);
    end;
  finally
    Reassembler.Free;
  end;

  Result := not Terminated;
end;

procedure TRtmpClientRelayThread.Execute;
var
  BackoffMS: Integer;
  DelayRemainingMS: Integer;
begin
  BackoffMS := FClient.Config.ReconnectDelayMS;
  if BackoffMS <= 0 then
    BackoffMS := 1000;

  while not Terminated do
  begin
    try
      RunStreamingSession;
    except
      on E: Exception do
      begin
        if not Terminated and (FClient.CurrentState <> csStopped) then
        begin
          FClient.ChangeState(csError);
          FClient.Log(llError, 'client', E.Message);
        end;
      end;
    end;

    CloseConnection;

    if Terminated or (FClient.CurrentState = csStopped) then
    begin
      if FSessionEstablished and Assigned(FClient.FOnDisconnected) then
        FClient.FOnDisconnected(FClient);
      Break;
    end;

    if FSessionEstablished and Assigned(FClient.FOnDisconnected) then
      FClient.FOnDisconnected(FClient);
    if FSessionEstablished then
      BackoffMS := FClient.Config.ReconnectDelayMS;

    FClient.NoteReconnect;
    FClient.ChangeState(csReconnecting);
    FClient.Log(llWarning, 'client',
      Format('Reconnecting in %d ms', [BackoffMS]));
    if Assigned(FClient.FOnReconnect) then
      FClient.FOnReconnect(FClient);

    DelayRemainingMS := BackoffMS;
    while (DelayRemainingMS > 0) and (not Terminated) and
      (FClient.CurrentState <> csStopped) do
    begin
      if DelayRemainingMS > 100 then
        RtmpSleepMS(100)
      else
        RtmpSleepMS(DelayRemainingMS);
      Dec(DelayRemainingMS, 100);
    end;

    if Terminated or (FClient.CurrentState = csStopped) then
      Break;

    if BackoffMS < FClient.Config.MaxReconnectDelayMS then
    begin
      BackoffMS := BackoffMS * 2;
      if BackoffMS > FClient.Config.MaxReconnectDelayMS then
        BackoffMS := FClient.Config.MaxReconnectDelayMS;
    end;
  end;

  CloseConnection;
  if FClient.CurrentState <> csStopped then
    FClient.ChangeState(csStopped);
end;

function TRtmpClientRelayThread.HandleIncomingCommand(
  const AMessage: TRtmpChunkMessage; var AResponseState: TRtmpClientResponseState): Boolean;
var
  Code: string;
  Command: TRtmpCommandMessage;
  Description: string;
  StreamIDValue: TRtmpAmf0Value;
  StatusObject: TRtmpAmf0Object;
begin
  Result := True;
  Command := TRtmpCommandMessage.Create(AMessage.Payload);
  try
    if Command.IsCommand('_result') then
    begin
      if SameValue(Command.TransactionID, 1.0, 0.001) then
      begin
        AResponseState.ConnectAccepted := True;
        FClient.Log(llInfo, 'client', 'connect accepted');
      end
      else if SameValue(Command.TransactionID, 4.0, 0.001) then
      begin
        AResponseState.CreateStreamAccepted := True;
        StreamIDValue := nil;
        if Command.ArgumentCount > 3 then
          StreamIDValue := Command[3];
        if StreamIDValue is TRtmpAmf0Number then
          AResponseState.StreamID := UInt32(Trunc(TRtmpAmf0Number(StreamIDValue).Value));
        FClient.Log(llInfo, 'client',
          Format('createStream accepted streamId=%d', [AResponseState.StreamID]));
      end;
    end
    else if Command.IsCommand('onStatus') then
    begin
      Code := '';
      Description := '';
      if (Command.ArgumentCount > 3) and (Command[3] is TRtmpAmf0Object) then
      begin
        StatusObject := TRtmpAmf0Object(Command[3]);
        Code := StatusObject.GetString('code');
        Description := StatusObject.GetString('description');
      end;

      if SameText(Code, 'NetStream.Publish.Start') then
      begin
        AResponseState.PublishAccepted := True;
        FClient.Log(llInfo, 'client', 'publish accepted');
      end
      else if SameText(Code, 'NetConnection.Connect.Success') then
      begin
        AResponseState.ConnectAccepted := True;
        FClient.Log(llInfo, 'client', 'connect accepted');
      end
      else if IsCodeInList(Code, ['NetConnection.Connect.Rejected',
        'NetConnection.Connect.InvalidApp', 'NetConnection.Connect.Failed']) then
        SetResponseFailure(AResponseState, 'connect', Code, Description)
      else if IsCodeInList(Code, ['NetStream.Publish.']) and
        (not SameText(Code, 'NetStream.Publish.Start')) then
        SetResponseFailure(AResponseState, 'publish', Code, Description)
      else if IsCodeInList(Code, ['NetStream.Failed', 'NetStream.Error']) then
      begin
        if FClient.CurrentState = csStreaming then
          raise Exception.CreateFmt('Target stream failure %s: %s', [Code, Description])
        else
          SetResponseFailure(AResponseState, 'publish', Code, Description);
      end
      else if Code <> '' then
        FClient.Log(llInfo, 'client', Format('onStatus code=%s description=%s',
          [Code, Description]));
    end
    else if Command.IsCommand('_error') then
    begin
      Code := '';
      Description := '';
      if (Command.ArgumentCount > 3) and (Command[3] is TRtmpAmf0Object) then
      begin
        StatusObject := TRtmpAmf0Object(Command[3]);
        Code := StatusObject.GetString('code');
        Description := StatusObject.GetString('description');
      end;

      if SameValue(Command.TransactionID, 1.0, 0.001) then
        SetResponseFailure(AResponseState, 'connect', Code, Description)
      else if SameValue(Command.TransactionID, 4.0, 0.001) then
        SetResponseFailure(AResponseState, 'createStream', Code, Description)
      else if SameValue(Command.TransactionID, 2.0, 0.001) or
        SameValue(Command.TransactionID, 3.0, 0.001) then
        FClient.Log(llWarning, 'client', Format(
          'Optional command rejected transaction=%.0f code=%s description=%s',
          [Command.TransactionID, Code, Description]))
      else if FClient.CurrentState = csStreaming then
        raise Exception.CreateFmt('RTMP target returned _error code=%s description=%s',
          [Code, Description])
      else
        SetResponseFailure(AResponseState, 'publish', Code, Description);
    end;
  finally
    Command.Free;
  end;
end;

function TRtmpClientRelayThread.HandleIncomingMessage(
  const AMessage: TRtmpChunkMessage; AReassembler: TRtmpChunkReassembler;
  var AResponseState: TRtmpClientResponseState): Boolean;
var
  AbortChunkStreamID: UInt32;
  LimitTypeName: string;
  Reader: TRtmpByteReader;
  WindowSize: UInt32;
begin
  Result := True;
  case AMessage.MessageType of
    mtAbort:
      begin
        Reader := TRtmpByteReader.Create(AMessage.Payload);
        try
          if Reader.Remaining >= 4 then
          begin
            AbortChunkStreamID := Reader.ReadUInt32BE;
            if AReassembler <> nil then
              AReassembler.AbortChunkStream(AbortChunkStreamID);
            FClient.Log(llInfo, 'protocol',
              Format('Server aborted chunk stream %d', [AbortChunkStreamID]));
          end;
        finally
          Reader.Free;
        end;
      end;
    mtSetChunkSize:
      begin
        Reader := TRtmpByteReader.Create(AMessage.Payload);
        try
          FIncomingChunkSize := Reader.ReadUInt32BE;
          FClient.Log(llInfo, 'protocol',
            Format('Server inbound chunk size changed to %d', [FIncomingChunkSize]));
        finally
          Reader.Free;
        end;
      end;
    mtWindowAckSize:
      begin
        Reader := TRtmpByteReader.Create(AMessage.Payload);
        try
          if Reader.Remaining >= 4 then
          begin
            WindowSize := Reader.ReadUInt32BE;
            FInboundAckWindowSize := WindowSize;
            if WindowSize = 0 then
              FNextAcknowledgementAt := 0
            else if FNextAcknowledgementAt < FBytesReceived + WindowSize then
              FNextAcknowledgementAt := FBytesReceived + WindowSize;
            FClient.Log(llInfo, 'protocol',
              Format('Server window acknowledgement size=%d', [WindowSize]));
            MaybeSendAcknowledgement;
          end;
        finally
          Reader.Free;
        end;
      end;
    mtSetPeerBandwidth:
      begin
        Reader := TRtmpByteReader.Create(AMessage.Payload);
        try
          if Reader.Remaining >= 5 then
          begin
            WindowSize := Reader.ReadUInt32BE;
            LimitTypeName := PeerBandwidthLimitTypeName(Reader.ReadUInt8);
            if (WindowSize <> 0) and (FLastSentWindowAckSize <> WindowSize) then
              SendWindowAckSize(WindowSize);
            if (FInboundAckWindowSize = 0) and (WindowSize <> 0) then
            begin
              FInboundAckWindowSize := WindowSize;
              FNextAcknowledgementAt := FBytesReceived + WindowSize;
            end;
            FClient.Log(llInfo, 'protocol',
              Format('Server peer bandwidth=%d limit=%s', [WindowSize, LimitTypeName]));
          end;
        finally
          Reader.Free;
        end;
      end;
    mtAck:
      ;
    mtUserControl:
      Result := HandleIncomingUserControl(AMessage);
    mtCommandAMF3:
      raise Exception.Create(
        'RTMP target used unsupported AMF3 command messages; use objectEncoding=0');
    mtCommandAMF0:
      Result := HandleIncomingCommand(AMessage, AResponseState);
  end;
end;

function TRtmpClientRelayThread.HandleIncomingUserControl(
  const AMessage: TRtmpChunkMessage): Boolean;
var
  EventType: Word;
  Reader: TRtmpByteReader;
  Value1: UInt32;
begin
  Result := True;
  Reader := TRtmpByteReader.Create(AMessage.Payload);
  try
    if Reader.Remaining < 2 then
      Exit;

    EventType := Reader.ReadUInt16BE;
    Value1 := 0;
    if Reader.Remaining >= 4 then
      Value1 := Reader.ReadUInt32BE;

    case EventType of
      Ord(ucPingRequest):
        begin
          SendUserControl(Ord(ucPingResponse), Value1);
          FClient.Log(llInfo, 'protocol',
            Format('Responded to server ping timestamp=%d', [Value1]));
        end;
    else
      FClient.Log(llDebug, 'protocol',
        Format('Server UserControl %s(%d)', [UserControlEventName(EventType), EventType]));
    end;
  finally
    Reader.Free;
  end;
end;

function TRtmpClientRelayThread.IsStreamingFailureCode(const ACode: string): Boolean;
begin
  Result := IsCodeInList(ACode, ['NetStream.Publish.', 'NetStream.Failed',
    'NetStream.Error', 'NetConnection.Connect.Rejected',
    'NetConnection.Connect.InvalidApp', 'NetConnection.Connect.Failed']) and
    (not SameText(ACode, 'NetStream.Publish.Start'));
end;

procedure TRtmpClientRelayThread.MaybeSendAcknowledgement;
begin
  if (FInboundAckWindowSize = 0) or (FBytesReceived < FNextAcknowledgementAt) then
    Exit;

  SendWindowAcknowledgement(UInt32(FBytesReceived and High(UInt32)));
  while FNextAcknowledgementAt <= FBytesReceived do
    Inc(FNextAcknowledgementAt, FInboundAckWindowSize);
end;

procedure TRtmpClientRelayThread.NoteBytesReceived(ACount: Integer);
begin
  if ACount <= 0 then
    Exit;

  Inc(FBytesReceived, UInt64(ACount));
  MaybeSendAcknowledgement;
end;

function TRtmpClientRelayThread.MapPacketTimestamp(const APacket: TRtmpPacket): UInt32;
var
  Delta: UInt32;
begin
  if APacket = nil then
    Exit(0);

  case FClient.Config.TimestampMode of
    tmPassThrough:
      Result := APacket.Timestamp;
    tmRebased:
      begin
        if not FTimestampStateInitialized then
        begin
          FTimestampBaseSource := APacket.Timestamp;
          FLastSourceTimestamp := APacket.Timestamp;
          FLastOutboundTimestamp := 0;
          FTimestampStateInitialized := True;
        end;

        if APacket.Timestamp >= FTimestampBaseSource then
          Result := APacket.Timestamp - FTimestampBaseSource
        else
          Result := 0;

        FLastSourceTimestamp := APacket.Timestamp;
        FLastOutboundTimestamp := Result;
      end;
    tmSmoothed:
      begin
        if not FTimestampStateInitialized then
        begin
          FTimestampBaseSource := APacket.Timestamp;
          FLastSourceTimestamp := APacket.Timestamp;
          FLastOutboundTimestamp := 0;
          FTimestampStateInitialized := True;
          Exit(0);
        end;

        if APacket.Timestamp >= FLastSourceTimestamp then
          Delta := APacket.Timestamp - FLastSourceTimestamp
        else
          Delta := 0;

        Result := FLastOutboundTimestamp + Delta;
        FLastSourceTimestamp := APacket.Timestamp;
        FLastOutboundTimestamp := Result;
      end;
  else
    Result := APacket.Timestamp;
  end;
end;

function TRtmpClientRelayThread.PerformHandshake: Boolean;
var
  C0C1: TBytes;
  C2: TBytes;
  S0: TBytes;
  S1: TBytes;
  S2: TBytes;
begin
  Result := False;
  C0C1 := TRtmpHandshake.BuildC0C1;
  SendBytes(C0C1);

  if not ReadExact(1, S0) then
    Exit;
  if S0[0] <> RTMP_VERSION then
    raise ERtmpProtocolError.CreateFmt('Unsupported RTMP version %d', [S0[0]]);

  if not ReadExact(RTMP_HANDSHAKE_SIZE, S1) then
    Exit;
  C2 := TRtmpHandshake.BuildC2(S1);
  SendBytes(C2);

  if not ReadExact(RTMP_HANDSHAKE_SIZE, S2) then
    Exit;

  FClient.Log(llInfo, 'client', 'Outbound RTMP handshake completed');
  Result := True;
end;

procedure TRtmpClientRelayThread.ResetTimestampState;
begin
  FTimestampBaseSource := 0;
  FLastSourceTimestamp := 0;
  FLastOutboundTimestamp := 0;
  FTimestampStateInitialized := False;
end;

procedure TRtmpClientRelayThread.RaiseResponseFailure(
  const AResponseState: TRtmpClientResponseState; const ADefaultStage: string);
var
  FailureStage: string;
begin
  if not AResponseState.Failed then
    Exit;

  FailureStage := AResponseState.FailureStage;
  if FailureStage = '' then
    FailureStage := ADefaultStage;

  raise Exception.CreateFmt('RTMP target rejected %s code=%s description=%s',
    [FailureStage, AResponseState.FailureCode, AResponseState.FailureDescription]);
end;

procedure TRtmpClientRelayThread.SetResponseFailure(
  var AResponseState: TRtmpClientResponseState; const AStage, ACode,
  ADescription: string);
begin
  if AResponseState.Failed then
    Exit;

  AResponseState.Failed := True;
  AResponseState.FailureStage := AStage;
  AResponseState.FailureCode := ACode;
  AResponseState.FailureDescription := ADescription;
  FClient.Log(llWarning, 'client', Format(
    'Target rejected %s code=%s description=%s', [AStage, ACode, ADescription]));

  if (FClient.CurrentState = csStreaming) and IsStreamingFailureCode(ACode) then
    RaiseResponseFailure(AResponseState, AStage);
end;

procedure TRtmpClientRelayThread.PumpIncomingMessages(
  AReassembler: TRtmpChunkReassembler; ATimeoutMS: Integer;
  var AResponseState: TRtmpClientResponseState);
var
  Buffer: TBytes;
  MessageOut: TRtmpChunkMessage;
begin
  if not Assigned(AReassembler) then
    Exit;

  if ReadOneOrMoreBytes(ATimeoutMS, Buffer) then
  begin
    AReassembler.InChunkSize := FIncomingChunkSize;
    AReassembler.AppendBytes(Buffer);
    while AReassembler.TryReadMessage(MessageOut) do
    begin
      HandleIncomingMessage(MessageOut, AReassembler, AResponseState);
      AReassembler.InChunkSize := FIncomingChunkSize;
    end;
  end;
end;

function TRtmpClientRelayThread.ReadExact(ACount: Integer; out ABytes: TBytes): Boolean;
var
  Offset: Integer;
  Received: Integer;
begin
  Result := False;
  Offset := 0;
  SetLength(ABytes, ACount);
  while Offset < ACount do
  begin
    try
      Received := FClient.FConnection.Receive(ABytes[Offset], ACount - Offset,
        FClient.Config.ConnectTimeoutMS);
    except
      if Terminated or (FClient.CurrentState = csStopped) then
        Exit(False);
      raise;
    end;
    if Received <= 0 then
    begin
      if not FClient.FConnection.Connected then
        Exit(False);
      Continue;
    end;
    Inc(Offset, Received);
  end;
  Result := True;
end;

function TRtmpClientRelayThread.ReadOneOrMoreBytes(ATimeoutMS: Integer;
  out ABytes: TBytes): Boolean;
var
  Buffer: array[0..8191] of Byte;
  Received: Integer;
begin
  Result := False;
  ABytes := nil;
  if not Assigned(FClient.FConnection) then
    Exit;

  try
    Received := FClient.FConnection.Receive(Buffer, SizeOf(Buffer), ATimeoutMS);
  except
    if Terminated or (FClient.CurrentState = csStopped) then
      Exit(False);
    raise;
  end;
  if Received <= 0 then
    Exit;

  SetLength(ABytes, Received);
  Move(Buffer[0], ABytes[0], Received);
  NoteBytesReceived(Received);
  Result := True;
end;

procedure TRtmpClientRelayThread.SendBytes(const ABytes: TBytes);
begin
  if Length(ABytes) = 0 then
    Exit;
  SendBuffer(@ABytes[0], Length(ABytes));
end;

procedure TRtmpClientRelayThread.SendBuffer(ABuffer: Pointer; ACount: Integer);
var
  Cursor: PByte;
  Offset: Integer;
  Sent: Integer;
begin
  if ACount <= 0 then
    Exit;

  if ABuffer = nil then
    raise ERtmpTransportError.Create('Cannot send nil buffer');

  Cursor := PByte(ABuffer);
  Offset := 0;
  while Offset < ACount do
  begin
    Sent := FClient.FConnection.Send(Cursor^, ACount - Offset, 10000);
    if Sent <= 0 then
      raise ERtmpTransportError.Create('Outbound socket send timed out or failed');
    Inc(Cursor, Sent);
    Inc(Offset, Sent);
  end;
end;

procedure TRtmpClientRelayThread.SendCommandMessage(AChunkStreamID,
  AMessageStreamID: UInt32; const AValues: array of TObject);
var
  I: Integer;
  Payload: TBytes;
  Values: TRtmpAmf0ValueList;
begin
  Values := TRtmpAmf0ValueList.Create(True);
  try
    for I := 0 to High(AValues) do
    begin
      if AValues[I] is TRtmpAmf0Value then
        Values.AddValue(TRtmpAmf0Value(AValues[I]).Clone)
      else
        raise Exception.Create('SendCommandMessage only accepts TRtmpAmf0Value objects');
    end;
    Payload := TRtmpAmf0.EncodeValues(Values);
  finally
    Values.Free;
  end;

  SendRtmpMessage(AChunkStreamID, AMessageStreamID,
    RtmpMessageTypeID(mtCommandAMF0), 0, Payload);
end;

procedure TRtmpClientRelayThread.SendInitialSnapshot;
var
  Headers: TRtmpPacketArray;
  I: Integer;
  Packets: TRtmpPacketArray;
begin
  if (FClient = nil) or (FClient.FBuffer = nil) then
    Exit;

  Headers := FClient.FBuffer.GetCodecHeadersSnapshot;
  try
    for I := 0 to High(Headers) do
    begin
      SendPacketNow(Headers[I]);
      if Headers[I].SequenceNo >= FNextSequenceNo then
        FNextSequenceNo := Headers[I].SequenceNo + 1;
    end;
  finally
    FreePacketArray(Headers);
  end;

  FNextSequenceNo := FClient.FBuffer.GetBootstrapSequenceNo(FNextSequenceNo);
  Packets := FClient.FBuffer.GetSinceSequenceSnapshot(FNextSequenceNo);
  try
    for I := 0 to High(Packets) do
    begin
      if Packets[I].SequenceNo < FNextSequenceNo then
        Continue;
      SendPacketNow(Packets[I]);
      FNextSequenceNo := Packets[I].SequenceNo + 1;
    end;
  finally
    FreePacketArray(Packets);
  end;
end;

procedure TRtmpClientRelayThread.SendPacketNow(const APacket: TRtmpPacket);
var
  ChunkStreamID: UInt32;
  OutTimestamp: UInt32;
begin
  if APacket = nil then
    Exit;

  case APacket.MessageType of
    mtAudio:
      ChunkStreamID := 4;
    mtVideo:
      ChunkStreamID := 6;
    mtDataAMF0, mtDataAMF3:
      ChunkStreamID := 5;
  else
    Exit;
  end;

  OutTimestamp := MapPacketTimestamp(APacket);
  SendRtmpMessage(ChunkStreamID, FMessageStreamID,
    RtmpMessageTypeID(APacket.MessageType), OutTimestamp,
    APacket.Payload.Bytes);
  FClient.NoteSentPacket(APacket);

  if APacket.HasFlag(pfIsCodecConfig) or APacket.HasFlag(pfIsKeyframe) then
    FClient.Log(llInfo, 'client',
      Format('Relay packet seq=%d type=%d inTs=%d outTs=%d size=%d keyframe=%s config=%s',
        [APacket.SequenceNo, Ord(APacket.MessageType), APacket.Timestamp,
         OutTimestamp, APacket.PayloadSize,
         BoolToStr(APacket.HasFlag(pfIsKeyframe), True),
         BoolToStr(APacket.HasFlag(pfIsCodecConfig), True)]));
end;

procedure TRtmpClientRelayThread.SendProtocolDefaults;
begin
  SendSetChunkSize(FClient.FOutChunkSize);
end;

procedure TRtmpClientRelayThread.SendRtmpMessage(AChunkStreamID,
  AMessageStreamID: UInt32; AMessageTypeID: Byte; ATimestamp: UInt32;
  const APayload: TBytes);
var
  ChunkDataSize: Integer;
  ChunkOffset: Integer;
  Header: TRtmpChunkMessageHeader;
  Writer: TRtmpByteWriter;
begin
  Header := Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat := hfType0;
  Header.Timestamp := ATimestamp;
  Header.MessageLength := Length(APayload);
  Header.MessageTypeID := AMessageTypeID;
  Header.MessageStreamID := AMessageStreamID;
  Header.HasExtendedTimestamp := ATimestamp >= RTMP_TIMESTAMP_EXTENDED;

  Writer := TRtmpByteWriter.Create(Integer(FClient.FOutChunkSize) + 32);
  try
    ChunkOffset := 0;
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

      ChunkDataSize := Length(APayload) - ChunkOffset;
      if ChunkDataSize > Integer(FClient.FOutChunkSize) then
        ChunkDataSize := FClient.FOutChunkSize;

      Writer.WriteBytesRange(APayload, ChunkOffset, ChunkDataSize);
      SendBuffer(Writer.Data, Writer.Size);
      Inc(ChunkOffset, ChunkDataSize);
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

procedure TRtmpClientRelayThread.SendSetChunkSize(AChunkSize: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer := TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AChunkSize);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtSetChunkSize), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TRtmpClientRelayThread.SendUserControl(AEventType: Word;
  AValue1: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer := TRtmpByteWriter.Create;
  try
    Writer.WriteUInt16BE(AEventType);
    Writer.WriteUInt32BE(AValue1);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtUserControl), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TRtmpClientRelayThread.SendWindowAckSize(AWindowSize: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer := TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AWindowSize);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtWindowAckSize), 0, Writer.ToBytes);
    FLastSentWindowAckSize := AWindowSize;
  finally
    Writer.Free;
  end;
end;

procedure TRtmpClientRelayThread.SendWindowAcknowledgement(ASequence: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer := TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(ASequence);
    SendRtmpMessage(2, 0, RtmpMessageTypeID(mtAck), 0, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

function TRtmpClientRelayThread.WaitForSessionReady(
  AReassembler: TRtmpChunkReassembler;
  var AResponseState: TRtmpClientResponseState; ATimeoutMS: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Result := False;
  Deadline := RtmpGetTickCount64 + UInt64(ATimeoutMS);
  while not Terminated do
  begin
    PumpIncomingMessages(AReassembler, 250, AResponseState);
    if AResponseState.ConnectAccepted and AResponseState.CreateStreamAccepted then
      Exit(True);
    if RtmpGetTickCount64 >= Deadline then
      Exit(False);
  end;
end;

constructor TRtmpClient.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FConfig := DefaultRtmpClientConfig;
  FLog := TRtmpLogSink.Create;
  FState := csStopped;
  FTransactionID := 1.0;
  FTransportFactory := TRtmpNativeTransportFactory.Create;
  FRelayThread := nil;
  FOutChunkSize := 4096;
  ResetStats;
end;

destructor TRtmpClient.Destroy;
begin
  Stop;
  FLock.Free;
  FLog.Free;
  inherited Destroy;
end;

procedure TRtmpClient.AttachBuffer(ABuffer: TRtmpCircularBuffer);
begin
  FBuffer := ABuffer;
end;

procedure TRtmpClient.ChangeState(AState: TRtmpClientState);
begin
  FLock.Acquire;
  try
    FState := AState;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpClient.CloseConnection;
begin
  FLock.Acquire;
  try
    if FConnection <> nil then
      FConnection.Close;
    FConnection := nil;
  finally
    FLock.Release;
  end;
end;

function TRtmpClient.CurrentState: TRtmpClientState;
begin
  FLock.Acquire;
  try
    Result := FState;
  finally
    FLock.Release;
  end;
end;

function TRtmpClient.GetStats: TRtmpClientStats;
begin
  FLock.Acquire;
  try
    RecalculateBitrate;
    Result := FStats;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpClient.Log(ALevel: TRtmpLogLevel; const ACategory,
  AMessage: string);
begin
  FLog.Log(Self, ALevel, ACategory, AMessage);
end;

procedure TRtmpClient.NoteReconnect;
begin
  FLock.Acquire;
  try
    Inc(FStats.Reconnects);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpClient.NoteSentPacket(const APacket: TRtmpPacket);
begin
  if APacket = nil then
    Exit;

  FLock.Acquire;
  try
    Inc(FStats.PacketsSent);
    Inc(FStats.BytesSent, UInt64(APacket.PayloadSize));
    FStats.LastSendTick := RtmpGetTickCount64;
    RecalculateBitrate;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpClient.RecalculateBitrate;
var
  DeltaBytes: UInt64;
  DeltaMS: UInt64;
  NowTick: TRtmpTick;
  UptimeMS: UInt64;
begin
  NowTick := RtmpGetTickCount64;
  UptimeMS := NowTick - FStartedAt;
  if UptimeMS > 0 then
    FStats.AverageBitrate := (FStats.BytesSent * 8.0 * 1000.0) / UptimeMS
  else
    FStats.AverageBitrate := 0.0;

  DeltaMS := NowTick - FLastBitrateTick;
  if DeltaMS > 0 then
  begin
    DeltaBytes := FStats.BytesSent - FLastBitrateBytes;
    FStats.CurrentBitrate := (DeltaBytes * 8.0 * 1000.0) / DeltaMS;
    FLastBitrateTick := NowTick;
    FLastBitrateBytes := FStats.BytesSent;
  end
  else
    FStats.CurrentBitrate := 0.0;
end;

procedure TRtmpClient.ResetStats;
begin
  FLock.Acquire;
  try
    FillChar(FStats, SizeOf(FStats), 0);
    FStartedAt := RtmpGetTickCount64;
    FLastBitrateTick := FStartedAt;
    FLastBitrateBytes := 0;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpClient.SendPacket(const APacket: TRtmpPacket);
begin
  if APacket = nil then
    Exit;

  NoteSentPacket(APacket);
end;

procedure TRtmpClient.Start;
begin
  if CurrentState <> csStopped then
    Exit;

  ResetStats;
  FOutChunkSize := UInt32(FConfig.OutChunkSize);
  if FOutChunkSize = 0 then
    FOutChunkSize := 4096;

  FRelayThread := TRtmpClientRelayThread.Create(Self);
  FRelayThread.Start;
end;

procedure TRtmpClient.Stop;
begin
  if CurrentState = csStopped then
    Exit;

  ChangeState(csStopped);

  if FRelayThread <> nil then
  begin
    FRelayThread.Terminate;
    CloseConnection;
    FRelayThread.WaitFor;
    FreeAndNil(FRelayThread);
  end
  else
    CloseConnection;

  Log(llInfo, 'client', 'Client relay stopped');
end;

end.

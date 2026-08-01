program RtmpClientReconnectLiveEdgeSmoke;

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
  TRTMP.RTMP.Protocol.AMF0,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.Core.Bytes,
  TRTMP.RTMP.Protocol.Chunk,
  TRTMP.RTMP.Client,
  TRTMP.RTMP.Protocol.Command,
  TRTMP.RTMP.Protocol.FLV,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Protocol.Core,
  TRTMP.Transport,
  TRTMP.Transport.Native,
  TRTMP.RTMP.Types;

type
  TLiveEdgeTargetThread = class(TThread)
  private
    FFirstVideoTimestamps: array[0..1] of UInt32;
    FConfigSeen: array[0..1] of Boolean;
    FFirstFrameHadConfig: array[0..1] of Boolean;
    FLastError: string;
    FReconnectRequestSent: Boolean;
    FListener: IRtmpListener;
    FTransportFactory: IRtmpTransportFactory;
    function BuildObject(const APairs: array of const): TRtmpAmf0Object;
    function ReadExact(const AConnection: IRtmpConnection; ACount,
      ATimeoutMS: Integer; out ABytes: TBytes): Boolean;
    function ReadOneOrMoreBytes(const AConnection: IRtmpConnection; ATimeoutMS: Integer;
      out ABytes: TBytes): Boolean;
    procedure RunOneSession(const AConnection: IRtmpConnection; ASessionIndex: Integer);
    procedure SendCommandMessage(const AConnection: IRtmpConnection; AChunkStreamID,
      AMessageStreamID: UInt32; const AValues: array of TObject);
    procedure SendConnectResult(const AConnection: IRtmpConnection;
      ATransactionID: Double);
    procedure SendCreateStreamResult(const AConnection: IRtmpConnection;
      ATransactionID: Double);
    procedure SendProtocolDefaults(const AConnection: IRtmpConnection);
    procedure SendPublishStart(const AConnection: IRtmpConnection);
    procedure SendReconnectRequest(const AConnection: IRtmpConnection);
    procedure SendRawBytes(const AConnection: IRtmpConnection; const ABytes: TBytes);
    procedure SendRtmpMessage(const AConnection: IRtmpConnection; AChunkStreamID,
      AMessageStreamID: UInt32; AMessageTypeID: Byte; ATimestamp: UInt32;
      const APayload: TBytes);
    procedure SendSetChunkSize(const AConnection: IRtmpConnection; AChunkSize: UInt32);
    procedure SendSetPeerBandwidth(const AConnection: IRtmpConnection;
      AValue: UInt32; ALimitType: Byte);
    procedure SendUserControl(const AConnection: IRtmpConnection; AEventType: Word;
      AValue1: UInt32);
    procedure SendWindowAckSize(const AConnection: IRtmpConnection; AValue: UInt32);
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Word);
    destructor Destroy; override;
    function FirstVideoTimestamp(AIndex: Integer): UInt32;
    function FirstFrameHadConfig(AIndex: Integer): Boolean;
    property LastError: string read FLastError;
  end;

  TReconnectLiveEdgeSmokeApp = class
  private
    FClient: TRtmpClient;
    FNextSequenceNo: UInt64;
    FSourceBuffer: TRtmpCircularBuffer;
    FTarget: TLiveEdgeTargetThread;
    procedure PushOutagePackets;
    procedure PushPacket(AMessageType: TRtmpMessageType; ATimestamp: UInt32;
      AChunkStreamID: UInt32; const APayloadBytes: array of Byte;
      AFlags: TRtmpPacketFlags);
    procedure SeedBootstrap;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result:=nil;
  SetLength(Result, Length(AValues));
  for I:=0 to High(AValues) do
    Result[I]:=AValues[I];
end;

constructor TLiveEdgeTargetThread.Create(APort: Word);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FLastError:='';
  FReconnectRequestSent:=False;
  FFirstVideoTimestamps[0]:=High(UInt32);
  FFirstVideoTimestamps[1]:=High(UInt32);
  FConfigSeen[0]:=False;
  FConfigSeen[1]:=False;
  FFirstFrameHadConfig[0]:=False;
  FFirstFrameHadConfig[1]:=False;
  FTransportFactory:=TRtmpNativeTransportFactory.Create;
  FListener:=FTransportFactory.CreateListener(
    TRtmpSocketEndpoint.Create('127.0.0.1', APort), 4);
end;

destructor TLiveEdgeTargetThread.Destroy;
begin
  if FListener <> nil then
    FListener.Close;
  inherited Destroy;
end;

function TLiveEdgeTargetThread.BuildObject(
  const APairs: array of const): TRtmpAmf0Object;
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
        Result.Add(KeyName, TRtmpAmf0String.Create(
          string(AnsiString(APairs[I + 1].VAnsiString))));
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
    else
      raise Exception.Create('Unsupported BuildObject value type');
    end;

    Inc(I, 2);
  end;
end;

procedure TLiveEdgeTargetThread.Execute;
var
  Connection: IRtmpConnection;
  SessionIndex: Integer;
begin
  SessionIndex:=0;
  while (NOT Terminated) AND (SessionIndex < 2) do
  begin
    if FListener = nil then
      Break;

    Connection:=FListener.Accept(200);
    if Connection = nil then
      Continue;

    try
      RunOneSession(Connection, SessionIndex);
    except
      on E: Exception do
      begin
        FLastError:=E.Message;
        Break;
      end;
    end;

    Inc(SessionIndex);
  end;
end;

function TLiveEdgeTargetThread.FirstVideoTimestamp(AIndex: Integer): UInt32;
begin
  if (AIndex < Low(FFirstVideoTimestamps)) OR (AIndex > High(FFirstVideoTimestamps)) then
    Exit(High(UInt32));
  Result:=FFirstVideoTimestamps[AIndex];
end;

function TLiveEdgeTargetThread.FirstFrameHadConfig(AIndex: Integer): Boolean;
begin
  if (AIndex < Low(FFirstFrameHadConfig)) OR
    (AIndex > High(FFirstFrameHadConfig)) then
    Exit(False);
  Result:=FFirstFrameHadConfig[AIndex];
end;

function TLiveEdgeTargetThread.ReadExact(const AConnection: IRtmpConnection;
  ACount, ATimeoutMS: Integer; out ABytes: TBytes): Boolean;
var
  Offset: Integer;
  Received: Integer;
begin
  Result:=False;
  Offset:=0;
  SetLength(ABytes, ACount);
  while Offset < ACount do
  begin
    Received:=AConnection.Receive(ABytes[Offset], ACount - Offset, ATimeoutMS);
    if Received <= 0 then
      Exit(False);
    Inc(Offset, Received);
  end;
  Result:=True;
end;

function TLiveEdgeTargetThread.ReadOneOrMoreBytes(const AConnection: IRtmpConnection;
  ATimeoutMS: Integer; out ABytes: TBytes): Boolean;
var
  Buffer: array[0..8191] of Byte;
  Received: Integer;
begin
  Result:=False;
  ABytes:=nil;
  Received:=AConnection.Receive(Buffer, SizeOf(Buffer), ATimeoutMS);
  if Received <= 0 then
    Exit(False);
  SetLength(ABytes, Received);
  Move(Buffer[0], ABytes[0], Received);
  Result:=True;
end;

procedure TLiveEdgeTargetThread.RunOneSession(const AConnection: IRtmpConnection;
  ASessionIndex: Integer);
var
  BytesIn: TBytes;
  C0C1: TBytes;
  C2: TBytes;
  Command: TRtmpCommandMessage;
  MessageOut: TRtmpChunkMessage;
  Reassembler: TRtmpChunkReassembler;
  S0S1S2: TBytes;
begin
  if NOT ReadExact(AConnection, 1 + RTMP_HANDSHAKE_SIZE, 3000, C0C1) then
    Exit;
  if C0C1[0] <> RTMP_VERSION then
    Exit;

  SetLength(BytesIn, RTMP_HANDSHAKE_SIZE);
  Move(C0C1[1], BytesIn[0], RTMP_HANDSHAKE_SIZE);
  S0S1S2:=TRtmpHandshake.BuildS0S1S2(BytesIn);
  SendRawBytes(AConnection, S0S1S2);
  if NOT ReadExact(AConnection, RTMP_HANDSHAKE_SIZE, 3000, C2) then
    Exit;

  SendProtocolDefaults(AConnection);
  Reassembler:=TRtmpChunkReassembler.Create(4096);
  try
    while NOT Terminated do
    begin
      if NOT ReadOneOrMoreBytes(AConnection, 3000, BytesIn) then
        Exit;

      Reassembler.AppendBytes(BytesIn);
      while Reassembler.TryReadMessage(MessageOut) do
      begin
        case MessageOut.MessageType of
          mtSetChunkSize:
            begin
              if Length(MessageOut.Payload) >= 4 then
                Reassembler.InChunkSize:=TRtmpByteReader.Create(
                  MessageOut.Payload).ReadUInt32BE;
            end;
          mtCommandAMF0:
            begin
              Command:=TRtmpCommandMessage.Create(MessageOut.Payload);
              try
                if Command.IsCommand('connect') then
                  SendConnectResult(AConnection, Command.TransactionID)
                else if Command.IsCommand('createStream') then
                  SendCreateStreamResult(AConnection, Command.TransactionID)
                else if Command.IsCommand('publish') then
                  SendPublishStart(AConnection);
              finally
                Command.Free;
              end;
            end;
          mtVideo:
            if (Length(MessageOut.Payload) >= 5) AND
              ((MessageOut.Payload[0] AND $80) <> 0) AND
              ((MessageOut.Payload[0] AND $0F) = 0) AND
              (MessageOut.Payload[1] = Ord('h')) AND
              (MessageOut.Payload[2] = Ord('v')) AND
              (MessageOut.Payload[3] = Ord('c')) AND
              (MessageOut.Payload[4] = Ord('1')) then
              FConfigSeen[ASessionIndex]:=True
            else if (Length(MessageOut.Payload) >= 5) AND
              ((MessageOut.Payload[0] AND $80) <> 0) AND
              ((MessageOut.Payload[0] AND $0F) IN [1, 3]) AND
              (((MessageOut.Payload[0] SHR 4) AND $07) = 1) AND
              (FFirstVideoTimestamps[ASessionIndex] = High(UInt32)) then
            begin
              FFirstVideoTimestamps[ASessionIndex]:=MessageOut.Timestamp;
              FFirstFrameHadConfig[ASessionIndex]:=FConfigSeen[ASessionIndex];
              if (ASessionIndex = 0) AND (NOT FReconnectRequestSent) then
              begin
                FReconnectRequestSent:=True;
                SendReconnectRequest(AConnection);
              end
              else if ASessionIndex = 1 then
              begin
                AConnection.Close;
                Exit;
              end;
            end;
        end;
      end;
    end;
  finally
    Reassembler.Free;
  end;
end;

procedure TLiveEdgeTargetThread.SendCommandMessage(const AConnection: IRtmpConnection;
  AChunkStreamID, AMessageStreamID: UInt32; const AValues: array of TObject);
type
  TObjectArray = array of TObject;
var
  I: Integer;
  Payload: TBytes;
  TempValues: TObjectArray;
  Values: TRtmpAmf0ValueList;
begin
  SetLength(TempValues, Length(AValues));
  for I:=0 to High(AValues) do
    TempValues[I]:=AValues[I];

  Values:=TRtmpAmf0ValueList.Create(True);
  try
    for I:=0 to High(TempValues) do
      Values.AddValue(TRtmpAmf0Value(TempValues[I]).Clone);
    Payload:=TRtmpAmf0.EncodeValues(Values);
  finally
    Values.Free;
  end;

  SendRtmpMessage(AConnection, AChunkStreamID, AMessageStreamID,
    RtmpMessageTypeID(mtCommandAMF0), 0, Payload);
end;

procedure TLiveEdgeTargetThread.SendConnectResult(const AConnection: IRtmpConnection;
  ATransactionID: Double);
var
  ServerInfo: TRtmpAmf0Object;
  StatusInfo: TRtmpAmf0Object;
begin
  ServerInfo:=BuildObject([
    'fmsVer', 'FMS/3,5,1,516',
    'capabilities', 31,
    'capsEx', RTMP_DEFAULT_ENHANCED_CAPABILITIES
  ]);
  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetConnection.Connect.Success',
    'description', 'Connection succeeded.',
    'objectEncoding', 0
  ]);
  try
    SendCommandMessage(AConnection, 3, 0, [
      TRtmpAmf0String.Create('_result'),
      TRtmpAmf0Number.Create(ATransactionID),
      ServerInfo,
      StatusInfo
    ]);
  finally
    ServerInfo.Free;
    StatusInfo.Free;
  end;
end;

procedure TLiveEdgeTargetThread.SendReconnectRequest(
  const AConnection: IRtmpConnection);
var
  StatusInfo: TRtmpAmf0Object;
begin
  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetConnection.Connect.ReconnectRequest',
    'description', 'Reconnect smoke redirect',
    'tcUrl', '/live'
  ]);
  try
    SendCommandMessage(AConnection, 3, 0, [
      TRtmpAmf0String.Create('onStatus'),
      TRtmpAmf0Number.Create(0),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]);
  finally
    StatusInfo.Free;
  end;
end;

procedure TLiveEdgeTargetThread.SendCreateStreamResult(
  const AConnection: IRtmpConnection; ATransactionID: Double);
begin
  SendCommandMessage(AConnection, 3, 0, [
    TRtmpAmf0String.Create('_result'),
    TRtmpAmf0Number.Create(ATransactionID),
    TRtmpAmf0Null.Create,
    TRtmpAmf0Number.Create(1)
  ]);
end;

procedure TLiveEdgeTargetThread.SendProtocolDefaults(
  const AConnection: IRtmpConnection);
begin
  SendWindowAckSize(AConnection, 5000000);
  SendSetPeerBandwidth(AConnection, 5000000, 2);
  SendSetChunkSize(AConnection, 4096);
end;

procedure TLiveEdgeTargetThread.SendPublishStart(const AConnection: IRtmpConnection);
var
  StatusInfo: TRtmpAmf0Object;
begin
  SendUserControl(AConnection, Ord(ucStreamBegin), 1);
  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetStream.Publish.Start',
    'description', 'Publish started'
  ]);
  try
    SendCommandMessage(AConnection, 5, 1, [
      TRtmpAmf0String.Create('onStatus'),
      TRtmpAmf0Number.Create(0),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]);
  finally
    StatusInfo.Free;
  end;
end;

procedure TLiveEdgeTargetThread.SendRawBytes(const AConnection: IRtmpConnection;
  const ABytes: TBytes);
var
  Offset: Integer;
  Sent: Integer;
begin
  Offset:=0;
  while Offset < Length(ABytes) do
  begin
    Sent:=AConnection.Send(ABytes[Offset], Length(ABytes) - Offset, 3000);
    if Sent <= 0 then
      raise Exception.Create('Socket send failed');
    Inc(Offset, Sent);
  end;
end;

procedure TLiveEdgeTargetThread.SendRtmpMessage(const AConnection: IRtmpConnection;
  AChunkStreamID, AMessageStreamID: UInt32; AMessageTypeID: Byte;
  ATimestamp: UInt32; const APayload: TBytes);
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

  Writer:=TRtmpByteWriter.Create(4128);
  try
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
          WriteChunkMessageHeader(Writer, Header);
      end;

      ChunkSize:=Length(APayload) - ChunkOffset;
      if ChunkSize > 4096 then
        ChunkSize:=4096;

      Writer.WriteBytesRange(APayload, ChunkOffset, ChunkSize);
      SendRawBytes(AConnection, Writer.ToBytes);
      Inc(ChunkOffset, ChunkSize);
    end;
  finally
    Writer.Free;
  end;
end;

procedure TLiveEdgeTargetThread.SendSetChunkSize(const AConnection: IRtmpConnection;
  AChunkSize: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AChunkSize);
    SendRtmpMessage(AConnection, 2, 0, RtmpMessageTypeID(mtSetChunkSize), 0,
      Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TLiveEdgeTargetThread.SendSetPeerBandwidth(
  const AConnection: IRtmpConnection; AValue: UInt32; ALimitType: Byte);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AValue);
    Writer.WriteUInt8(ALimitType);
    SendRtmpMessage(AConnection, 2, 0, RtmpMessageTypeID(mtSetPeerBandwidth), 0,
      Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TLiveEdgeTargetThread.SendUserControl(const AConnection: IRtmpConnection;
  AEventType: Word; AValue1: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt16BE(AEventType);
    Writer.WriteUInt32BE(AValue1);
    SendRtmpMessage(AConnection, 2, 0, RtmpMessageTypeID(mtUserControl), 0,
      Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TLiveEdgeTargetThread.SendWindowAckSize(
  const AConnection: IRtmpConnection; AValue: UInt32);
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AValue);
    SendRtmpMessage(AConnection, 2, 0, RtmpMessageTypeID(mtWindowAckSize), 0,
      Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

constructor TReconnectLiveEdgeSmokeApp.Create;
var
  ClientConfig: TRtmpClientConfig;
begin
  inherited Create;
  FClient:=TRtmpClient.Create;
  FNextSequenceNo:=0;
  FSourceBuffer:=TRtmpCircularBuffer.Create(256, 8 * 1024 * 1024);
  FTarget:=TLiveEdgeTargetThread.Create(1944);
  FTarget.Start;

  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig:=DefaultRtmpClientConfig;
  ClientConfig.TargetURL:='rtmp://127.0.0.1:1944/live/test';
  ClientConfig.OutChunkSize:=4096;
  ClientConfig.ReconnectDelayMS:=200;
  ClientConfig.MaxReconnectDelayMS:=500;
  FClient.Config:=ClientConfig;
end;

destructor TReconnectLiveEdgeSmokeApp.Destroy;
begin
  FClient.Free;
  if FTarget <> nil then
  begin
    FTarget.Terminate;
    FTarget.WaitFor;
    FTarget.Free;
  end;
  FSourceBuffer.Free;
  inherited Destroy;
end;

procedure TReconnectLiveEdgeSmokeApp.PushOutagePackets;
begin
  PushPacket(mtVideo, 1000, 6,
    [$A1, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00,
     $21, $22, $23, $24], [pfIsVideo]);
  PushPacket(mtAudio, 1000, 4,
    [$AF, $01, $31, $32], [pfIsAudio]);
  PushPacket(mtVideo, 2000, 6,
    [$91, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00,
     $41, $42, $43, $44], [pfIsVideo, pfIsKeyframe]);
  PushPacket(mtAudio, 2000, 4,
    [$AF, $01, $33, $34], [pfIsAudio]);
  PushPacket(mtVideo, 2040, 6,
    [$A1, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00,
     $45, $46, $47, $48], [pfIsVideo]);
  PushPacket(mtVideo, 2080, 6,
    [$A1, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00,
     $49, $4A, $4B, $4C], [pfIsVideo]);
  PushPacket(mtVideo, 4000, 6,
    [$91, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00,
     $61, $62, $63, $64], [pfIsVideo, pfIsKeyframe]);
  PushPacket(mtAudio, 4000, 4,
    [$AF, $01, $35, $36], [pfIsAudio]);
  PushPacket(mtVideo, 4040, 6,
    [$A1, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00,
     $65, $66, $67, $68], [pfIsVideo]);
  PushPacket(mtVideo, 4080, 6,
    [$A1, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00,
     $69, $6A, $6B, $6C], [pfIsVideo]);
end;

procedure TReconnectLiveEdgeSmokeApp.PushPacket(AMessageType: TRtmpMessageType;
  ATimestamp: UInt32; AChunkStreamID: UInt32; const APayloadBytes: array of Byte;
  AFlags: TRtmpPacketFlags);
var
  Info: TRtmpFlvTagInfo;
  Packet: TRtmpPacket;
begin
  Info:=Default(TRtmpFlvTagInfo);
  if RtmpInspectFlvTag(AMessageType, Bytes(APayloadBytes), Info) then
    AFlags:=RtmpPacketFlagsFromFlvTag(AMessageType, Info, False);
  Packet:=TRtmpPacket.Create(AMessageType, ATimestamp, ATimestamp, 1,
    AChunkStreamID, TRtmpSharedPayload.Create(Bytes(APayloadBytes)), AFlags,
    FNextSequenceNo);
  Inc(FNextSequenceNo);
  FSourceBuffer.Push(Packet);
end;

procedure TReconnectLiveEdgeSmokeApp.SeedBootstrap;
begin
  PushPacket(mtDataAMF0, 0, 5,
    [$12, $00, $01, $02], [pfIsMetadata]);
  PushPacket(mtAudio, 0, 4,
    [$AF, $00, $12, $10], [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader]);
  PushPacket(mtVideo, 0, 6,
    [$90, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $01, $64, $00, $1E],
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe]);
  PushPacket(mtVideo, 40, 6,
    [$91, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00,
     $09, $10, $11, $12, $13],
    [pfIsVideo, pfIsKeyframe]);
end;

procedure TReconnectLiveEdgeSmokeApp.Run;
var
  ClientStats: TRtmpClientStats;
  Deadline: UInt64;
begin
  SeedBootstrap;
  FClient.Start;
  try
    Deadline:=RtmpGetTickCount64 + 4000;
    while RtmpGetTickCount64 < Deadline do
    begin
      if FTarget.FirstVideoTimestamp(0) <> High(UInt32) then
        Break;
      Sleep(50);
    end;

    if FTarget.FirstVideoTimestamp(0) = High(UInt32) then
      raise Exception.CreateFmt(
        'Reconnect live-edge smoke failed: initial publish did not start targetError=%s state=%d',
        [FTarget.LastError, Ord(FClient.State)]);
    if FTarget.FirstVideoTimestamp(0) <> 40 then
      raise Exception.CreateFmt(
        'Reconnect live-edge smoke failed: expected initial video timestamp 40, got %d',
        [FTarget.FirstVideoTimestamp(0)]);
    if NOT FTarget.FirstFrameHadConfig(0) then
      raise Exception.Create(
        'Reconnect live-edge smoke failed: initial enhanced keyframe lacked hvc1 config');

    PushOutagePackets;

    Deadline:=RtmpGetTickCount64 + 8000;
    while RtmpGetTickCount64 < Deadline do
    begin
      if FTarget.FirstVideoTimestamp(1) <> High(UInt32) then
        Break;
      Sleep(50);
    end;
  finally
    FClient.Stop;
  end;

  if FTarget.LastError <> '' then
    raise Exception.CreateFmt('Reconnect live-edge smoke target failed: %s',
      [FTarget.LastError]);

  ClientStats:=FClient.GetStats;
  if FTarget.FirstVideoTimestamp(1) = High(UInt32) then
    raise Exception.Create('Reconnect live-edge smoke failed: reconnect publish did not start');
  if FTarget.FirstVideoTimestamp(1) <> 4000 then
    raise Exception.CreateFmt(
      'Reconnect live-edge smoke failed: expected reconnect timestamp 4000, got %d',
      [FTarget.FirstVideoTimestamp(1)]);
  if NOT FTarget.FirstFrameHadConfig(1) then
    raise Exception.Create(
      'Reconnect live-edge smoke failed: reconnect keyframe lacked retained hvc1 config');
  if ClientStats.Reconnects = 0 then
    raise Exception.Create(
      'Reconnect live-edge smoke failed: reconnect counter did not advance');
  if ClientStats.ReconnectRequests <> 1 then
    raise Exception.CreateFmt(
      'Reconnect live-edge smoke failed: expected one reconnect request, got %d',
      [ClientStats.ReconnectRequests]);

  WriteLn(Format(
    'Enhanced reconnect-request live-edge smoke passed: firstSessionTs=%d reconnectTs=%d reconnects=%d requests=%d',
    [FTarget.FirstVideoTimestamp(0), FTarget.FirstVideoTimestamp(1),
     ClientStats.Reconnects, ClientStats.ReconnectRequests]));
end;

var
  App: TReconnectLiveEdgeSmokeApp;

begin
  App:=TReconnectLiveEdgeSmokeApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

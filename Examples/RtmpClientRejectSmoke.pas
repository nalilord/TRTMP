program RtmpClientRejectSmoke;

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
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Protocol.Core,
  TRTMP.Transport,
  TRTMP.Transport.Native,
  TRTMP.RTMP.Types;

type
  TRejectServerThread = class(TThread)
  private
    FClientWindowAckCount: Integer;
    FClientWindowAckSize: UInt32;
    FConnectionCount: Integer;
    FCreateStreamCount: Integer;
    FLastError: string;
    FListener: IRtmpListener;
    FPublishCommandCount: Integer;
    FRejectCount: Integer;
    FTransportFactory: IRtmpTransportFactory;
    function BuildObject(const APairs: array of const): TRtmpAmf0Object;
    function ReadExact(const AConnection: IRtmpConnection; ACount: Integer;
      ATimeoutMS: Integer; out ABytes: TBytes): Boolean;
    function ReadOneOrMoreBytes(const AConnection: IRtmpConnection; ATimeoutMS: Integer;
      out ABytes: TBytes): Boolean;
    procedure RunOneSession(const AConnection: IRtmpConnection);
    procedure SendCommandMessage(const AConnection: IRtmpConnection; AChunkStreamID,
      AMessageStreamID: UInt32; const AValues: array of TObject);
    procedure SendCreateStreamResult(const AConnection: IRtmpConnection;
      ATransactionID: Double);
    procedure SendProtocolDefaults(const AConnection: IRtmpConnection);
    procedure SendRtmpMessage(const AConnection: IRtmpConnection; AChunkStreamID,
      AMessageStreamID: UInt32; AMessageTypeID: Byte; ATimestamp: UInt32;
      const APayload: TBytes);
    procedure SendWindowAckSize(const AConnection: IRtmpConnection; AValue: UInt32);
    procedure SendSetPeerBandwidth(const AConnection: IRtmpConnection;
      AValue: UInt32; ALimitType: Byte);
    procedure SendSetChunkSize(const AConnection: IRtmpConnection; AChunkSize: UInt32);
    procedure SendConnectResult(const AConnection: IRtmpConnection; ATransactionID: Double);
    procedure SendPublishRejected(const AConnection: IRtmpConnection);
    procedure SendRawBytes(const AConnection: IRtmpConnection; const ABytes: TBytes);
    procedure SendOptionalCommandError(const AConnection: IRtmpConnection;
      ATransactionID: Double);
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Word);
    destructor Destroy; override;
    property ClientWindowAckCount: Integer read FClientWindowAckCount;
    property ClientWindowAckSize: UInt32 read FClientWindowAckSize;
    property ConnectionCount: Integer read FConnectionCount;
    property CreateStreamCount: Integer read FCreateStreamCount;
    property LastError: string read FLastError;
    property PublishCommandCount: Integer read FPublishCommandCount;
    property RejectCount: Integer read FRejectCount;
  end;

  TRejectSmokeApp = class
  private
    FClient: TRtmpClient;
    FRejectServer: TRejectServerThread;
    FSourceBuffer: TRtmpCircularBuffer;
    procedure SeedSourceBuffer;
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

constructor TRejectServerThread.Create(APort: Word);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FClientWindowAckCount:=0;
  FClientWindowAckSize:=0;
  FLastError:='';
  FConnectionCount:=0;
  FCreateStreamCount:=0;
  FPublishCommandCount:=0;
  FTransportFactory:=TRtmpNativeTransportFactory.Create;
  FListener:=FTransportFactory.CreateListener(
    TRtmpSocketEndpoint.Create('127.0.0.1', APort), 4);
  FRejectCount:=0;
end;

destructor TRejectServerThread.Destroy;
begin
  if FListener <> nil then
    FListener.Close;
  inherited Destroy;
end;

function TRejectServerThread.BuildObject(const APairs: array of const): TRtmpAmf0Object;
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
    else
      raise Exception.Create('Unsupported BuildObject value type');
    end;

    Inc(I, 2);
  end;
end;

procedure TRejectServerThread.Execute;
var
  Connection: IRtmpConnection;
begin
  while NOT Terminated do
  begin
    if FListener = nil then
      Break;
    Connection:=FListener.Accept(200);
    if Connection = nil then
      Continue;
    Inc(FConnectionCount);

    try
      RunOneSession(Connection);
    except
      on E: Exception do
        FLastError:=E.Message;
    end;
  end;
end;

function TRejectServerThread.ReadExact(const AConnection: IRtmpConnection; ACount,
  ATimeoutMS: Integer; out ABytes: TBytes): Boolean;
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

function TRejectServerThread.ReadOneOrMoreBytes(const AConnection: IRtmpConnection;
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

procedure TRejectServerThread.RunOneSession(const AConnection: IRtmpConnection);
var
  BytesIn: TBytes;
  C0C1: TBytes;
  C2: TBytes;
  Command: TRtmpCommandMessage;
  MessageOut: TRtmpChunkMessage;
  Reader: TRtmpByteReader;
  Reassembler: TRtmpChunkReassembler;
  S0S1S2: TBytes;
  TransactionID: Double;
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
        Break;
      Reassembler.AppendBytes(BytesIn);
      while Reassembler.TryReadMessage(MessageOut) do
      begin
        if MessageOut.MessageType = mtSetChunkSize then
        begin
          Reader:=TRtmpByteReader.Create(MessageOut.Payload);
          try
            if Reader.Remaining >= 4 then
              Reassembler.InChunkSize:=Integer(Reader.ReadUInt32BE);
          finally
            Reader.Free;
          end;
          Continue;
        end;

        if MessageOut.MessageType = mtWindowAckSize then
        begin
          Reader:=TRtmpByteReader.Create(MessageOut.Payload);
          try
            if Reader.Remaining >= 4 then
            begin
              Inc(FClientWindowAckCount);
              FClientWindowAckSize:=Reader.ReadUInt32BE;
            end;
          finally
            Reader.Free;
          end;
          Continue;
        end;

        if MessageOut.MessageType <> mtCommandAMF0 then
          Continue;

        Command:=TRtmpCommandMessage.Create(MessageOut.Payload);
        try
          TransactionID:=Command.TransactionID;
          if Command.IsCommand('connect') then
            SendConnectResult(AConnection, TransactionID)
          else if Command.IsCommand('releaseStream') OR Command.IsCommand('FCPublish') then
            SendOptionalCommandError(AConnection, TransactionID)
          else if Command.IsCommand('createStream') then
          begin
            Inc(FCreateStreamCount);
            SendCreateStreamResult(AConnection, TransactionID)
          end
          else if Command.IsCommand('publish') then
          begin
            Inc(FPublishCommandCount);
            Inc(FRejectCount);
            SendPublishRejected(AConnection);
            AConnection.Close;
            Exit;
          end;
        finally
          Command.Free;
        end;
      end;
    end;
  finally
    Reassembler.Free;
  end;
end;

procedure TRejectServerThread.SendRawBytes(const AConnection: IRtmpConnection;
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
      raise Exception.Create('Reject test server failed to send bytes');
    Inc(Offset, Sent);
  end;
end;

procedure TRejectServerThread.SendRtmpMessage(const AConnection: IRtmpConnection;
  AChunkStreamID, AMessageStreamID: UInt32; AMessageTypeID: Byte;
  ATimestamp: UInt32; const APayload: TBytes);
var
  Header: TRtmpChunkMessageHeader;
  PayloadOut: TBytes;
  Writer: TRtmpByteWriter;
begin
  Header:=Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat:=hfType0;
  Header.Timestamp:=ATimestamp;
  Header.MessageLength:=Length(APayload);
  Header.MessageTypeID:=AMessageTypeID;
  Header.MessageStreamID:=AMessageStreamID;
  Header.HasExtendedTimestamp:=ATimestamp >= RTMP_TIMESTAMP_EXTENDED;

  Writer:=TRtmpByteWriter.Create;
  try
    WriteChunkBasicHeader(Writer, hfType0, AChunkStreamID);
    WriteChunkMessageHeader(Writer, Header);
    Writer.WriteBytes(APayload);
    PayloadOut:=Writer.ToBytes;
  finally
    Writer.Free;
  end;

  SendRawBytes(AConnection, PayloadOut);
end;

procedure TRejectServerThread.SendCommandMessage(const AConnection: IRtmpConnection;
  AChunkStreamID, AMessageStreamID: UInt32; const AValues: array of TObject);
var
  I: Integer;
  Payload: TBytes;
  Values: TRtmpAmf0ValueList;
begin
  Values:=TRtmpAmf0ValueList.Create(True);
  try
    for I:=0 to High(AValues) do
      if AValues[I] IS TRtmpAmf0Value then
        Values.AddValue(TRtmpAmf0Value(AValues[I]).Clone)
      else
        raise Exception.Create('SendCommandMessage only accepts TRtmpAmf0Value objects');
    Payload:=TRtmpAmf0.EncodeValues(Values);
  finally
    Values.Free;
  end;

  SendRtmpMessage(AConnection, AChunkStreamID, AMessageStreamID,
    RtmpMessageTypeID(mtCommandAMF0), 0, Payload);
end;

procedure TRejectServerThread.SendConnectResult(const AConnection: IRtmpConnection;
  ATransactionID: Double);
var
  ServerInfo: TRtmpAmf0Object;
  StatusInfo: TRtmpAmf0Object;
begin
  ServerInfo:=BuildObject([
    'fmsVer', 'TRTMP-Test/0.1',
    'capabilities', 31
  ]);
  StatusInfo:=BuildObject([
    'level', 'status',
    'code', 'NetConnection.Connect.Success',
    'description', 'Connection succeeded.'
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

procedure TRejectServerThread.SendCreateStreamResult(const AConnection: IRtmpConnection;
  ATransactionID: Double);
begin
  SendCommandMessage(AConnection, 3, 0, [
    TRtmpAmf0String.Create('_result'),
    TRtmpAmf0Number.Create(ATransactionID),
    TRtmpAmf0Null.Create,
    TRtmpAmf0Number.Create(1)
  ]);
end;

procedure TRejectServerThread.SendOptionalCommandError(
  const AConnection: IRtmpConnection; ATransactionID: Double);
var
  StatusInfo: TRtmpAmf0Object;
begin
  StatusInfo:=BuildObject([
    'level', 'error',
    'code', 'NetConnection.Call.Failed',
    'description', 'Optional command is not supported.'
  ]);
  try
    SendCommandMessage(AConnection, 3, 0, [
      TRtmpAmf0String.Create('_error'),
      TRtmpAmf0Number.Create(ATransactionID),
      TRtmpAmf0Null.Create,
      StatusInfo
    ]);
  finally
    StatusInfo.Free;
  end;
end;

procedure TRejectServerThread.SendProtocolDefaults(const AConnection: IRtmpConnection);
begin
  SendWindowAckSize(AConnection, 5000000);
  SendSetPeerBandwidth(AConnection, 5000000, 2);
  SendSetChunkSize(AConnection, 4096);
end;

procedure TRejectServerThread.SendPublishRejected(const AConnection: IRtmpConnection);
var
  StatusInfo: TRtmpAmf0Object;
begin
  StatusInfo:=BuildObject([
    'level', 'error',
    'code', 'NetStream.Publish.BadName',
    'description', 'Rejected by test target'
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

procedure TRejectServerThread.SendSetChunkSize(const AConnection: IRtmpConnection;
  AChunkSize: UInt32);
var
  Writer: TRtmpByteWriter;
  Payload: TBytes;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AChunkSize);
    Payload:=Writer.ToBytes;
  finally
    Writer.Free;
  end;
  SendRtmpMessage(AConnection, 2, 0, RtmpMessageTypeID(mtSetChunkSize), 0, Payload);
end;

procedure TRejectServerThread.SendSetPeerBandwidth(
  const AConnection: IRtmpConnection; AValue: UInt32; ALimitType: Byte);
var
  Writer: TRtmpByteWriter;
  Payload: TBytes;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AValue);
    Writer.WriteUInt8(ALimitType);
    Payload:=Writer.ToBytes;
  finally
    Writer.Free;
  end;
  SendRtmpMessage(AConnection, 2, 0, RtmpMessageTypeID(mtSetPeerBandwidth), 0, Payload);
end;

procedure TRejectServerThread.SendWindowAckSize(const AConnection: IRtmpConnection;
  AValue: UInt32);
var
  Writer: TRtmpByteWriter;
  Payload: TBytes;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    Writer.WriteUInt32BE(AValue);
    Payload:=Writer.ToBytes;
  finally
    Writer.Free;
  end;
  SendRtmpMessage(AConnection, 2, 0, RtmpMessageTypeID(mtWindowAckSize), 0, Payload);
end;

constructor TRejectSmokeApp.Create;
var
  ClientConfig: TRtmpClientConfig;
begin
  inherited Create;
  FRejectServer:=TRejectServerThread.Create(1954);
  FRejectServer.Start;
  FSourceBuffer:=TRtmpCircularBuffer.Create(64, 2 * 1024 * 1024);
  FClient:=TRtmpClient.Create;
  FClient.AttachBuffer(FSourceBuffer);
  ClientConfig:=DefaultRtmpClientConfig;
  ClientConfig.TargetURL:='rtmp://127.0.0.1:1954/live/test';
  ClientConfig.OutChunkSize:=4096;
  ClientConfig.ReconnectDelayMS:=200;
  ClientConfig.MaxReconnectDelayMS:=400;
  FClient.Config:=ClientConfig;
end;

destructor TRejectSmokeApp.Destroy;
begin
  FClient.Free;
  FSourceBuffer.Free;
  FRejectServer.Terminate;
  FRejectServer.WaitFor;
  FRejectServer.Free;
  inherited Destroy;
end;

procedure TRejectSmokeApp.SeedSourceBuffer;
begin
  FSourceBuffer.Push(TRtmpPacket.Create(mtDataAMF0, 0, 0, 1, 5,
    TRtmpSharedPayload.Create(Bytes([$12, 0, 1, 2])), [pfIsMetadata], 0));
  FSourceBuffer.Push(TRtmpPacket.Create(mtAudio, 0, 0, 1, 4,
    TRtmpSharedPayload.Create(Bytes([$AF, $00, $12, $10])),
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], 1));
  FSourceBuffer.Push(TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $00, $00, $00, $00, $01, $64, $00, $1E])),
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], 2));
  FSourceBuffer.Push(TRtmpPacket.Create(mtVideo, 40, 40, 1, 6,
    TRtmpSharedPayload.Create(Bytes([$17, $01, $00, $00, $00, $09, $10, $11, $12, $13])),
    [pfIsVideo, pfIsKeyframe], 3));
end;

procedure TRejectSmokeApp.Run;
var
  Deadline: UInt64;
  Stats: TRtmpClientStats;
begin
  SeedSourceBuffer;
  FClient.Start;
  try
    Deadline:=RtmpGetTickCount64 + 2500;
    while RtmpGetTickCount64 < Deadline do
    begin
      if FRejectServer.RejectCount >= 2 then
        Break;
      Sleep(50);
    end;
  finally
    FClient.Stop;
  end;

  Stats:=FClient.GetStats;
  if FRejectServer.RejectCount = 0 then
    raise Exception.CreateFmt(
      'Reject smoke failed: target never rejected publish connections=%d createStream=%d publish=%d reconnects=%d lastError=%s',
      [FRejectServer.ConnectionCount, FRejectServer.CreateStreamCount,
       FRejectServer.PublishCommandCount, Stats.Reconnects, FRejectServer.LastError]);
  if Stats.Reconnects = 0 then
    raise Exception.Create('Reject smoke failed: reconnect counter did not advance');
  if FRejectServer.ClientWindowAckCount = 0 then
    raise Exception.Create('Reject smoke failed: client never replied with WindowAckSize');
  if FRejectServer.ClientWindowAckSize <> 5000000 then
    raise Exception.CreateFmt(
      'Reject smoke failed: expected client WindowAckSize 5000000, got %d',
      [FRejectServer.ClientWindowAckSize]);
  if Stats.PacketsSent <> 0 then
    raise Exception.CreateFmt('Reject smoke failed: media packets leaked before publish acceptance: %d',
      [Stats.PacketsSent]);
  if Stats.BytesSent <> 0 then
    raise Exception.CreateFmt('Reject smoke failed: media bytes leaked before publish acceptance: %d',
      [Stats.BytesSent]);

  WriteLn(Format('Reject smoke passed: rejects=%d reconnects=%d packetsSent=%d',
    [FRejectServer.RejectCount, Stats.Reconnects, Stats.PacketsSent]));
end;

var
  App: TRejectSmokeApp;

begin
  App:=TRejectSmokeApp.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.

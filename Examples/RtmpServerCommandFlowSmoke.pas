program RtmpServerCommandFlowSmoke;

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
  RtmpAmf0,
  RtmpBuffer,
  RtmpChunkReassembler,
  RtmpCommand,
  RtmpCompat,
  RtmpBytes,
  RtmpPacket,
  RtmpProtocol,
  RtmpServer,
  RtmpServerSession,
  RtmpTransport,
  RtmpTransportNative,
  RtmpTypes;

type
  TServerCommandFlowSmoke = class
  private
    FLogs: TStringList;
    FPublishStopCount: Integer;
    FPublishStopStreamName: string;
    FServer: TRtmpServer;
    FTransportFactory: IRtmpTransportFactory;
    procedure AssertTrue(const AMessage: string; AValue: Boolean);
    function BuildObject(const APairs: array of const): TRtmpAmf0Object;
    procedure HandlePublishStopped(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    function LogContains(const AFragment: string): Boolean;
    function ReadExact(const AConnection: IRtmpConnection; ACount, ATimeoutMS: Integer;
      out ABytes: TBytes): Boolean;
    procedure RestartServer(APort: Word);
    procedure SendCommandMessage(const AConnection: IRtmpConnection; AChunkStreamID,
      AMessageStreamID: UInt32; const AValues: array of TObject);
    procedure SendConnect(const AConnection: IRtmpConnection; const AApp, ATcUrl: string);
    procedure SendCreateStream(const AConnection: IRtmpConnection);
    procedure SendDeleteStream(const AConnection: IRtmpConnection);
    procedure SendFCPublish(const AConnection: IRtmpConnection; const AStreamName: string);
    procedure SendFCUnpublish(const AConnection: IRtmpConnection; const AStreamName: string);
    procedure SendPlay(const AConnection: IRtmpConnection; const AStreamName: string);
    procedure SendPublish(const AConnection: IRtmpConnection; const AStreamName: string);
    procedure SendRtmpMessage(const AConnection: IRtmpConnection; AChunkStreamID,
      AMessageStreamID: UInt32; AMessageTypeID: Byte; ATimestamp: UInt32;
      const APayload: TBytes);
    procedure SendRawBytes(const AConnection: IRtmpConnection; const ABytes: TBytes);
    procedure SendReleaseStream(const AConnection: IRtmpConnection; const AStreamName: string);
    procedure SeedPacket(AMessageType: TRtmpMessageType; ATimestamp: UInt32;
      ASequenceNo: UInt64; AChunkStreamID: UInt32; const APayload: TBytes;
      AFlags: TRtmpPacketFlags);
    procedure StopServer;
    procedure TestAmf3CommandRejected;
    procedure TestPlayBootstrap;
    procedure TestPublishBeforeCreateStreamRejected;
    procedure TestTeardownCommands;
    procedure TestUnsupportedMessageIgnored;
    function WaitForActiveSessions(AExpected: Integer; ATimeoutMS: Integer): Boolean;
    function WaitForLog(const AFragment: string; ATimeoutMS: Integer): Boolean;
    procedure WriteHandshake(const AConnection: IRtmpConnection);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TServerCommandFlowSmoke.Create;
begin
  inherited Create;
  FLogs := TStringList.Create;
  FPublishStopCount := 0;
  FPublishStopStreamName := '';
  FTransportFactory := TRtmpNativeTransportFactory.Create;
  FServer := nil;
end;

destructor TServerCommandFlowSmoke.Destroy;
begin
  StopServer;
  FLogs.Free;
  inherited Destroy;
end;

procedure TServerCommandFlowSmoke.AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if not AValue then
    raise Exception.Create(AMessage);
end;

function TServerCommandFlowSmoke.BuildObject(const APairs: array of const): TRtmpAmf0Object;
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
    else
      raise Exception.Create('Unsupported BuildObject value type');
    end;

    Inc(I, 2);
  end;
end;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

procedure TServerCommandFlowSmoke.HandleServerLog(Sender: TObject;
  ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
const
  LEVEL_NAMES: array[TRtmpLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  FLogs.Add(Format('[%s] %s: %s', [LEVEL_NAMES[ALevel], ACategory, AMessage]));
end;

procedure TServerCommandFlowSmoke.HandlePublishStopped(Sender: TObject;
  Session: TRtmpServerSession);
begin
  Inc(FPublishStopCount);
  if Session <> nil then
    FPublishStopStreamName := Session.StreamName
  else
    FPublishStopStreamName := '';
  FLogs.Add(Format('[EVENT] publish-stopped stream=%s', [FPublishStopStreamName]));
end;

function TServerCommandFlowSmoke.LogContains(const AFragment: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FLogs.Count - 1 do
    if Pos(AFragment, FLogs[I]) > 0 then
      Exit(True);
end;

function TServerCommandFlowSmoke.ReadExact(const AConnection: IRtmpConnection;
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

procedure TServerCommandFlowSmoke.RestartServer(APort: Word);
var
  Config: TRtmpServerConfig;
begin
  StopServer;
  FLogs.Clear;
  FPublishStopCount := 0;
  FPublishStopStreamName := '';
  FServer := TRtmpServer.Create;
  Config := DefaultRtmpServerConfig;
  Config.BindAddress := '127.0.0.1';
  Config.Port := APort;
  FServer.Config := Config;
  FServer.LogSink.OnLog := HandleServerLog;
  FServer.OnPublishStopped := HandlePublishStopped;
  FServer.MinLogLevel := llDebug;
  FServer.Start;
end;

procedure TServerCommandFlowSmoke.Run;
begin
  TestAmf3CommandRejected;
  TestPlayBootstrap;
  TestPublishBeforeCreateStreamRejected;
  TestTeardownCommands;
  TestUnsupportedMessageIgnored;
  WriteLn('Server command-flow smoke passed.');
end;

procedure TServerCommandFlowSmoke.SendCommandMessage(const AConnection: IRtmpConnection;
  AChunkStreamID, AMessageStreamID: UInt32; const AValues: array of TObject);
var
  Header: TRtmpChunkMessageHeader;
  I: Integer;
  Payload: TBytes;
  Values: TRtmpAmf0ValueList;
  Writer: TRtmpByteWriter;
begin
  Values := TRtmpAmf0ValueList.Create(True);
  try
    for I := 0 to High(AValues) do
      if AValues[I] is TRtmpAmf0Value then
        Values.AddValue(TRtmpAmf0Value(AValues[I]).Clone)
      else
        raise Exception.Create('SendCommandMessage only accepts TRtmpAmf0Value objects');
    Payload := TRtmpAmf0.EncodeValues(Values);
  finally
    Values.Free;
  end;

  Header := Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat := hfType0;
  Header.Timestamp := 0;
  Header.MessageLength := Length(Payload);
  Header.MessageTypeID := RtmpMessageTypeID(mtCommandAMF0);
  Header.MessageStreamID := AMessageStreamID;
  Header.HasExtendedTimestamp := False;

  Writer := TRtmpByteWriter.Create;
  try
    WriteChunkBasicHeader(Writer, hfType0, AChunkStreamID);
    WriteChunkMessageHeader(Writer, Header);
    Writer.WriteBytes(Payload);
    SendRawBytes(AConnection, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TServerCommandFlowSmoke.SendRtmpMessage(const AConnection: IRtmpConnection;
  AChunkStreamID, AMessageStreamID: UInt32; AMessageTypeID: Byte;
  ATimestamp: UInt32; const APayload: TBytes);
var
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

  Writer := TRtmpByteWriter.Create;
  try
    WriteChunkBasicHeader(Writer, hfType0, AChunkStreamID);
    WriteChunkMessageHeader(Writer, Header);
    Writer.WriteBytes(APayload);
    SendRawBytes(AConnection, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure TServerCommandFlowSmoke.SendConnect(const AConnection: IRtmpConnection;
  const AApp, ATcUrl: string);
var
  ConnectInfo: TRtmpAmf0Object;
begin
  ConnectInfo := BuildObject([
    'app', AApp,
    'tcUrl', ATcUrl,
    'flashVer', 'TRTMP-CommandFlowSmoke/0.1'
  ]);
  try
    SendCommandMessage(AConnection, 3, 0, [
      TRtmpAmf0String.Create('connect'),
      TRtmpAmf0Number.Create(1),
      ConnectInfo
    ]);
  finally
    ConnectInfo.Free;
  end;
end;

procedure TServerCommandFlowSmoke.SendCreateStream(const AConnection: IRtmpConnection);
begin
  SendCommandMessage(AConnection, 3, 0, [
    TRtmpAmf0String.Create('createStream'),
    TRtmpAmf0Number.Create(2),
    TRtmpAmf0Null.Create
  ]);
end;

procedure TServerCommandFlowSmoke.SendDeleteStream(const AConnection: IRtmpConnection);
begin
  SendCommandMessage(AConnection, 3, 0, [
    TRtmpAmf0String.Create('deleteStream'),
    TRtmpAmf0Number.Create(0),
    TRtmpAmf0Null.Create,
    TRtmpAmf0Number.Create(1)
  ]);
end;

procedure TServerCommandFlowSmoke.SendFCPublish(const AConnection: IRtmpConnection;
  const AStreamName: string);
begin
  SendCommandMessage(AConnection, 3, 0, [
    TRtmpAmf0String.Create('FCPublish'),
    TRtmpAmf0Number.Create(0),
    TRtmpAmf0Null.Create,
    TRtmpAmf0String.Create(AStreamName)
  ]);
end;

procedure TServerCommandFlowSmoke.SendFCUnpublish(const AConnection: IRtmpConnection;
  const AStreamName: string);
begin
  SendCommandMessage(AConnection, 3, 0, [
    TRtmpAmf0String.Create('FCUnpublish'),
    TRtmpAmf0Number.Create(0),
    TRtmpAmf0Null.Create,
    TRtmpAmf0String.Create(AStreamName)
  ]);
end;

procedure TServerCommandFlowSmoke.SendPlay(const AConnection: IRtmpConnection;
  const AStreamName: string);
begin
  SendCommandMessage(AConnection, 8, 1, [
    TRtmpAmf0String.Create('play'),
    TRtmpAmf0Number.Create(0),
    TRtmpAmf0Null.Create,
    TRtmpAmf0String.Create(AStreamName)
  ]);
end;

procedure TServerCommandFlowSmoke.SendPublish(const AConnection: IRtmpConnection;
  const AStreamName: string);
begin
  SendCommandMessage(AConnection, 8, 1, [
    TRtmpAmf0String.Create('publish'),
    TRtmpAmf0Number.Create(0),
    TRtmpAmf0Null.Create,
    TRtmpAmf0String.Create(AStreamName),
    TRtmpAmf0String.Create('live')
  ]);
end;

procedure TServerCommandFlowSmoke.SendRawBytes(const AConnection: IRtmpConnection;
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

procedure TServerCommandFlowSmoke.SendReleaseStream(const AConnection: IRtmpConnection;
  const AStreamName: string);
begin
  SendCommandMessage(AConnection, 3, 0, [
    TRtmpAmf0String.Create('releaseStream'),
    TRtmpAmf0Number.Create(0),
    TRtmpAmf0Null.Create,
    TRtmpAmf0String.Create(AStreamName)
  ]);
end;

procedure TServerCommandFlowSmoke.SeedPacket(AMessageType: TRtmpMessageType;
  ATimestamp: UInt32; ASequenceNo: UInt64; AChunkStreamID: UInt32;
  const APayload: TBytes; AFlags: TRtmpPacketFlags);
var
  Packet: TRtmpPacket;
begin
  Packet := TRtmpPacket.Create(AMessageType, ATimestamp, 0, 1, AChunkStreamID,
    TRtmpSharedPayload.Create(APayload), AFlags, ASequenceNo);
  FServer.Buffer.Push(Packet);
end;

procedure TServerCommandFlowSmoke.StopServer;
begin
  if FServer <> nil then
  begin
    FServer.Stop;
    FreeAndNil(FServer);
  end;
end;

procedure TServerCommandFlowSmoke.TestAmf3CommandRejected;
var
  Connection: IRtmpConnection;
begin
  RestartServer(1956);
  Connection := FTransportFactory.CreateClientConnection(
    TRtmpSocketEndpoint.Create('127.0.0.1', 1956), 3000);
  try
    WriteHandshake(Connection);
    SendRtmpMessage(Connection, 3, 0, RtmpMessageTypeID(mtCommandAMF3), 0, Bytes([$00]));

    AssertTrue('expected explicit AMF3 rejection log',
      WaitForLog('AMF3 command messages are not supported', 2000));
    AssertTrue('expected session to close after AMF3 rejection',
      WaitForActiveSessions(0, 2000));
  finally
    Connection.Close;
  end;

  StopServer;
end;

procedure TServerCommandFlowSmoke.TestPlayBootstrap;
var
  Buffer: array[0..4095] of Byte;
  BytesIn: TBytes;
  Code: string;
  Command: TRtmpCommandMessage;
  Connection: IRtmpConnection;
  Deadline: UInt64;
  EventType: Word;
  GotAudio: Boolean;
  GotMetadata: Boolean;
  GotPlayReset: Boolean;
  GotPlayStart: Boolean;
  GotStreamBegin: Boolean;
  GotVideo: Boolean;
  MessageOut: TRtmpChunkMessage;
  MetaInfo: TRtmpAmf0Object;
  PlaybackBuffer: TRtmpCircularBuffer;
  Reader: TRtmpByteReader;
  Received: Integer;
  Reassembler: TRtmpChunkReassembler;
  Values: TRtmpAmf0ValueList;
begin
  RestartServer(1960);
  PlaybackBuffer := TRtmpCircularBuffer.Create(128, 1024 * 1024, 5000);
  MetaInfo := BuildObject([
    'width', 1280,
    'height', 720
  ]);
  Values := TRtmpAmf0ValueList.Create(True);
  Reassembler := TRtmpChunkReassembler.Create(4096);
  Connection := FTransportFactory.CreateClientConnection(
    TRtmpSocketEndpoint.Create('127.0.0.1', 1960), 3000);
  try
    FServer.AttachPlaybackBuffer(PlaybackBuffer);
    Values.AddValue(TRtmpAmf0String.Create('onMetaData'));
    Values.AddValue(MetaInfo.Clone);
    PlaybackBuffer.Push(TRtmpPacket.Create(mtDataAMF0, 0, 0, 1, 5,
      TRtmpSharedPayload.Create(TRtmpAmf0.EncodeValues(Values)), [pfIsMetadata], 1));
    PlaybackBuffer.Push(TRtmpPacket.Create(mtAudio, 10, 0, 1, 4,
      TRtmpSharedPayload.Create(Bytes([$AF, $00, $12, $10])),
      [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], 2));
    PlaybackBuffer.Push(TRtmpPacket.Create(mtVideo, 20, 0, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$17, $00, $00, $00, $00, $01, $64, $00, $1F])),
      [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader], 3));
    PlaybackBuffer.Push(TRtmpPacket.Create(mtVideo, 30, 0, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$17, $01, $00, $00, $00, $AA])),
      [pfIsVideo, pfIsKeyframe], 4));

    WriteHandshake(Connection);
    SendConnect(Connection, 'live', 'rtmp://127.0.0.1:1960/live');
    Sleep(50);
    SendCreateStream(Connection);
    Sleep(50);
    SendPlay(Connection, 'play-bootstrap');

    GotAudio := False;
    GotMetadata := False;
    GotPlayReset := False;
    GotPlayStart := False;
    GotStreamBegin := False;
    GotVideo := False;
    Deadline := RtmpGetTickCount64 + 3000;
    repeat
      Received := Connection.Receive(Buffer, SizeOf(Buffer), 200);
      if Received > 0 then
      begin
        SetLength(BytesIn, Received);
        Move(Buffer[0], BytesIn[0], Received);
        Reassembler.AppendBytes(BytesIn);
        while Reassembler.TryReadMessage(MessageOut) do
        begin
          case MessageOut.MessageType of
            mtSetChunkSize:
              if Length(MessageOut.Payload) >= 4 then
              begin
                Reader := TRtmpByteReader.Create(MessageOut.Payload);
                try
                  Reassembler.InChunkSize := Integer(Reader.ReadUInt32BE);
                finally
                  Reader.Free;
                end;
              end;
            mtUserControl:
              begin
                Reader := TRtmpByteReader.Create(MessageOut.Payload);
                try
                  if Reader.Remaining >= 6 then
                  begin
                    EventType := Reader.ReadUInt16BE;
                    if (EventType = Ord(ucStreamBegin)) and (Reader.ReadUInt32BE = 1) then
                      GotStreamBegin := True;
                  end;
                finally
                  Reader.Free;
                end;
              end;
            mtCommandAMF0:
              begin
                Command := TRtmpCommandMessage.Create(MessageOut.Payload);
                try
                  if Command.IsCommand('onStatus') and
                    (Command.ArgumentCount > 3) and
                    (Command[3] is TRtmpAmf0Object) then
                  begin
                    Code := TRtmpAmf0Object(Command[3]).GetString('code');
                    if SameText(Code, 'NetStream.Play.Reset') then
                      GotPlayReset := True
                    else if SameText(Code, 'NetStream.Play.Start') then
                      GotPlayStart := True;
                  end;
                finally
                  Command.Free;
                end;
              end;
            mtDataAMF0:
              GotMetadata := True;
            mtAudio:
              GotAudio := True;
            mtVideo:
              GotVideo := True;
          end;
        end;
      end;
    until (RtmpGetTickCount64 >= Deadline) or
      (GotStreamBegin and GotPlayReset and GotPlayStart and GotMetadata and GotAudio and GotVideo);

    AssertTrue('expected play acceptance log',
      WaitForLog('play stream=play-bootstrap', 2000));
    AssertTrue('expected StreamBegin for play stream', GotStreamBegin);
    AssertTrue('expected NetStream.Play.Reset', GotPlayReset);
    AssertTrue('expected NetStream.Play.Start', GotPlayStart);
    AssertTrue('expected metadata bootstrap packet', GotMetadata);
    AssertTrue('expected audio bootstrap packet', GotAudio);
    AssertTrue('expected video bootstrap packet', GotVideo);
  finally
    Connection.Close;
    FServer.AttachPlaybackBuffer(nil);
    Reassembler.Free;
    Values.Free;
    MetaInfo.Free;
    PlaybackBuffer.Free;
  end;

  StopServer;
end;

procedure TServerCommandFlowSmoke.TestPublishBeforeCreateStreamRejected;
var
  ProbeBuffer: array[0..63] of Byte;
  Connection: IRtmpConnection;
  Received: Integer;
begin
  RestartServer(1957);
  Connection := FTransportFactory.CreateClientConnection(
    TRtmpSocketEndpoint.Create('127.0.0.1', 1957), 3000);
  try
    WriteHandshake(Connection);
    Received := Connection.Receive(ProbeBuffer, SizeOf(ProbeBuffer), 200);
    AssertTrue('expected server protocol defaults to wait for connect',
      Received <= 0);
    SendConnect(Connection, 'live', 'rtmp://127.0.0.1:1957/live');
    Sleep(100);
    SendPublish(Connection, 'bad-sequence');

    AssertTrue('expected publish-before-createStream rejection log',
      WaitForLog('Rejected publish before createStream established a message stream', 2000) or
      WaitForLog('Rejected command publish', 2000));
    AssertTrue('expected session to end after bad publish ordering',
      WaitForActiveSessions(0, 2000));
  finally
    Connection.Close;
  end;

  StopServer;
end;

procedure TServerCommandFlowSmoke.TestTeardownCommands;
var
  Connection: IRtmpConnection;
begin
  RestartServer(1958);
  Connection := FTransportFactory.CreateClientConnection(
    TRtmpSocketEndpoint.Create('127.0.0.1', 1958), 3000);
  try
    WriteHandshake(Connection);
    SendConnect(Connection, 'live', 'rtmp://127.0.0.1:1958/live');
    Sleep(50);
    SendReleaseStream(Connection, 'teardown-test');
    SendFCPublish(Connection, 'teardown-test');
    SendCreateStream(Connection);
    Sleep(50);
    SendPublish(Connection, 'teardown-test');

    AssertTrue('expected publish to be accepted before teardown',
      WaitForLog('publish stream=teardown-test type=live', 2000));

    SendFCUnpublish(Connection, 'teardown-test');
    SendDeleteStream(Connection);

    AssertTrue('expected FCUnpublish log',
      WaitForLog('FCUnpublish stream=teardown-test', 2000));
    AssertTrue('expected publish-stop event on FCUnpublish',
      WaitForLog('publish-stopped stream=teardown-test', 2000));
    AssertTrue('expected deleteStream log',
      WaitForLog('deleteStream received for stream=teardown-test', 2000));
    AssertTrue('expected exactly one publish-stop event',
      FPublishStopCount = 1);
    AssertTrue('expected publish-stop stream name',
      SameText(FPublishStopStreamName, 'teardown-test'));
    AssertTrue('expected session to end after deleteStream',
      WaitForActiveSessions(0, 2000));
  finally
    Connection.Close;
  end;

  StopServer;
end;

procedure TServerCommandFlowSmoke.TestUnsupportedMessageIgnored;
var
  Connection: IRtmpConnection;
begin
  RestartServer(1959);
  Connection := FTransportFactory.CreateClientConnection(
    TRtmpSocketEndpoint.Create('127.0.0.1', 1959), 3000);
  try
    WriteHandshake(Connection);
    SendConnect(Connection, 'live', 'rtmp://127.0.0.1:1959/live');
    Sleep(50);
    SendRtmpMessage(Connection, 2, 0, 31, 0, Bytes([$DE, $AD, $BE, $EF]));
    SendCreateStream(Connection);
    Sleep(50);
    SendPublish(Connection, 'unknown-message-test');

    AssertTrue('expected unsupported message log',
      WaitForLog('Ignoring RTMP message type id 31', 2000));
    AssertTrue('expected publish to continue after unsupported message',
      WaitForLog('publish stream=unknown-message-test type=live', 2000));
  finally
    Connection.Close;
    AssertTrue('expected session to drain after unsupported-message test',
      WaitForActiveSessions(0, 2000));
  end;

  StopServer;
end;

function TServerCommandFlowSmoke.WaitForActiveSessions(AExpected: Integer;
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

function TServerCommandFlowSmoke.WaitForLog(const AFragment: string;
  ATimeoutMS: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := RtmpGetTickCount64 + UInt64(ATimeoutMS);
  repeat
    Result := LogContains(AFragment);
    if Result then
      Exit;
    Sleep(20);
  until RtmpGetTickCount64 >= Deadline;
  Result := False;
end;

procedure TServerCommandFlowSmoke.WriteHandshake(const AConnection: IRtmpConnection);
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
  Smoke: TServerCommandFlowSmoke;

begin
  Smoke := TServerCommandFlowSmoke.Create;
  try
    Smoke.Run;
  finally
    Smoke.Free;
  end;
end.

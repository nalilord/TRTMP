program RtmpPlayReconnectSmoke;

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
  SysUtils,
  TRTMP.RTMP.Protocol.AMF0,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Protocol.Chunk,
  TRTMP.RTMP.Protocol.Command,
  TRTMP.Core.Compat,
  TRTMP.Core.Bytes,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Protocol.Core,
  TRTMP.RTMP.Server,
  TRTMP.Transport,
  TRTMP.Transport.Native,
  TRTMP.RTMP.Types;

type
  TPlaySessionResult = record
    GotPlayReset: Boolean;
    GotPlayStart: Boolean;
    GotStreamBegin: Boolean;
    FirstVideoTimestamp: UInt32;
    VideoPackets: Integer;
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
    else
      raise Exception.Create('Unsupported BuildObject value type');
    end;

    Inc(I, 2);
  end;
end;

procedure SendRawBytes(const AConnection: IRtmpConnection; const ABytes: TBytes);
var
  Offset: Integer;
  Sent: Integer;
begin
  Offset:=0;
  while Offset < Length(ABytes) do
  begin
    Sent:=AConnection.Send(ABytes[Offset], Length(ABytes) - Offset, 3000);
    if Sent <= 0 then
      raise Exception.Create('Failed to send test bytes');
    Inc(Offset, Sent);
  end;
end;

function ReadExact(const AConnection: IRtmpConnection; ACount, ATimeoutMS: Integer;
  out ABytes: TBytes): Boolean;
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

procedure WriteHandshake(const AConnection: IRtmpConnection);
var
  C0C1: TBytes;
  C2: TBytes;
  Reply: TBytes;
  S1: TBytes;
begin
  C0C1:=TRtmpHandshake.BuildC0C1(0);
  SendRawBytes(AConnection, C0C1);

  if NOT ReadExact(AConnection, 1 + RTMP_HANDSHAKE_SIZE * 2, 3000, Reply) then
    raise Exception.Create('Handshake failed: expected S0/S1/S2');

  if Reply[0] <> RTMP_VERSION then
    raise Exception.CreateFmt('Handshake failed: expected RTMP version %d got %d',
      [RTMP_VERSION, Reply[0]]);

  SetLength(S1, RTMP_HANDSHAKE_SIZE);
  Move(Reply[1], S1[0], RTMP_HANDSHAKE_SIZE);
  C2:=TRtmpHandshake.BuildC2(S1, 0);
  SendRawBytes(AConnection, C2);
end;

procedure SendCommandMessage(const AConnection: IRtmpConnection; AChunkStreamID,
  AMessageStreamID: UInt32; const AValues: array of TObject);
var
  Header: TRtmpChunkMessageHeader;
  I: Integer;
  Payload: TBytes;
  Values: TRtmpAmf0ValueList;
  Writer: TRtmpByteWriter;
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

  Header:=Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat:=hfType0;
  Header.Timestamp:=0;
  Header.MessageLength:=Length(Payload);
  Header.MessageTypeID:=RtmpMessageTypeID(mtCommandAMF0);
  Header.MessageStreamID:=AMessageStreamID;
  Header.HasExtendedTimestamp:=False;

  Writer:=TRtmpByteWriter.Create;
  try
    WriteChunkBasicHeader(Writer, hfType0, AChunkStreamID);
    WriteChunkMessageHeader(Writer, Header);
    Writer.WriteBytes(Payload);
    SendRawBytes(AConnection, Writer.ToBytes);
  finally
    Writer.Free;
  end;
end;

procedure SendConnect(const AConnection: IRtmpConnection; const AApp, ATcUrl: string);
var
  ConnectInfo: TRtmpAmf0Object;
begin
  ConnectInfo:=BuildObject([
    'app', AApp,
    'tcUrl', ATcUrl,
    'flashVer', 'TRTMP-PlayReconnectSmoke/0.1'
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

procedure SendCreateStream(const AConnection: IRtmpConnection);
begin
  SendCommandMessage(AConnection, 3, 0, [
    TRtmpAmf0String.Create('createStream'),
    TRtmpAmf0Number.Create(2),
    TRtmpAmf0Null.Create
  ]);
end;

procedure SendPlay(const AConnection: IRtmpConnection; const AStreamName: string);
begin
  SendCommandMessage(AConnection, 8, 1, [
    TRtmpAmf0String.Create('play'),
    TRtmpAmf0Number.Create(0),
    TRtmpAmf0Null.Create,
    TRtmpAmf0String.Create(AStreamName)
  ]);
end;

function RunPlaySession(const ATransportFactory: IRtmpTransportFactory;
  APort: Word; const AStreamName: string): TPlaySessionResult;
var
  Buffer: array[0..4095] of Byte;
  BytesIn: TBytes;
  Code: string;
  Command: TRtmpCommandMessage;
  Connection: IRtmpConnection;
  Deadline: UInt64;
  EventType: Word;
  MessageOut: TRtmpChunkMessage;
  Reader: TRtmpByteReader;
  Received: Integer;
  Reassembler: TRtmpChunkReassembler;
begin
  Result:=Default(TPlaySessionResult);
  Result.FirstVideoTimestamp:=High(UInt32);
  Reassembler:=TRtmpChunkReassembler.Create(4096);
  Connection:=ATransportFactory.CreateClientConnection(
    TRtmpSocketEndpoint.Create('127.0.0.1', APort), 3000);
  try
    WriteHandshake(Connection);
    SendConnect(Connection, 'live', Format('rtmp://127.0.0.1:%d/live', [APort]));
    Sleep(50);
    SendCreateStream(Connection);
    Sleep(50);
    SendPlay(Connection, AStreamName);

    Deadline:=RtmpGetTickCount64 + 3000;
    repeat
      Received:=Connection.Receive(Buffer, SizeOf(Buffer), 200);
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
                Reader:=TRtmpByteReader.Create(MessageOut.Payload);
                try
                  Reassembler.InChunkSize:=Integer(Reader.ReadUInt32BE);
                finally
                  Reader.Free;
                end;
              end;
            mtUserControl:
              begin
                Reader:=TRtmpByteReader.Create(MessageOut.Payload);
                try
                  if Reader.Remaining >= 6 then
                  begin
                    EventType:=Reader.ReadUInt16BE;
                    if (EventType = Ord(ucStreamBegin)) AND (Reader.ReadUInt32BE = 1) then
                      Result.GotStreamBegin:=True;
                  end;
                finally
                  Reader.Free;
                end;
              end;
            mtCommandAMF0:
              begin
                Command:=TRtmpCommandMessage.Create(MessageOut.Payload);
                try
                  if Command.IsCommand('onStatus') AND
                    (Command.ArgumentCount > 3) AND
                    (Command[3] IS TRtmpAmf0Object) then
                  begin
                    Code:=TRtmpAmf0Object(Command[3]).GetString('code');
                    if SameText(Code, 'NetStream.Play.Reset') then
                      Result.GotPlayReset:=True
                    else if SameText(Code, 'NetStream.Play.Start') then
                      Result.GotPlayStart:=True;
                  end;
                finally
                  Command.Free;
                end;
              end;
            mtVideo:
              begin
                if (Length(MessageOut.Payload) > 1) AND (MessageOut.Payload[1] = $00) then
                  Continue;
                Inc(Result.VideoPackets);
                if Result.FirstVideoTimestamp = High(UInt32) then
                  Result.FirstVideoTimestamp:=MessageOut.Timestamp;
              end;
          end;
        end;
      end;
    until (RtmpGetTickCount64 >= Deadline) OR
      (Result.GotStreamBegin AND Result.GotPlayReset AND Result.GotPlayStart AND
       (Result.FirstVideoTimestamp <> High(UInt32)));
  finally
    Connection.Close;
    Reassembler.Free;
  end;
end;

var
  PlaybackBuffer: TRtmpCircularBuffer;
  Result1: TPlaySessionResult;
  Result2: TPlaySessionResult;
  Server: TRtmpServer;
  ServerConfig: TRtmpServerConfig;
  TransportFactory: IRtmpTransportFactory;
begin
  PlaybackBuffer:=TRtmpCircularBuffer.Create(128, 1024 * 1024, 5000);
  Server:=TRtmpServer.Create;
  TransportFactory:=TRtmpNativeTransportFactory.Create;
  try
    ServerConfig:=DefaultRtmpServerConfig;
    ServerConfig.BindAddress:='127.0.0.1';
    ServerConfig.Port:=1961;
    Server.Config:=ServerConfig;
    Server.AttachPlaybackBuffer(PlaybackBuffer);

    PlaybackBuffer.Push(TRtmpPacket.Create(mtDataAMF0, 0, 0, 1, 5,
      TRtmpSharedPayload.Create(Bytes([$02, $00])), [pfIsMetadata], 1));
    PlaybackBuffer.Push(TRtmpPacket.Create(mtAudio, 0, 0, 1, 4,
      TRtmpSharedPayload.Create(Bytes([$AF, $00, $12, $10])),
      [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], 2));
    PlaybackBuffer.Push(TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$17, $00, $00, $00, $00, $01, $64, $00, $1E])),
      [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader], 3));
    PlaybackBuffer.Push(TRtmpPacket.Create(mtVideo, 100, 0, 1, 6,
      TRtmpSharedPayload.Create(Bytes([$17, $01, $00, $00, $00, $AA])),
      [pfIsVideo, pfIsKeyframe], 4));

    Server.Start;
    try
      Result1:=RunPlaySession(TransportFactory, 1961, 'reconnect-play');

      PlaybackBuffer.Push(TRtmpPacket.Create(mtVideo, 1000, 0, 1, 6,
        TRtmpSharedPayload.Create(Bytes([$17, $01, $00, $00, $00, $BB])),
        [pfIsVideo, pfIsKeyframe], 5));
      PlaybackBuffer.Push(TRtmpPacket.Create(mtVideo, 1040, 0, 1, 6,
        TRtmpSharedPayload.Create(Bytes([$27, $01, $00, $00, $00, $CC])),
        [pfIsVideo], 6));

      Result2:=RunPlaySession(TransportFactory, 1961, 'reconnect-play');
    finally
      Server.Stop;
    end;
  finally
    Server.Free;
    PlaybackBuffer.Free;
  end;

  if NOT (Result1.GotStreamBegin AND Result1.GotPlayReset AND Result1.GotPlayStart) then
    raise Exception.Create('Play reconnect smoke failed: first session did not establish play');
  if Result1.FirstVideoTimestamp <> 100 then
    raise Exception.CreateFmt(
      'Play reconnect smoke failed: expected first session first video timestamp 100, got %d',
      [Result1.FirstVideoTimestamp]);
  if NOT (Result2.GotStreamBegin AND Result2.GotPlayReset AND Result2.GotPlayStart) then
    raise Exception.Create('Play reconnect smoke failed: second session did not establish play');
  if Result2.FirstVideoTimestamp <> 1000 then
    raise Exception.CreateFmt(
      'Play reconnect smoke failed: expected reconnect first video timestamp 1000, got %d',
      [Result2.FirstVideoTimestamp]);

  WriteLn(Format(
    'Play reconnect smoke passed: firstTs=%d reconnectTs=%d videoPackets1=%d videoPackets2=%d',
    [Result1.FirstVideoTimestamp, Result2.FirstVideoTimestamp,
     Result1.VideoPackets, Result2.VideoPackets]));
end.

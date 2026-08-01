program RtmpPlayConsole;

{$IFDEF MSWINDOWS}
  {$APPTYPE CONSOLE}
{$ENDIF}

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
  TRTMP.RTMP.Protocol.Chunk,
  TRTMP.RTMP.Protocol.Command,
  TRTMP.Core.Compat,
  TRTMP.Core.Bytes,
  TRTMP.RTMP.Protocol.Core,
  TRTMP.Transport,
  TRTMP.Transport.Native,
  TRTMP.RTMP.Types;

type
  TPlayTargetInfo = record
    Endpoint: TRtmpSocketEndpoint;
    AppName: string;
    StreamName: string;
    TcUrl: string;
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
      raise Exception.Create('Failed to send bytes');
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

procedure SendConnect(const AConnection: IRtmpConnection; const ATarget: TPlayTargetInfo);
var
  ConnectInfo: TRtmpAmf0Object;
begin
  ConnectInfo:=BuildObject([
    'app', ATarget.AppName,
    'tcUrl', ATarget.TcUrl,
    'flashVer', 'TRTMP-PlayConsole/0.1'
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

function ParsePlayTarget(const AUrl: string; out ATarget: TPlayTargetInfo): Boolean;
var
  ColonPos: Integer;
  HostPart: string;
  PathPart: string;
  SchemePos: Integer;
  SlashPos: Integer;
begin
  Result:=False;
  ATarget:=Default(TPlayTargetInfo);

  SchemePos:=Pos('://', AUrl);
  if SchemePos <= 0 then
    Exit;
  if NOT SameText(Copy(AUrl, 1, SchemePos - 1), 'rtmp') then
    Exit;

  HostPart:=Copy(AUrl, SchemePos + 3, MaxInt);
  SlashPos:=Pos('/', HostPart);
  if SlashPos <= 0 then
    Exit;

  PathPart:=Copy(HostPart, SlashPos + 1, MaxInt);
  HostPart:=Copy(HostPart, 1, SlashPos - 1);
  if PathPart = '' then
    Exit;

  ColonPos:=Pos(':', HostPart);
  if ColonPos > 0 then
  begin
    ATarget.Endpoint.Address:=Copy(HostPart, 1, ColonPos - 1);
    ATarget.Endpoint.Port:=Word(StrToIntDef(Copy(HostPart, ColonPos + 1, MaxInt), 1935));
  end
  else
  begin
    ATarget.Endpoint.Address:=HostPart;
    ATarget.Endpoint.Port:=1935;
  end;

  SlashPos:=Pos('/', PathPart);
  if SlashPos > 0 then
  begin
    ATarget.AppName:=Copy(PathPart, 1, SlashPos - 1);
    ATarget.StreamName:=Copy(PathPart, SlashPos + 1, MaxInt);
  end
  else
  begin
    ATarget.AppName:=PathPart;
    ATarget.StreamName:='test';
  end;

  ATarget.TcUrl:=Format('rtmp://%s:%d/%s',
    [ATarget.Endpoint.Address, ATarget.Endpoint.Port, ATarget.AppName]);
  Result:=(ATarget.Endpoint.Address <> '') AND (ATarget.AppName <> '') AND
    (ATarget.StreamName <> '');
end;

var
  Buffer: array[0..8191] of Byte;
  BytesIn: TBytes;
  Code: string;
  Command: TRtmpCommandMessage;
  Connection: IRtmpConnection;
  MessageOut: TRtmpChunkMessage;
  PacketCount: UInt64;
  PacketLogEvery: Integer;
  Reader: TRtmpByteReader;
  Received: Integer;
  Reassembler: TRtmpChunkReassembler;
  Target: TPlayTargetInfo;
  TransportFactory: IRtmpTransportFactory;
begin
  if ParamCount >= 1 then
  begin
    if NOT ParsePlayTarget(ParamStr(1), Target) then
      raise Exception.Create('Usage: RtmpPlayConsole rtmp://host:port/app/stream [packet_log_every]');
  end
  else
  begin
    if NOT ParsePlayTarget('rtmp://127.0.0.1:1935/live/test', Target) then
      raise Exception.Create('Failed to parse default target');
  end;

  if ParamCount >= 2 then
    PacketLogEvery:=StrToIntDef(ParamStr(2), 0)
  else
    PacketLogEvery:=0;

  WriteLn(Format('Connecting to rtmp://%s:%d/%s/%s',
    [Target.Endpoint.Address, Target.Endpoint.Port, Target.AppName, Target.StreamName]));

  TransportFactory:=TRtmpNativeTransportFactory.Create;
  Reassembler:=TRtmpChunkReassembler.Create(4096);
  PacketCount:=0;
  Connection:=TransportFactory.CreateClientConnection(Target.Endpoint, 5000);
  try
    WriteHandshake(Connection);
    SendConnect(Connection, Target);
    Sleep(50);
    SendCreateStream(Connection);
    Sleep(50);
    SendPlay(Connection, Target.StreamName);

    while Connection.Connected do
    begin
      Received:=Connection.Receive(Buffer, SizeOf(Buffer), 1000);
      if Received <= 0 then
      begin
        if NOT Connection.Connected then
          Break;
        Continue;
      end;

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
                  WriteLn(Format('UserControl event=%d streamId=%d',
                    [Reader.ReadUInt16BE, Reader.ReadUInt32BE]));
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
                  WriteLn(Format('onStatus code=%s', [Code]));
                end
                else if Command.IsCommand('_result') then
                  WriteLn('_result');
              finally
                Command.Free;
              end;
            end;
          mtDataAMF0, mtAudio, mtVideo:
            begin
              Inc(PacketCount);
              if (MessageOut.MessageType = mtDataAMF0) OR
                (PacketLogEvery <= 0) OR ((PacketCount MOD UInt64(PacketLogEvery)) = 0) OR
                ((MessageOut.MessageType = mtVideo) AND (Length(MessageOut.Payload) > 0) AND
                  ((MessageOut.Payload[0] AND $F0) = $10)) then
                WriteLn(Format('packet type=%d ts=%d size=%d',
                  [Ord(MessageOut.MessageType), MessageOut.Timestamp, Length(MessageOut.Payload)]));
            end;
        end;
      end;
    end;
  finally
    Connection.Close;
    Reassembler.Free;
  end;
end.

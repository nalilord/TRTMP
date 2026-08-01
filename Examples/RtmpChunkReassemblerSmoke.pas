program RtmpChunkReassemblerSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  TRTMP.Core.Bytes,
  TRTMP.RTMP.Protocol.Chunk,
  TRTMP.RTMP.Protocol.Core,
  TRTMP.RTMP.Types;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result:=nil;
  SetLength(Result, Length(AValues));
  for I:=0 to High(AValues) do
    Result[I]:=AValues[I];
end;

procedure AppendBytes(var ATarget: TBytes; const ASource: TBytes);
var
  OldLength: Integer;
begin
  OldLength:=Length(ATarget);
  SetLength(ATarget, OldLength + Length(ASource));
  if Length(ASource) > 0 then
    Move(ASource[0], ATarget[OldLength], Length(ASource));
end;

procedure AssertEqualInt(const AMessage: string; AExpected, AActual: Integer);
begin
  if AExpected <> AActual then
    raise Exception.CreateFmt('%s expected=%d actual=%d', [AMessage, AExpected, AActual]);
end;

procedure AssertEqualUInt32(const AMessage: string; AExpected, AActual: UInt32);
begin
  if AExpected <> AActual then
    raise Exception.CreateFmt('%s expected=%u actual=%u', [AMessage, AExpected, AActual]);
end;

procedure AssertEqualByte(const AMessage: string; AExpected, AActual: Byte);
begin
  if AExpected <> AActual then
    raise Exception.CreateFmt('%s expected=%d actual=%d', [AMessage, AExpected, AActual]);
end;

procedure AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if NOT AValue then
    raise Exception.Create(AMessage);
end;

procedure AssertBytesEqual(const AMessage: string; const AExpected, AActual: TBytes);
var
  I: Integer;
begin
  AssertEqualInt(AMessage + ' length', Length(AExpected), Length(AActual));
  for I:=0 to High(AExpected) do
    if AExpected[I] <> AActual[I] then
      raise Exception.CreateFmt('%s mismatch at index=%d expected=%d actual=%d',
        [AMessage, I, AExpected[I], AActual[I]]);
end;

function BuildChunk(const ABasicFormat: TRtmpChunkHeaderFormat; AChunkStreamID: UInt32;
  const AHeader: TRtmpChunkMessageHeader; const APayload: TBytes): TBytes;
var
  Writer: TRtmpByteWriter;
begin
  Writer:=TRtmpByteWriter.Create;
  try
    WriteChunkBasicHeader(Writer, ABasicFormat, AChunkStreamID);
    WriteChunkMessageHeader(Writer, AHeader);
    Writer.WriteBytes(APayload);
    Result:=Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

function BuildType0Chunk(AChunkStreamID, AMessageStreamID: UInt32; ATimestamp: UInt32;
  AMessageTypeID: Byte; const APayload: TBytes): TBytes;
var
  Header: TRtmpChunkMessageHeader;
begin
  Header:=Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat:=hfType0;
  Header.Timestamp:=ATimestamp;
  Header.MessageLength:=Length(APayload);
  Header.MessageTypeID:=AMessageTypeID;
  Header.MessageStreamID:=AMessageStreamID;
  Header.HasExtendedTimestamp:=ATimestamp >= RTMP_TIMESTAMP_EXTENDED;
  Result:=BuildChunk(hfType0, AChunkStreamID, Header, APayload);
end;

function BuildType1Chunk(AChunkStreamID: UInt32; ATimestampDelta: UInt32;
  AMessageLength: UInt32; AMessageTypeID: Byte; const APayload: TBytes): TBytes;
var
  Header: TRtmpChunkMessageHeader;
begin
  Header:=Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat:=hfType1;
  Header.TimestampDelta:=ATimestampDelta;
  Header.MessageLength:=AMessageLength;
  Header.MessageTypeID:=AMessageTypeID;
  Header.HasExtendedTimestamp:=ATimestampDelta >= RTMP_TIMESTAMP_EXTENDED;
  Result:=BuildChunk(hfType1, AChunkStreamID, Header, APayload);
end;

function BuildType3Chunk(AChunkStreamID: UInt32; AExtendedTimestamp: UInt32;
  const APayload: TBytes): TBytes;
var
  Header: TRtmpChunkMessageHeader;
begin
  Header:=Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat:=hfType3;
  Header.HasExtendedTimestamp:=AExtendedTimestamp <> 0;
  Header.Timestamp:=AExtendedTimestamp;
  Result:=BuildChunk(hfType3, AChunkStreamID, Header, APayload);
end;

procedure TestType1WithoutPreviousHeader;
var
  Chunk: TBytes;
  MessageOut: TRtmpChunkMessage;
  Reassembler: TRtmpChunkReassembler;
begin
  Reassembler:=TRtmpChunkReassembler.Create(128);
  try
    Chunk:=BuildType1Chunk(3, 10, 1, RtmpMessageTypeID(mtAudio), Bytes([$AF]));
    Reassembler.AppendBytes(Chunk);
    try
      Reassembler.TryReadMessage(MessageOut);
      raise Exception.Create('type1 without previous header did not raise ERtmpProtocolError');
    except
      on E: ERtmpProtocolError do
        AssertTrue('type1 wrong error message',
          Pos('has no previous header for type 1 chunk', E.Message) > 0);
    end;
  finally
    Reassembler.Free;
  end;
end;

procedure TestType3WithoutPreviousHeader;
var
  Chunk: TBytes;
  MessageOut: TRtmpChunkMessage;
  Reassembler: TRtmpChunkReassembler;
begin
  Reassembler:=TRtmpChunkReassembler.Create(128);
  try
    Chunk:=BuildType3Chunk(5, 0, nil);
    Reassembler.AppendBytes(Chunk);
    try
      Reassembler.TryReadMessage(MessageOut);
      raise Exception.Create('type3 without previous header did not raise ERtmpProtocolError');
    except
      on E: ERtmpProtocolError do
        AssertTrue('type3 wrong error message',
          Pos('has no previous header for type 3 chunk', E.Message) > 0);
    end;
  finally
    Reassembler.Free;
  end;
end;

procedure TestTruncatedMessageAssembly;
var
  Chunk: TBytes;
  MessageOut: TRtmpChunkMessage;
  Payload: TBytes;
  Reassembler: TRtmpChunkReassembler;
begin
  Payload:=Bytes([$01, $02, $03, $04, $05]);
  Reassembler:=TRtmpChunkReassembler.Create(128);
  try
    Chunk:=BuildType0Chunk(4, 1, 123, RtmpMessageTypeID(mtDataAMF0), Payload);

    Reassembler.AppendBytes(Copy(Chunk, 0, 8));
    AssertTrue('truncated chunk should not yet yield a message',
      NOT Reassembler.TryReadMessage(MessageOut));
    AssertEqualInt('truncated pending bytes after first append', 8, Reassembler.PendingBytes);

    Reassembler.AppendBytes(Copy(Chunk, 8, Length(Chunk) - 8));
    AssertTrue('completed chunk should now yield a message',
      Reassembler.TryReadMessage(MessageOut));
    AssertEqualUInt32('truncated timestamp', 123, MessageOut.Timestamp);
    AssertEqualUInt32('truncated message stream id', 1, MessageOut.MessageStreamID);
    AssertEqualByte('truncated message type id', RtmpMessageTypeID(mtDataAMF0),
      MessageOut.MessageTypeID);
    AssertBytesEqual('truncated payload', Payload, MessageOut.Payload);
    AssertEqualInt('pending bytes drained after full message', 0, Reassembler.PendingBytes);
  finally
    Reassembler.Free;
  end;
end;

procedure TestNewHeaderBeforeActiveMessageCompleted;
var
  FirstChunk: TBytes;
  Header: TRtmpChunkMessageHeader;
  MessageOut: TRtmpChunkMessage;
  Reassembler: TRtmpChunkReassembler;
begin
  Reassembler:=TRtmpChunkReassembler.Create(4);
  try
    Header:=Default(TRtmpChunkMessageHeader);
    Header.HeaderFormat:=hfType0;
    Header.Timestamp:=0;
    Header.MessageLength:=6;
    Header.MessageTypeID:=RtmpMessageTypeID(mtVideo);
    Header.MessageStreamID:=1;
    Header.HasExtendedTimestamp:=False;
    FirstChunk:=BuildChunk(hfType0, 6, Header, Bytes([$11, $22, $33, $44]));
    Reassembler.AppendBytes(FirstChunk);
    AssertTrue('first split chunk should not yet complete message',
      NOT Reassembler.TryReadMessage(MessageOut));

    Reassembler.AppendBytes(BuildType0Chunk(6, 1, 10, RtmpMessageTypeID(mtVideo),
      Bytes([$77])));
    try
      Reassembler.TryReadMessage(MessageOut);
      raise Exception.Create('new header before active message completed did not raise ERtmpProtocolError');
    except
      on E: ERtmpProtocolError do
        AssertTrue('new header wrong error message: ' + E.Message,
          Pos('received a new message header before the current message completed',
            E.Message) > 0);
    end;
  finally
    Reassembler.Free;
  end;
end;

procedure TestBufferedContinuationDrainsSingleCall;
var
  Header: TRtmpChunkMessageHeader;
  MessageOut: TRtmpChunkMessage;
  Payload: TBytes;
  Reassembler: TRtmpChunkReassembler;
  Wire: TBytes;
begin
  Payload:=Bytes([$10, $20, $30, $40, $50, $60]);
  Header:=Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat:=hfType0;
  Header.Timestamp:=55;
  Header.MessageLength:=Length(Payload);
  Header.MessageTypeID:=RtmpMessageTypeID(mtVideo);
  Header.MessageStreamID:=1;
  Header.HasExtendedTimestamp:=False;

  Wire:=BuildChunk(hfType0, 6, Header, Bytes([$10, $20, $30, $40]));
  AppendBytes(Wire, BuildType3Chunk(6, 0, Bytes([$50, $60])));

  Reassembler:=TRtmpChunkReassembler.Create(4);
  try
    Reassembler.AppendBytes(Wire);
    AssertTrue('buffered continuation should reconstruct in a single call',
      Reassembler.TryReadMessage(MessageOut));
    AssertEqualUInt32('buffered continuation timestamp', 55, MessageOut.Timestamp);
    AssertBytesEqual('buffered continuation payload', Payload, MessageOut.Payload);
  finally
    Reassembler.Free;
  end;
end;

procedure TestExtendedTimestampAcrossContinuation;
var
  FirstPayload: TBytes;
  Header: TRtmpChunkMessageHeader;
  MessageOut: TRtmpChunkMessage;
  Payload: TBytes;
  Reassembler: TRtmpChunkReassembler;
  FirstChunk: TBytes;
begin
  Payload:=Bytes([$10, $20, $30, $40, $50, $60]);
  FirstPayload:=Bytes([$10, $20, $30, $40]);
  Header:=Default(TRtmpChunkMessageHeader);
  Header.HeaderFormat:=hfType0;
  Header.Timestamp:=$01020304;
  Header.MessageLength:=Length(Payload);
  Header.MessageTypeID:=RtmpMessageTypeID(mtVideo);
  Header.MessageStreamID:=1;
  Header.HasExtendedTimestamp:=True;
  FirstChunk:=BuildChunk(hfType0, 6, Header, FirstPayload);

  Reassembler:=TRtmpChunkReassembler.Create(4);
  try
    Reassembler.AppendBytes(FirstChunk);
    AssertTrue('extended-timestamp first chunk should be incomplete',
      NOT Reassembler.TryReadMessage(MessageOut));

    Reassembler.AppendBytes(BuildType3Chunk(6, $01020304, Bytes([$50, $60])));
    AssertTrue('extended-timestamp message should reconstruct',
      Reassembler.TryReadMessage(MessageOut));
    AssertEqualUInt32('extended timestamp', $01020304, MessageOut.Timestamp);
    AssertTrue('extended timestamp flag', MessageOut.HasExtendedTimestamp);
    AssertEqualUInt32('extended message stream id', 1, MessageOut.MessageStreamID);
    AssertBytesEqual('extended payload', Payload, MessageOut.Payload);
  finally
    Reassembler.Free;
  end;
end;

procedure TestAbortDiscardsPartialMessage;
var
  Header: TRtmpChunkMessageHeader;
  FirstChunk: TBytes;
  MessageOut: TRtmpChunkMessage;
  Payload: TBytes;
  Reassembler: TRtmpChunkReassembler;
begin
  Payload:=Bytes([$11, $22, $33, $44, $55, $66]);
  Reassembler:=TRtmpChunkReassembler.Create(4);
  try
    Header:=Default(TRtmpChunkMessageHeader);
    Header.HeaderFormat:=hfType0;
    Header.Timestamp:=90;
    Header.MessageLength:=Length(Payload);
    Header.MessageTypeID:=RtmpMessageTypeID(mtVideo);
    Header.MessageStreamID:=1;
    FirstChunk:=BuildChunk(hfType0, 7, Header, Bytes([$11, $22, $33, $44]));
    Reassembler.AppendBytes(FirstChunk);
    AssertTrue('partial message should not complete before abort',
      NOT Reassembler.TryReadMessage(MessageOut));

    Reassembler.AbortChunkStream(7);
    Header.Timestamp:=120;
    FirstChunk:=BuildChunk(hfType0, 7, Header, Bytes([$11, $22, $33, $44]));
    AppendBytes(FirstChunk, BuildType3Chunk(7, 0, Bytes([$55, $66])));
    Reassembler.AppendBytes(FirstChunk);
    AssertTrue('message after abort should reconstruct cleanly',
      Reassembler.TryReadMessage(MessageOut));
    AssertEqualUInt32('abort reset timestamp', 120, MessageOut.Timestamp);
    AssertBytesEqual('abort reset payload', Payload, MessageOut.Payload);
  finally
    Reassembler.Free;
  end;
end;

begin
  TestType1WithoutPreviousHeader;
  TestType3WithoutPreviousHeader;
  TestTruncatedMessageAssembly;
  TestNewHeaderBeforeActiveMessageCompleted;
  TestBufferedContinuationDrainsSingleCall;
  TestExtendedTimestampAcrossContinuation;
  TestAbortDiscardsPartialMessage;
  WriteLn('Chunk reassembler smoke passed.');
end.

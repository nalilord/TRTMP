unit RtmpProtocol;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  RtmpCompat,
  RtmpBytes,
  RtmpTypes;

const
  RTMP_VERSION = 3;
  RTMP_HANDSHAKE_SIZE = 1536;
  RTMP_TIMESTAMP_EXTENDED = $FFFFFF;

type
  ERtmpProtocolError = class(Exception);

  TRtmpChunkHeaderFormat = (
    hfType0 = 0,
    hfType1 = 1,
    hfType2 = 2,
    hfType3 = 3
  );

  TRtmpChunkBasicHeader = record
    HeaderFormat: TRtmpChunkHeaderFormat;
    ChunkStreamID: UInt32;
  end;

  TRtmpChunkMessageHeader = record
    HeaderFormat: TRtmpChunkHeaderFormat;
    Timestamp: UInt32;
    TimestampDelta: UInt32;
    MessageLength: UInt32;
    MessageTypeID: Byte;
    MessageStreamID: UInt32;
    HasExtendedTimestamp: Boolean;
  end;

  TRtmpChunkHeader = record
    BasicHeader: TRtmpChunkBasicHeader;
    MessageHeader: TRtmpChunkMessageHeader;
  end;

  TRtmpHandshake = class
  private
    class procedure FillRandomBytes(var ABuffer: TBytes; AOffset, ACount: Integer); static;
    class function BuildHandshakeBlock(ATimestamp, ATime2: UInt32;
      const APayload: TBytes): TBytes; static;
    class function CopyHandshakePayload(const ABlock: TBytes): TBytes; static;
  public
    class function BuildC0C1(ATimestamp: UInt32 = 0): TBytes; static;
    class function BuildC2(const AS1: TBytes; ACurrentTimestamp: UInt32 = 0): TBytes; static;
    class function BuildS0S1S2(const AC1: TBytes; AServerTimestamp: UInt32 = 0): TBytes; static;
    class function IsValidC1S1Block(const ABlock: TBytes): Boolean; static;
  end;

function RtmpChunkHeaderSize(AFormat: TRtmpChunkHeaderFormat;
  AChunkStreamID: UInt32; AHasExtendedTimestamp: Boolean): Integer;
function RtmpMessageTypeFromTypeID(ATypeID: Byte): TRtmpMessageType;
function RtmpMessageTypeID(AType: TRtmpMessageType): Byte;
procedure ReadChunkBasicHeader(AReader: TRtmpByteReader;
  out ABasicHeader: TRtmpChunkBasicHeader);
procedure ReadChunkMessageHeader(AReader: TRtmpByteReader;
  const ABasicHeader: TRtmpChunkBasicHeader; out AMessageHeader: TRtmpChunkMessageHeader);
procedure WriteChunkBasicHeader(AWriter: TRtmpByteWriter;
  AFormat: TRtmpChunkHeaderFormat; AChunkStreamID: UInt32);
procedure WriteChunkMessageHeader(AWriter: TRtmpByteWriter;
  const AMessageHeader: TRtmpChunkMessageHeader);

implementation

function CurrentTimestampOr(AValue: UInt32): UInt32;
begin
  if AValue <> 0 then
    Result := AValue
  else
    Result := UInt32(RtmpGetTickCount64 and High(UInt32));
end;

function RtmpChunkHeaderSize(AFormat: TRtmpChunkHeaderFormat;
  AChunkStreamID: UInt32; AHasExtendedTimestamp: Boolean): Integer;
begin
  if AChunkStreamID < 64 then
    Result := 1
  else if AChunkStreamID < 320 then
    Result := 2
  else
    Result := 3;

  case AFormat of
    hfType0:
      Inc(Result, 11);
    hfType1:
      Inc(Result, 7);
    hfType2:
      Inc(Result, 3);
    hfType3:
      ;
  end;

  if AHasExtendedTimestamp then
    Inc(Result, 4);
end;

function RtmpMessageTypeFromTypeID(ATypeID: Byte): TRtmpMessageType;
begin
  case ATypeID of
    1: Result := mtSetChunkSize;
    2: Result := mtAbort;
    3: Result := mtAck;
    4: Result := mtUserControl;
    5: Result := mtWindowAckSize;
    6: Result := mtSetPeerBandwidth;
    8: Result := mtAudio;
    9: Result := mtVideo;
    15: Result := mtDataAMF3;
    16: Result := mtSharedObjectAMF3;
    17: Result := mtCommandAMF3;
    18: Result := mtDataAMF0;
    19: Result := mtSharedObjectAMF0;
    20: Result := mtCommandAMF0;
    22: Result := mtAggregate;
  else
    Result := mtUnknown;
  end;
end;

function RtmpMessageTypeID(AType: TRtmpMessageType): Byte;
begin
  case AType of
    mtSetChunkSize: Result := 1;
    mtAbort: Result := 2;
    mtAck: Result := 3;
    mtUserControl: Result := 4;
    mtWindowAckSize: Result := 5;
    mtSetPeerBandwidth: Result := 6;
    mtAudio: Result := 8;
    mtVideo: Result := 9;
    mtDataAMF3: Result := 15;
    mtSharedObjectAMF3: Result := 16;
    mtCommandAMF3: Result := 17;
    mtDataAMF0: Result := 18;
    mtSharedObjectAMF0: Result := 19;
    mtCommandAMF0: Result := 20;
    mtAggregate: Result := 22;
  else
    Result := 0;
  end;
end;

procedure ReadChunkBasicHeader(AReader: TRtmpByteReader;
  out ABasicHeader: TRtmpChunkBasicHeader);
var
  FirstByte: Byte;
  ChunkStreamID: UInt32;
begin
  FirstByte := AReader.ReadUInt8;
  ABasicHeader.HeaderFormat := TRtmpChunkHeaderFormat((FirstByte shr 6) and $03);
  ChunkStreamID := FirstByte and $3F;

  case ChunkStreamID of
    0:
      ABasicHeader.ChunkStreamID := UInt32(AReader.ReadUInt8) + 64;
    1:
      ABasicHeader.ChunkStreamID := UInt32(AReader.ReadUInt8) +
        (UInt32(AReader.ReadUInt8) shl 8) + 64;
  else
    ABasicHeader.ChunkStreamID := ChunkStreamID;
  end;
end;

procedure ReadChunkMessageHeader(AReader: TRtmpByteReader;
  const ABasicHeader: TRtmpChunkBasicHeader; out AMessageHeader: TRtmpChunkMessageHeader);
var
  TimestampField: UInt32;
begin
  AMessageHeader := Default(TRtmpChunkMessageHeader);
  AMessageHeader.HeaderFormat := ABasicHeader.HeaderFormat;

  case ABasicHeader.HeaderFormat of
    hfType0:
      begin
        TimestampField := AReader.ReadUInt24BE;
        AMessageHeader.Timestamp := TimestampField;
        AMessageHeader.MessageLength := AReader.ReadUInt24BE;
        AMessageHeader.MessageTypeID := AReader.ReadUInt8;
        AMessageHeader.MessageStreamID := AReader.ReadUInt32LE;
      end;
    hfType1:
      begin
        TimestampField := AReader.ReadUInt24BE;
        AMessageHeader.TimestampDelta := TimestampField;
        AMessageHeader.MessageLength := AReader.ReadUInt24BE;
        AMessageHeader.MessageTypeID := AReader.ReadUInt8;
      end;
    hfType2:
      begin
        TimestampField := AReader.ReadUInt24BE;
        AMessageHeader.TimestampDelta := TimestampField;
      end;
    hfType3:
      TimestampField := 0;
  else
    raise ERtmpProtocolError.Create('Unsupported chunk header format');
  end;

  if TimestampField = RTMP_TIMESTAMP_EXTENDED then
  begin
    AMessageHeader.HasExtendedTimestamp := True;
    if ABasicHeader.HeaderFormat = hfType0 then
      AMessageHeader.Timestamp := AReader.ReadUInt32BE
    else if ABasicHeader.HeaderFormat in [hfType1, hfType2] then
      AMessageHeader.TimestampDelta := AReader.ReadUInt32BE
    else
      AMessageHeader.Timestamp := AReader.ReadUInt32BE;
  end;
end;

procedure WriteChunkBasicHeader(AWriter: TRtmpByteWriter;
  AFormat: TRtmpChunkHeaderFormat; AChunkStreamID: UInt32);
var
  HeaderByte: Byte;
begin
  if AChunkStreamID < 64 then
  begin
    HeaderByte := (Byte(Ord(AFormat)) shl 6) or Byte(AChunkStreamID);
    AWriter.WriteUInt8(HeaderByte);
  end
  else if AChunkStreamID < 320 then
  begin
    HeaderByte := Byte(Ord(AFormat)) shl 6;
    AWriter.WriteUInt8(HeaderByte);
    AWriter.WriteUInt8(Byte(AChunkStreamID - 64));
  end
  else
  begin
    HeaderByte := (Byte(Ord(AFormat)) shl 6) or 1;
    AWriter.WriteUInt8(HeaderByte);
    AWriter.WriteUInt8(Byte((AChunkStreamID - 64) and $FF));
    AWriter.WriteUInt8(Byte(((AChunkStreamID - 64) shr 8) and $FF));
  end;
end;

procedure WriteChunkMessageHeader(AWriter: TRtmpByteWriter;
  const AMessageHeader: TRtmpChunkMessageHeader);
var
  TimestampField: UInt32;
begin
  case AMessageHeader.HeaderFormat of
    hfType0:
      begin
        if AMessageHeader.Timestamp >= RTMP_TIMESTAMP_EXTENDED then
          TimestampField := RTMP_TIMESTAMP_EXTENDED
        else
          TimestampField := AMessageHeader.Timestamp;

        AWriter.WriteUInt24BE(TimestampField);
        AWriter.WriteUInt24BE(AMessageHeader.MessageLength);
        AWriter.WriteUInt8(AMessageHeader.MessageTypeID);
        AWriter.WriteUInt32LE(AMessageHeader.MessageStreamID);

        if AMessageHeader.Timestamp >= RTMP_TIMESTAMP_EXTENDED then
          AWriter.WriteUInt32BE(AMessageHeader.Timestamp);
      end;
    hfType1:
      begin
        if AMessageHeader.TimestampDelta >= RTMP_TIMESTAMP_EXTENDED then
          TimestampField := RTMP_TIMESTAMP_EXTENDED
        else
          TimestampField := AMessageHeader.TimestampDelta;

        AWriter.WriteUInt24BE(TimestampField);
        AWriter.WriteUInt24BE(AMessageHeader.MessageLength);
        AWriter.WriteUInt8(AMessageHeader.MessageTypeID);

        if AMessageHeader.TimestampDelta >= RTMP_TIMESTAMP_EXTENDED then
          AWriter.WriteUInt32BE(AMessageHeader.TimestampDelta);
      end;
    hfType2:
      begin
        if AMessageHeader.TimestampDelta >= RTMP_TIMESTAMP_EXTENDED then
          TimestampField := RTMP_TIMESTAMP_EXTENDED
        else
          TimestampField := AMessageHeader.TimestampDelta;

        AWriter.WriteUInt24BE(TimestampField);
        if AMessageHeader.TimestampDelta >= RTMP_TIMESTAMP_EXTENDED then
          AWriter.WriteUInt32BE(AMessageHeader.TimestampDelta);
      end;
    hfType3:
      if AMessageHeader.HasExtendedTimestamp then
      begin
        if AMessageHeader.Timestamp <> 0 then
          AWriter.WriteUInt32BE(AMessageHeader.Timestamp)
        else
          AWriter.WriteUInt32BE(AMessageHeader.TimestampDelta);
      end;
  else
    raise ERtmpProtocolError.Create('Unsupported chunk header format');
  end;
end;

class function TRtmpHandshake.BuildC0C1(ATimestamp: UInt32): TBytes;
var
  Block: TBytes;
begin
  Result := nil;
  SetLength(Result, RTMP_HANDSHAKE_SIZE + 1);
  Result[0] := RTMP_VERSION;

  Block := BuildHandshakeBlock(CurrentTimestampOr(ATimestamp), 0, nil);
  Move(Block[0], Result[1], Length(Block));
end;

class function TRtmpHandshake.BuildC2(const AS1: TBytes;
  ACurrentTimestamp: UInt32): TBytes;
var
  Payload: TBytes;
  Reader: TRtmpByteReader;
begin
  if not IsValidC1S1Block(AS1) then
    raise ERtmpProtocolError.CreateFmt('Expected %d-byte S1 block', [RTMP_HANDSHAKE_SIZE]);

  Payload := CopyHandshakePayload(AS1);
  Reader := TRtmpByteReader.Create(AS1);
  try
    Result := BuildHandshakeBlock(Reader.ReadUInt32BE,
      CurrentTimestampOr(ACurrentTimestamp), Payload);
  finally
    Reader.Free;
  end;
end;

class function TRtmpHandshake.BuildHandshakeBlock(ATimestamp, ATime2: UInt32;
  const APayload: TBytes): TBytes;
begin
  Result := nil;
  SetLength(Result, RTMP_HANDSHAKE_SIZE);

  Result[0] := Byte((ATimestamp shr 24) and $FF);
  Result[1] := Byte((ATimestamp shr 16) and $FF);
  Result[2] := Byte((ATimestamp shr 8) and $FF);
  Result[3] := Byte(ATimestamp and $FF);

  Result[4] := Byte((ATime2 shr 24) and $FF);
  Result[5] := Byte((ATime2 shr 16) and $FF);
  Result[6] := Byte((ATime2 shr 8) and $FF);
  Result[7] := Byte(ATime2 and $FF);

  if Length(APayload) > 0 then
  begin
    if Length(APayload) <> RTMP_HANDSHAKE_SIZE - 8 then
      raise ERtmpProtocolError.CreateFmt(
        'Invalid handshake payload length %d', [Length(APayload)]);
    Move(APayload[0], Result[8], Length(APayload));
  end
  else
    FillRandomBytes(Result, 8, RTMP_HANDSHAKE_SIZE - 8);
end;

class function TRtmpHandshake.BuildS0S1S2(const AC1: TBytes;
  AServerTimestamp: UInt32): TBytes;
var
  S1: TBytes;
  S2: TBytes;
  Reader: TRtmpByteReader;
begin
  Result := nil;
  if not IsValidC1S1Block(AC1) then
    raise ERtmpProtocolError.CreateFmt('Expected %d-byte C1 block', [RTMP_HANDSHAKE_SIZE]);

  S1 := BuildHandshakeBlock(CurrentTimestampOr(AServerTimestamp), 0, nil);

  Reader := TRtmpByteReader.Create(AC1);
  try
    S2 := BuildHandshakeBlock(Reader.ReadUInt32BE,
      CurrentTimestampOr(AServerTimestamp), CopyHandshakePayload(AC1));
  finally
    Reader.Free;
  end;

  SetLength(Result, (RTMP_HANDSHAKE_SIZE * 2) + 1);
  Result[0] := RTMP_VERSION;
  Move(S1[0], Result[1], Length(S1));
  Move(S2[0], Result[1 + Length(S1)], Length(S2));
end;

class function TRtmpHandshake.CopyHandshakePayload(const ABlock: TBytes): TBytes;
begin
  if not IsValidC1S1Block(ABlock) then
    raise ERtmpProtocolError.CreateFmt('Expected %d-byte handshake block',
      [RTMP_HANDSHAKE_SIZE]);
  Result := nil;
  SetLength(Result, RTMP_HANDSHAKE_SIZE - 8);
  Move(ABlock[8], Result[0], Length(Result));
end;

class procedure TRtmpHandshake.FillRandomBytes(var ABuffer: TBytes; AOffset,
  ACount: Integer);
var
  I: Integer;
begin
  for I := 0 to ACount - 1 do
    ABuffer[AOffset + I] := Byte(Random(256));
end;

class function TRtmpHandshake.IsValidC1S1Block(const ABlock: TBytes): Boolean;
begin
  Result := Length(ABlock) = RTMP_HANDSHAKE_SIZE;
end;

initialization
  Randomize;

end.

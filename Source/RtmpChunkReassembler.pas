unit RtmpChunkReassembler;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  Contnrs,
  SysUtils,
  RtmpBytes,
  RtmpProtocol,
  RtmpTypes;

type
  TRtmpChunkMessage = record
    ChunkStreamID: UInt32;
    MessageStreamID: UInt32;
    MessageTypeID: Byte;
    MessageType: TRtmpMessageType;
    Timestamp: UInt32;
    TimestampDelta: UInt32;
    HasExtendedTimestamp: Boolean;
    Payload: TBytes;
  end;

  TRtmpChunkReassembler = class
  private
    type
      TRtmpChunkStreamState = class
      public
        ChunkStreamID: UInt32;
        LastHeader: TRtmpChunkMessageHeader;
        LastHeaderValid: Boolean;
        ActiveHeader: TRtmpChunkMessageHeader;
        ActivePayload: TBytes;
        ActiveBytesRead: UInt32;
        Active: Boolean;

        procedure ClearActive;
      end;
  private
    FInputBuffer: TBytes;
    FInputStart: Integer;
    FInChunkSize: Integer;
    FStates: TObjectList;
    procedure AppendBuffer(const ABytes: TBytes);
    procedure CompactInputBuffer;
    procedure ConsumeBuffer(ACount: Integer);
    function FindState(AChunkStreamID: UInt32): TRtmpChunkStreamState;
    function GetOrCreateState(AChunkStreamID: UInt32): TRtmpChunkStreamState;
    procedure ResolveNewMessageHeader(AState: TRtmpChunkStreamState;
      const ABasicHeader: TRtmpChunkBasicHeader;
      const ARawHeader: TRtmpChunkMessageHeader;
      AExtendedTimestampForType3: UInt32;
      out AResolvedHeader: TRtmpChunkMessageHeader);
    function TryReadChunk(out AMessage: TRtmpChunkMessage): Boolean;
  public
    constructor Create(AInChunkSize: Integer = 128);
    destructor Destroy; override;

    procedure AbortChunkStream(AChunkStreamID: UInt32);
    procedure AppendBytes(const ABytes: TBytes); overload;
    procedure AppendBytes(const ABuffer; ACount: Integer); overload;
    procedure Clear;
    function GetPendingPreview(AMaxBytes: Integer = 64): TBytes;
    function PendingBytes: Integer;
    procedure SetInChunkSize(AValue: Integer);
    function TryReadMessage(out AMessage: TRtmpChunkMessage): Boolean;

    property InChunkSize: Integer read FInChunkSize write SetInChunkSize;
  end;

implementation

procedure TRtmpChunkReassembler.TRtmpChunkStreamState.ClearActive;
begin
  Active := False;
  ActiveHeader := Default(TRtmpChunkMessageHeader);
  ActivePayload := nil;
  ActiveBytesRead := 0;
end;

constructor TRtmpChunkReassembler.Create(AInChunkSize: Integer);
begin
  inherited Create;
  FStates := TObjectList.Create(True);
  FInputStart := 0;
  SetInChunkSize(AInChunkSize);
end;

destructor TRtmpChunkReassembler.Destroy;
begin
  FStates.Free;
  inherited Destroy;
end;

procedure TRtmpChunkReassembler.AbortChunkStream(AChunkStreamID: UInt32);
var
  State: TRtmpChunkStreamState;
begin
  State := FindState(AChunkStreamID);
  if State = nil then
    Exit;

  State.ActivePayload := nil;
  State.ClearActive;
end;

procedure TRtmpChunkReassembler.AppendBuffer(const ABytes: TBytes);
var
  OldLength: Integer;
begin
  if Length(ABytes) = 0 then
    Exit;

  CompactInputBuffer;
  OldLength := Length(FInputBuffer);
  SetLength(FInputBuffer, OldLength + Length(ABytes));
  Move(ABytes[0], FInputBuffer[OldLength], Length(ABytes));
end;

procedure TRtmpChunkReassembler.AppendBytes(const ABytes: TBytes);
begin
  AppendBuffer(ABytes);
end;

procedure TRtmpChunkReassembler.AppendBytes(const ABuffer; ACount: Integer);
var
  OldLength: Integer;
begin
  if ACount <= 0 then
    Exit;

  CompactInputBuffer;
  OldLength := Length(FInputBuffer);
  SetLength(FInputBuffer, OldLength + ACount);
  Move(ABuffer, FInputBuffer[OldLength], ACount);
end;

procedure TRtmpChunkReassembler.Clear;
begin
  FInputBuffer := nil;
  FInputStart := 0;
  FStates.Clear;
end;

function TRtmpChunkReassembler.GetPendingPreview(AMaxBytes: Integer): TBytes;
var
  Available: Integer;
begin
  if AMaxBytes < 0 then
    AMaxBytes := 0;

  Available := Length(FInputBuffer) - FInputStart;
  if Available <= 0 then
  begin
    Result := nil;
    Exit;
  end;

  if AMaxBytes > Available then
    AMaxBytes := Available;

  Result := nil;
  SetLength(Result, AMaxBytes);
  Move(FInputBuffer[FInputStart], Result[0], AMaxBytes);
end;

procedure TRtmpChunkReassembler.CompactInputBuffer;
var
  Remaining: Integer;
begin
  if FInputStart <= 0 then
    Exit;

  Remaining := Length(FInputBuffer) - FInputStart;
  if Remaining <= 0 then
  begin
    FInputBuffer := nil;
    FInputStart := 0;
    Exit;
  end;

  if (FInputStart < 65536) and (FInputStart <= (Length(FInputBuffer) div 2)) then
    Exit;

  Move(FInputBuffer[FInputStart], FInputBuffer[0], Remaining);
  SetLength(FInputBuffer, Remaining);
  FInputStart := 0;
end;

procedure TRtmpChunkReassembler.ConsumeBuffer(ACount: Integer);
begin
  if ACount <= 0 then
    Exit;

  if ACount >= (Length(FInputBuffer) - FInputStart) then
  begin
    FInputBuffer := nil;
    FInputStart := 0;
    Exit;
  end;

  Inc(FInputStart, ACount);
end;

function TRtmpChunkReassembler.FindState(AChunkStreamID: UInt32): TRtmpChunkStreamState;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FStates.Count - 1 do
    if TRtmpChunkStreamState(FStates[I]).ChunkStreamID = AChunkStreamID then
    begin
      Result := TRtmpChunkStreamState(FStates[I]);
      Exit;
    end;
end;

function TRtmpChunkReassembler.GetOrCreateState(AChunkStreamID: UInt32): TRtmpChunkStreamState;
begin
  Result := FindState(AChunkStreamID);
  if Result = nil then
  begin
    Result := TRtmpChunkStreamState.Create;
    Result.ChunkStreamID := AChunkStreamID;
    Result.ClearActive;
    Result.LastHeader := Default(TRtmpChunkMessageHeader);
    Result.LastHeaderValid := False;
    FStates.Add(Result);
  end;
end;

function TRtmpChunkReassembler.PendingBytes: Integer;
begin
  Result := Length(FInputBuffer) - FInputStart;
end;

procedure TRtmpChunkReassembler.ResolveNewMessageHeader(AState: TRtmpChunkStreamState;
  const ABasicHeader: TRtmpChunkBasicHeader;
  const ARawHeader: TRtmpChunkMessageHeader; AExtendedTimestampForType3: UInt32;
  out AResolvedHeader: TRtmpChunkMessageHeader);
var
  NextDelta: UInt32;
begin
  AResolvedHeader := Default(TRtmpChunkMessageHeader);
  AResolvedHeader.HeaderFormat := ABasicHeader.HeaderFormat;

  case ABasicHeader.HeaderFormat of
    hfType0:
      begin
        AResolvedHeader := ARawHeader;
        AResolvedHeader.HeaderFormat := hfType0;
      end;
    hfType1:
      begin
        if not AState.LastHeaderValid then
          raise ERtmpProtocolError.CreateFmt(
            'Chunk stream %d has no previous header for type 1 chunk',
            [ABasicHeader.ChunkStreamID]);

        AResolvedHeader := AState.LastHeader;
        AResolvedHeader.HeaderFormat := hfType1;
        AResolvedHeader.TimestampDelta := ARawHeader.TimestampDelta;
        AResolvedHeader.Timestamp := AState.LastHeader.Timestamp + ARawHeader.TimestampDelta;
        AResolvedHeader.MessageLength := ARawHeader.MessageLength;
        AResolvedHeader.MessageTypeID := ARawHeader.MessageTypeID;
        AResolvedHeader.HasExtendedTimestamp := ARawHeader.HasExtendedTimestamp;
      end;
    hfType2:
      begin
        if not AState.LastHeaderValid then
          raise ERtmpProtocolError.CreateFmt(
            'Chunk stream %d has no previous header for type 2 chunk',
            [ABasicHeader.ChunkStreamID]);

        AResolvedHeader := AState.LastHeader;
        AResolvedHeader.HeaderFormat := hfType2;
        AResolvedHeader.TimestampDelta := ARawHeader.TimestampDelta;
        AResolvedHeader.Timestamp := AState.LastHeader.Timestamp + ARawHeader.TimestampDelta;
        AResolvedHeader.HasExtendedTimestamp := ARawHeader.HasExtendedTimestamp;
      end;
    hfType3:
      begin
        if not AState.LastHeaderValid then
          raise ERtmpProtocolError.CreateFmt(
            'Chunk stream %d has no previous header for type 3 chunk',
            [ABasicHeader.ChunkStreamID]);

        AResolvedHeader := AState.LastHeader;
        AResolvedHeader.HeaderFormat := hfType3;

        if AExtendedTimestampForType3 <> 0 then
        begin
          if AState.LastHeader.TimestampDelta <> 0 then
          begin
            AResolvedHeader.TimestampDelta := AExtendedTimestampForType3;
            AResolvedHeader.Timestamp := AState.LastHeader.Timestamp +
              AExtendedTimestampForType3;
          end
          else
            AResolvedHeader.Timestamp := AExtendedTimestampForType3;
          AResolvedHeader.HasExtendedTimestamp := True;
        end
        else
        begin
          NextDelta := AState.LastHeader.TimestampDelta;
          AResolvedHeader.TimestampDelta := NextDelta;
          AResolvedHeader.Timestamp := AState.LastHeader.Timestamp + NextDelta;
        end;
      end;
  else
    raise ERtmpProtocolError.Create('Unsupported chunk header format');
  end;
end;

procedure TRtmpChunkReassembler.SetInChunkSize(AValue: Integer);
begin
  if AValue <= 0 then
    raise ERtmpProtocolError.CreateFmt('Invalid inbound chunk size %d', [AValue]);
  FInChunkSize := AValue;
end;

function TRtmpChunkReassembler.TryReadChunk(out AMessage: TRtmpChunkMessage): Boolean;
var
  BasicHeader: TRtmpChunkBasicHeader;
  RawHeader: TRtmpChunkMessageHeader;
  ResolvedHeader: TRtmpChunkMessageHeader;
  Reader: TRtmpByteReader;
  State: TRtmpChunkStreamState;
  HeaderBytesConsumed: Integer;
  ChunkDataSize: UInt32;
  BytesRemaining: UInt32;
  ConsumedBytes: Integer;
  ExtendedTimestampForType3: UInt32;
  PreviousTimestamp: UInt32;
  StartPosition: Integer;
begin
  Result := False;
  AMessage := Default(TRtmpChunkMessage);

  if (Length(FInputBuffer) - FInputStart) = 0 then
    Exit;

  Reader := TRtmpByteReader.Create(FInputBuffer, FInputStart);
  try
    StartPosition := Reader.Position;
    try
      ReadChunkBasicHeader(Reader, BasicHeader);
      State := GetOrCreateState(BasicHeader.ChunkStreamID);

      if BasicHeader.HeaderFormat = hfType3 then
      begin
        RawHeader := Default(TRtmpChunkMessageHeader);
        RawHeader.HeaderFormat := hfType3;
        ExtendedTimestampForType3 := 0;

        if State.Active then
        begin
          ResolvedHeader := State.ActiveHeader;
          if State.ActiveHeader.HasExtendedTimestamp then
            ExtendedTimestampForType3 := Reader.ReadUInt32BE;
        end
        else
        begin
          if State.LastHeaderValid and State.LastHeader.HasExtendedTimestamp then
            ExtendedTimestampForType3 := Reader.ReadUInt32BE;
          ResolveNewMessageHeader(State, BasicHeader, RawHeader,
            ExtendedTimestampForType3, ResolvedHeader);
        end;
      end
      else
      begin
        ReadChunkMessageHeader(Reader, BasicHeader, RawHeader);
        ResolveNewMessageHeader(State, BasicHeader, RawHeader, 0, ResolvedHeader);
      end;
    except
      on E: ERtmpByteReader do
        Exit(False);
    end;

    HeaderBytesConsumed := Reader.Position - StartPosition;

    if State.Active and (BasicHeader.HeaderFormat <> hfType3) then
      raise ERtmpProtocolError.CreateFmt(
        'Chunk stream %d received a new message header before the current message completed',
        [BasicHeader.ChunkStreamID]);

    if State.Active then
    begin
      BytesRemaining := State.ActiveHeader.MessageLength - State.ActiveBytesRead;
      if BytesRemaining = 0 then
        raise ERtmpProtocolError.CreateFmt(
          'Chunk stream %d has an active message with no bytes remaining',
          [BasicHeader.ChunkStreamID]);
    end
    else
    begin
      BytesRemaining := ResolvedHeader.MessageLength;
    end;

    if BytesRemaining > UInt32(FInChunkSize) then
      ChunkDataSize := UInt32(FInChunkSize)
    else
      ChunkDataSize := BytesRemaining;

    if Reader.Remaining < Integer(ChunkDataSize) then
      Exit(False);

    ConsumedBytes := (Reader.Position - StartPosition) + Integer(ChunkDataSize);

    if not State.Active then
    begin
      State.Active := True;
      State.ActiveHeader := ResolvedHeader;
      SetLength(State.ActivePayload, ResolvedHeader.MessageLength);
      State.ActiveBytesRead := 0;
    end;

    if ChunkDataSize > 0 then
    begin
      Move(FInputBuffer[Reader.Position], State.ActivePayload[State.ActiveBytesRead],
        ChunkDataSize);
      Inc(State.ActiveBytesRead, ChunkDataSize);
    end;

    ConsumeBuffer(ConsumedBytes);

    if State.ActiveBytesRead = State.ActiveHeader.MessageLength then
    begin
      AMessage.ChunkStreamID := BasicHeader.ChunkStreamID;
      AMessage.MessageStreamID := State.ActiveHeader.MessageStreamID;
      AMessage.MessageTypeID := State.ActiveHeader.MessageTypeID;
      AMessage.MessageType := RtmpMessageTypeFromTypeID(State.ActiveHeader.MessageTypeID);
      AMessage.Timestamp := State.ActiveHeader.Timestamp;
      AMessage.TimestampDelta := State.ActiveHeader.TimestampDelta;
      AMessage.HasExtendedTimestamp := State.ActiveHeader.HasExtendedTimestamp;
      AMessage.Payload := State.ActivePayload;

      PreviousTimestamp := 0;
      if State.LastHeaderValid then
        PreviousTimestamp := State.LastHeader.Timestamp;

      State.LastHeader := State.ActiveHeader;
      if State.LastHeaderValid then
      begin
        if State.LastHeader.TimestampDelta = 0 then
          State.LastHeader.TimestampDelta := State.ActiveHeader.Timestamp - PreviousTimestamp;
      end;
      State.LastHeaderValid := True;
      State.ActivePayload := nil;
      State.ClearActive;
      Result := True;
    end
    else
      Result := False;

    if HeaderBytesConsumed > ConsumedBytes then
      raise ERtmpProtocolError.Create('Internal chunk accounting error');
  finally
    Reader.Free;
  end;
end;

function TRtmpChunkReassembler.TryReadMessage(out AMessage: TRtmpChunkMessage): Boolean;
var
  BytesBefore: Integer;
begin
  repeat
    BytesBefore := PendingBytes;
    Result := TryReadChunk(AMessage);
    if Result then
      Exit(True);
    if PendingBytes = BytesBefore then
      Exit(False);
  until False;
end;

end.

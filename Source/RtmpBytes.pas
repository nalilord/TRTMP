unit RtmpBytes;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils;

type
  ERtmpByteReader = class(Exception);
  ERtmpByteWriter = class(Exception);

  TRtmpByteReader = class
  private
    FBuffer: TBytes;
    FPosition: Integer;
    procedure Require(ACount: Integer);
    procedure SetPosition(AValue: Integer);
  public
    constructor Create(const ABuffer: TBytes); overload;
    constructor Create(const ABuffer: TBytes; APosition: Integer); overload;

    function ReadBytes(ACount: Integer): TBytes;
    function ReadDoubleBE: Double;
    function ReadUInt8: Byte;
    function ReadUInt16BE: Word;
    function ReadUInt24BE: UInt32;
    function ReadUInt32BE: UInt32;
    function ReadUInt32LE: UInt32;
    function Remaining: Integer;
    procedure Skip(ACount: Integer);

    property Position: Integer read FPosition write SetPosition;
  end;

  TRtmpByteWriter = class
  private
    FBuffer: TBytes;
    FSize: Integer;
    procedure EnsureCapacity(AAdditionalBytes: Integer);
  public
    constructor Create; overload;
    constructor Create(AInitialCapacity: Integer); overload;

    procedure Clear;
    function Data: Pointer;
    function ToBytes: TBytes;
    procedure WriteBuffer(const ABuffer; ACount: Integer);
    procedure WriteBytes(const ABytes: TBytes);
    procedure WriteBytesRange(const ABytes: TBytes; AOffset, ACount: Integer);
    procedure WriteDoubleBE(const AValue: Double);
    procedure WriteUInt8(AValue: Byte);
    procedure WriteUInt16BE(AValue: Word);
    procedure WriteUInt24BE(AValue: UInt32);
    procedure WriteUInt32BE(AValue: UInt32);
    procedure WriteUInt32LE(AValue: UInt32);

    property Size: Integer read FSize;
  end;

function RtmpStringToUtf8Bytes(const AValue: string): TBytes;
function RtmpUtf8BytesToString(const ABytes: TBytes): string;

implementation

function RtmpStringToUtf8Bytes(const AValue: string): TBytes;
var
  Utf8Value: UTF8String;
  I: Integer;
begin
  Utf8Value := UTF8Encode(AValue);
  Result := nil;
  SetLength(Result, Length(Utf8Value));
  for I := 1 to Length(Utf8Value) do
    Result[I - 1] := Ord(Utf8Value[I]);
end;

function RtmpUtf8BytesToString(const ABytes: TBytes): string;
var
  Utf8Value: UTF8String;
  I: Integer;
begin
  SetLength(Utf8Value, Length(ABytes));
  for I := 0 to High(ABytes) do
    Utf8Value[I + 1] := AnsiChar(ABytes[I]);
  Result := string(UTF8ToString(Utf8Value));
end;

constructor TRtmpByteReader.Create(const ABuffer: TBytes);
begin
  Create(ABuffer, 0);
end;

constructor TRtmpByteReader.Create(const ABuffer: TBytes; APosition: Integer);
begin
  inherited Create;
  FBuffer := ABuffer;
  SetPosition(APosition);
end;

procedure TRtmpByteReader.Require(ACount: Integer);
begin
  if ACount < 0 then
    raise ERtmpByteReader.Create('Negative byte count requested');

  if FPosition + ACount > Length(FBuffer) then
    raise ERtmpByteReader.CreateFmt(
      'Byte reader underrun: need %d bytes at position %d, only %d remaining',
      [ACount, FPosition, Remaining]);
end;

function TRtmpByteReader.ReadBytes(ACount: Integer): TBytes;
begin
  Require(ACount);
  Result := nil;
  SetLength(Result, ACount);
  if ACount > 0 then
    Move(FBuffer[FPosition], Result[0], ACount);
  Inc(FPosition, ACount);
end;

function TRtmpByteReader.ReadDoubleBE: Double;
var
  RawBytes: array[0..7] of Byte;
  HostBytes: array[0..7] of Byte;
  I: Integer;
begin
  Require(SizeOf(Double));
  Move(FBuffer[FPosition], RawBytes[0], SizeOf(Double));
  Inc(FPosition, SizeOf(Double));

  for I := 0 to High(RawBytes) do
    HostBytes[I] := RawBytes[High(RawBytes) - I];

  Move(HostBytes[0], Result, SizeOf(Double));
end;

function TRtmpByteReader.ReadUInt8: Byte;
begin
  Require(SizeOf(Byte));
  Result := FBuffer[FPosition];
  Inc(FPosition);
end;

function TRtmpByteReader.ReadUInt16BE: Word;
begin
  Require(2);
  Result := (UInt32(FBuffer[FPosition]) shl 8) or
    UInt32(FBuffer[FPosition + 1]);
  Inc(FPosition, 2);
end;

function TRtmpByteReader.ReadUInt24BE: UInt32;
begin
  Require(3);
  Result := (UInt32(FBuffer[FPosition]) shl 16) or
    (UInt32(FBuffer[FPosition + 1]) shl 8) or
    UInt32(FBuffer[FPosition + 2]);
  Inc(FPosition, 3);
end;

function TRtmpByteReader.ReadUInt32BE: UInt32;
begin
  Require(4);
  Result := (UInt32(FBuffer[FPosition]) shl 24) or
    (UInt32(FBuffer[FPosition + 1]) shl 16) or
    (UInt32(FBuffer[FPosition + 2]) shl 8) or
    UInt32(FBuffer[FPosition + 3]);
  Inc(FPosition, 4);
end;

function TRtmpByteReader.ReadUInt32LE: UInt32;
begin
  Require(4);
  Result := UInt32(FBuffer[FPosition]) or
    (UInt32(FBuffer[FPosition + 1]) shl 8) or
    (UInt32(FBuffer[FPosition + 2]) shl 16) or
    (UInt32(FBuffer[FPosition + 3]) shl 24);
  Inc(FPosition, 4);
end;

function TRtmpByteReader.Remaining: Integer;
begin
  Result := Length(FBuffer) - FPosition;
end;

procedure TRtmpByteReader.SetPosition(AValue: Integer);
begin
  if (AValue < 0) or (AValue > Length(FBuffer)) then
    raise ERtmpByteReader.CreateFmt('Invalid byte reader position %d', [AValue]);
  FPosition := AValue;
end;

procedure TRtmpByteReader.Skip(ACount: Integer);
begin
  Require(ACount);
  Inc(FPosition, ACount);
end;

constructor TRtmpByteWriter.Create;
begin
  Create(256);
end;

constructor TRtmpByteWriter.Create(AInitialCapacity: Integer);
begin
  inherited Create;
  if AInitialCapacity < 0 then
    raise ERtmpByteWriter.Create('Negative initial capacity');
  SetLength(FBuffer, AInitialCapacity);
  FSize := 0;
end;

procedure TRtmpByteWriter.Clear;
begin
  FSize := 0;
end;

procedure TRtmpByteWriter.EnsureCapacity(AAdditionalBytes: Integer);
var
  RequiredSize: Integer;
  NewCapacity: Integer;
begin
  if AAdditionalBytes < 0 then
    raise ERtmpByteWriter.Create('Negative growth requested');

  RequiredSize := FSize + AAdditionalBytes;
  if RequiredSize <= Length(FBuffer) then
    Exit;

  NewCapacity := Length(FBuffer);
  if NewCapacity = 0 then
    NewCapacity := 256;
  while NewCapacity < RequiredSize do
    NewCapacity := NewCapacity * 2;

  SetLength(FBuffer, NewCapacity);
end;

function TRtmpByteWriter.Data: Pointer;
begin
  if FSize <= 0 then
    Result := nil
  else
    Result := @FBuffer[0];
end;

function TRtmpByteWriter.ToBytes: TBytes;
begin
  Result := nil;
  SetLength(Result, FSize);
  if FSize > 0 then
    Move(FBuffer[0], Result[0], FSize);
end;

procedure TRtmpByteWriter.WriteBuffer(const ABuffer; ACount: Integer);
begin
  if ACount < 0 then
    raise ERtmpByteWriter.Create('Negative buffer write requested');

  if ACount = 0 then
    Exit;

  EnsureCapacity(ACount);
  Move(ABuffer, FBuffer[FSize], ACount);
  Inc(FSize, ACount);
end;

procedure TRtmpByteWriter.WriteBytes(const ABytes: TBytes);
begin
  WriteBytesRange(ABytes, 0, Length(ABytes));
end;

procedure TRtmpByteWriter.WriteBytesRange(const ABytes: TBytes; AOffset,
  ACount: Integer);
begin
  if (AOffset < 0) or (ACount < 0) or (AOffset > Length(ABytes)) or
    (AOffset + ACount > Length(ABytes)) then
    raise ERtmpByteWriter.CreateFmt(
      'Invalid byte range offset=%d count=%d length=%d',
      [AOffset, ACount, Length(ABytes)]);

  if ACount = 0 then
    Exit;

  WriteBuffer(ABytes[AOffset], ACount);
end;

procedure TRtmpByteWriter.WriteDoubleBE(const AValue: Double);
var
  HostBytes: array[0..7] of Byte;
  RawBytes: array[0..7] of Byte;
  I: Integer;
begin
  Move(AValue, HostBytes[0], SizeOf(Double));
  for I := 0 to High(HostBytes) do
    RawBytes[I] := HostBytes[High(HostBytes) - I];
  EnsureCapacity(SizeOf(Double));
  Move(RawBytes[0], FBuffer[FSize], SizeOf(Double));
  Inc(FSize, SizeOf(Double));
end;

procedure TRtmpByteWriter.WriteUInt8(AValue: Byte);
begin
  EnsureCapacity(1);
  FBuffer[FSize] := AValue;
  Inc(FSize);
end;

procedure TRtmpByteWriter.WriteUInt16BE(AValue: Word);
begin
  EnsureCapacity(2);
  FBuffer[FSize] := Byte((AValue shr 8) and $FF);
  FBuffer[FSize + 1] := Byte(AValue and $FF);
  Inc(FSize, 2);
end;

procedure TRtmpByteWriter.WriteUInt24BE(AValue: UInt32);
begin
  EnsureCapacity(3);
  FBuffer[FSize] := Byte((AValue shr 16) and $FF);
  FBuffer[FSize + 1] := Byte((AValue shr 8) and $FF);
  FBuffer[FSize + 2] := Byte(AValue and $FF);
  Inc(FSize, 3);
end;

procedure TRtmpByteWriter.WriteUInt32BE(AValue: UInt32);
begin
  EnsureCapacity(4);
  FBuffer[FSize] := Byte((AValue shr 24) and $FF);
  FBuffer[FSize + 1] := Byte((AValue shr 16) and $FF);
  FBuffer[FSize + 2] := Byte((AValue shr 8) and $FF);
  FBuffer[FSize + 3] := Byte(AValue and $FF);
  Inc(FSize, 4);
end;

procedure TRtmpByteWriter.WriteUInt32LE(AValue: UInt32);
begin
  EnsureCapacity(4);
  FBuffer[FSize] := Byte(AValue and $FF);
  FBuffer[FSize + 1] := Byte((AValue shr 8) and $FF);
  FBuffer[FSize + 2] := Byte((AValue shr 16) and $FF);
  FBuffer[FSize + 3] := Byte((AValue shr 24) and $FF);
  Inc(FSize, 4);
end;

end.

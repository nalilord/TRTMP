unit RtmpAmf0;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  Classes,
  Contnrs,
  SysUtils,
  RtmpBytes;

type
  ERtmpAmf0Error = class(Exception);

  TRtmpAmf0TypeMarker = (
    amfNumber = $00,
    amfBoolean = $01,
    amfString = $02,
    amfObject = $03,
    amfNull = $05,
    amfUndefined = $06,
    amfEcmaArray = $08,
    amfObjectEnd = $09,
    amfStrictArray = $0A,
    amfDate = $0B,
    amfLongString = $0C
  );

  TRtmpAmf0ValueKind = (
    avNumber,
    avBoolean,
    avString,
    avObject,
    avNull,
    avUndefined,
    avEcmaArray
  );

  TRtmpAmf0Value = class
  private
    FKind: TRtmpAmf0ValueKind;
  public
    constructor Create(AKind: TRtmpAmf0ValueKind);
    function AsBoolean: Boolean; virtual;
    function AsNumber: Double; virtual;
    function AsString: string; virtual;
    function Clone: TRtmpAmf0Value; virtual; abstract;

    property Kind: TRtmpAmf0ValueKind read FKind;
  end;

  TRtmpAmf0Number = class(TRtmpAmf0Value)
  private
    FValue: Double;
  public
    constructor Create(AValue: Double);
    function AsNumber: Double; override;
    function Clone: TRtmpAmf0Value; override;
    property Value: Double read FValue;
  end;

  TRtmpAmf0Boolean = class(TRtmpAmf0Value)
  private
    FValue: Boolean;
  public
    constructor Create(AValue: Boolean);
    function AsBoolean: Boolean; override;
    function Clone: TRtmpAmf0Value; override;
    property Value: Boolean read FValue;
  end;

  TRtmpAmf0String = class(TRtmpAmf0Value)
  private
    FValue: string;
  public
    constructor Create(const AValue: string);
    function AsString: string; override;
    function Clone: TRtmpAmf0Value; override;
    property Value: string read FValue;
  end;

  TRtmpAmf0Null = class(TRtmpAmf0Value)
  public
    constructor Create;
    function Clone: TRtmpAmf0Value; override;
  end;

  TRtmpAmf0Undefined = class(TRtmpAmf0Value)
  public
    constructor Create;
    function Clone: TRtmpAmf0Value; override;
  end;

  TRtmpAmf0NamedValue = class
  private
    FName: string;
    FValue: TRtmpAmf0Value;
  public
    constructor Create(const AName: string; AValue: TRtmpAmf0Value);
    destructor Destroy; override;
    function Clone: TRtmpAmf0NamedValue;

    property Name: string read FName;
    property Value: TRtmpAmf0Value read FValue;
  end;

  TRtmpAmf0Object = class(TRtmpAmf0Value)
  private
    FItems: TObjectList;
    function GetCount: Integer;
    function GetItem(Index: Integer): TRtmpAmf0NamedValue;
  public
    constructor Create(AKind: TRtmpAmf0ValueKind = avObject);
    destructor Destroy; override;

    function Add(const AName: string; AValue: TRtmpAmf0Value): TRtmpAmf0Object;
    function Clone: TRtmpAmf0Value; override;
    function Find(const AName: string): TRtmpAmf0Value;
    function GetBoolean(const AName: string; ADefault: Boolean = False): Boolean;
    function GetNumber(const AName: string; ADefault: Double = 0.0): Double;
    function GetString(const AName: string; const ADefault: string = ''): string;

    property Count: Integer read GetCount;
    property Items[Index: Integer]: TRtmpAmf0NamedValue read GetItem; default;
  end;

  TRtmpAmf0ValueList = class(TObjectList)
  private
    function GetItem(Index: Integer): TRtmpAmf0Value;
  public
    function AddValue(AValue: TRtmpAmf0Value): Integer;
    property Items[Index: Integer]: TRtmpAmf0Value read GetItem; default;
  end;

  TRtmpAmf0 = class
  private
    class function ReadObject(AReader: TRtmpByteReader;
      AKind: TRtmpAmf0ValueKind): TRtmpAmf0Object; static;
    class function ReadUtf8String(AReader: TRtmpByteReader;
      ALength: Integer): string; static;
    class procedure WriteObject(AWriter: TRtmpByteWriter;
      AObject: TRtmpAmf0Object); static;
    class procedure WriteUtf8String(AWriter: TRtmpByteWriter;
      const AValue: string); static;
  public
    class function DecodeValue(AReader: TRtmpByteReader): TRtmpAmf0Value; static;
    class function DecodeValues(const ABytes: TBytes): TRtmpAmf0ValueList; static;
    class function EncodeValues(AValues: TRtmpAmf0ValueList): TBytes; static;
    class procedure EncodeValue(AWriter: TRtmpByteWriter; AValue: TRtmpAmf0Value); static;
  end;

implementation

function MarkerByte(AMarker: TRtmpAmf0TypeMarker): Byte;
begin
  Result := Byte(Ord(AMarker));
end;

constructor TRtmpAmf0Value.Create(AKind: TRtmpAmf0ValueKind);
begin
  inherited Create;
  FKind := AKind;
end;

function TRtmpAmf0Value.AsBoolean: Boolean;
begin
  Result := False;
  raise ERtmpAmf0Error.Create('AMF0 value is not a Boolean');
end;

function TRtmpAmf0Value.AsNumber: Double;
begin
  Result := 0.0;
  raise ERtmpAmf0Error.Create('AMF0 value is not a Number');
end;

function TRtmpAmf0Value.AsString: string;
begin
  Result := '';
  raise ERtmpAmf0Error.Create('AMF0 value is not a String');
end;

constructor TRtmpAmf0Number.Create(AValue: Double);
begin
  inherited Create(avNumber);
  FValue := AValue;
end;

function TRtmpAmf0Number.AsNumber: Double;
begin
  Result := FValue;
end;

function TRtmpAmf0Number.Clone: TRtmpAmf0Value;
begin
  Result := TRtmpAmf0Number.Create(FValue);
end;

constructor TRtmpAmf0Boolean.Create(AValue: Boolean);
begin
  inherited Create(avBoolean);
  FValue := AValue;
end;

function TRtmpAmf0Boolean.AsBoolean: Boolean;
begin
  Result := FValue;
end;

function TRtmpAmf0Boolean.Clone: TRtmpAmf0Value;
begin
  Result := TRtmpAmf0Boolean.Create(FValue);
end;

constructor TRtmpAmf0String.Create(const AValue: string);
begin
  inherited Create(avString);
  FValue := AValue;
end;

function TRtmpAmf0String.AsString: string;
begin
  Result := FValue;
end;

function TRtmpAmf0String.Clone: TRtmpAmf0Value;
begin
  Result := TRtmpAmf0String.Create(FValue);
end;

constructor TRtmpAmf0Null.Create;
begin
  inherited Create(avNull);
end;

function TRtmpAmf0Null.Clone: TRtmpAmf0Value;
begin
  Result := TRtmpAmf0Null.Create;
end;

constructor TRtmpAmf0Undefined.Create;
begin
  inherited Create(avUndefined);
end;

function TRtmpAmf0Undefined.Clone: TRtmpAmf0Value;
begin
  Result := TRtmpAmf0Undefined.Create;
end;

constructor TRtmpAmf0NamedValue.Create(const AName: string; AValue: TRtmpAmf0Value);
begin
  inherited Create;
  FName := AName;
  FValue := AValue;
end;

destructor TRtmpAmf0NamedValue.Destroy;
begin
  FValue.Free;
  inherited Destroy;
end;

function TRtmpAmf0NamedValue.Clone: TRtmpAmf0NamedValue;
begin
  if FValue <> nil then
    Result := TRtmpAmf0NamedValue.Create(FName, FValue.Clone)
  else
    Result := TRtmpAmf0NamedValue.Create(FName, nil);
end;

constructor TRtmpAmf0Object.Create(AKind: TRtmpAmf0ValueKind);
begin
  inherited Create(AKind);
  FItems := TObjectList.Create(True);
end;

destructor TRtmpAmf0Object.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

function TRtmpAmf0Object.Add(const AName: string; AValue: TRtmpAmf0Value): TRtmpAmf0Object;
begin
  FItems.Add(TRtmpAmf0NamedValue.Create(AName, AValue));
  Result := Self;
end;

function TRtmpAmf0Object.Clone: TRtmpAmf0Value;
var
  I: Integer;
  NewObject: TRtmpAmf0Object;
begin
  NewObject := TRtmpAmf0Object.Create(Kind);
  for I := 0 to FItems.Count - 1 do
    NewObject.FItems.Add(TRtmpAmf0NamedValue(FItems[I]).Clone);
  Result := NewObject;
end;

function TRtmpAmf0Object.Find(const AName: string): TRtmpAmf0Value;
var
  I: Integer;
  NamedValue: TRtmpAmf0NamedValue;
begin
  Result := nil;
  for I := 0 to FItems.Count - 1 do
  begin
    NamedValue := TRtmpAmf0NamedValue(FItems[I]);
    if SameText(NamedValue.Name, AName) then
    begin
      Result := NamedValue.Value;
      Exit;
    end;
  end;
end;

function TRtmpAmf0Object.GetBoolean(const AName: string; ADefault: Boolean): Boolean;
var
  Value: TRtmpAmf0Value;
begin
  Value := Find(AName);
  if (Value <> nil) and (Value is TRtmpAmf0Boolean) then
    Result := Value.AsBoolean
  else
    Result := ADefault;
end;

function TRtmpAmf0Object.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TRtmpAmf0Object.GetItem(Index: Integer): TRtmpAmf0NamedValue;
begin
  Result := TRtmpAmf0NamedValue(FItems[Index]);
end;

function TRtmpAmf0Object.GetNumber(const AName: string; ADefault: Double): Double;
var
  Value: TRtmpAmf0Value;
begin
  Value := Find(AName);
  if (Value <> nil) and (Value is TRtmpAmf0Number) then
    Result := Value.AsNumber
  else
    Result := ADefault;
end;

function TRtmpAmf0Object.GetString(const AName: string; const ADefault: string): string;
var
  Value: TRtmpAmf0Value;
begin
  Value := Find(AName);
  if (Value <> nil) and (Value is TRtmpAmf0String) then
    Result := Value.AsString
  else
    Result := ADefault;
end;

function TRtmpAmf0ValueList.AddValue(AValue: TRtmpAmf0Value): Integer;
begin
  Result := Add(AValue);
end;

function TRtmpAmf0ValueList.GetItem(Index: Integer): TRtmpAmf0Value;
begin
  Result := TRtmpAmf0Value(inherited Items[Index]);
end;

class function TRtmpAmf0.DecodeValue(AReader: TRtmpByteReader): TRtmpAmf0Value;
var
  Marker: Byte;
begin
  Marker := AReader.ReadUInt8;
  case Marker of
    Byte(amfNumber):
      Result := TRtmpAmf0Number.Create(AReader.ReadDoubleBE);
    Byte(amfBoolean):
      Result := TRtmpAmf0Boolean.Create(AReader.ReadUInt8 <> 0);
    Byte(amfString):
      Result := TRtmpAmf0String.Create(ReadUtf8String(AReader, AReader.ReadUInt16BE));
    Byte(amfObject):
      Result := ReadObject(AReader, avObject);
    Byte(amfNull):
      Result := TRtmpAmf0Null.Create;
    Byte(amfUndefined):
      Result := TRtmpAmf0Undefined.Create;
    Byte(amfEcmaArray):
      begin
        AReader.ReadUInt32BE;
        Result := ReadObject(AReader, avEcmaArray);
      end;
    Byte(amfLongString):
      Result := TRtmpAmf0String.Create(ReadUtf8String(AReader, Integer(AReader.ReadUInt32BE)));
  else
    raise ERtmpAmf0Error.CreateFmt('Unsupported AMF0 marker $%.2x', [Marker]);
  end;
end;

class function TRtmpAmf0.DecodeValues(const ABytes: TBytes): TRtmpAmf0ValueList;
var
  Reader: TRtmpByteReader;
begin
  Result := TRtmpAmf0ValueList.Create(True);
  Reader := TRtmpByteReader.Create(ABytes);
  try
    while Reader.Remaining > 0 do
      Result.AddValue(DecodeValue(Reader));
  finally
    Reader.Free;
  end;
end;

class function TRtmpAmf0.EncodeValues(AValues: TRtmpAmf0ValueList): TBytes;
var
  I: Integer;
  Writer: TRtmpByteWriter;
begin
  Writer := TRtmpByteWriter.Create;
  try
    if AValues <> nil then
      for I := 0 to AValues.Count - 1 do
        EncodeValue(Writer, AValues[I]);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

class procedure TRtmpAmf0.EncodeValue(AWriter: TRtmpByteWriter; AValue: TRtmpAmf0Value);
var
  Utf8Bytes: TBytes;
begin
  if AValue = nil then
  begin
    AWriter.WriteUInt8(MarkerByte(amfNull));
    Exit;
  end;

  case AValue.Kind of
    avNumber:
      begin
        AWriter.WriteUInt8(MarkerByte(amfNumber));
        AWriter.WriteDoubleBE(TRtmpAmf0Number(AValue).Value);
      end;
    avBoolean:
      begin
        AWriter.WriteUInt8(MarkerByte(amfBoolean));
        if TRtmpAmf0Boolean(AValue).Value then
          AWriter.WriteUInt8(1)
        else
          AWriter.WriteUInt8(0);
      end;
    avString:
      begin
        Utf8Bytes := RtmpStringToUtf8Bytes(TRtmpAmf0String(AValue).Value);
        if Length(Utf8Bytes) <= High(Word) then
        begin
          AWriter.WriteUInt8(MarkerByte(amfString));
          AWriter.WriteUInt16BE(Length(Utf8Bytes));
        end
        else
        begin
          AWriter.WriteUInt8(MarkerByte(amfLongString));
          AWriter.WriteUInt32BE(Length(Utf8Bytes));
        end;
        AWriter.WriteBytes(Utf8Bytes);
      end;
    avObject:
      begin
        AWriter.WriteUInt8(MarkerByte(amfObject));
        WriteObject(AWriter, TRtmpAmf0Object(AValue));
      end;
    avNull:
      AWriter.WriteUInt8(MarkerByte(amfNull));
    avUndefined:
      AWriter.WriteUInt8(MarkerByte(amfUndefined));
    avEcmaArray:
      begin
        AWriter.WriteUInt8(MarkerByte(amfEcmaArray));
        AWriter.WriteUInt32BE(TRtmpAmf0Object(AValue).Count);
        WriteObject(AWriter, TRtmpAmf0Object(AValue));
      end;
  else
    raise ERtmpAmf0Error.Create('Unsupported AMF0 value kind');
  end;
end;

class function TRtmpAmf0.ReadObject(AReader: TRtmpByteReader;
  AKind: TRtmpAmf0ValueKind): TRtmpAmf0Object;
var
  Name: string;
  NameLength: Word;
  Marker: Byte;
begin
  Result := TRtmpAmf0Object.Create(AKind);
  try
    while True do
    begin
      NameLength := AReader.ReadUInt16BE;
      if NameLength = 0 then
      begin
        Marker := AReader.ReadUInt8;
        if Marker <> Byte(amfObjectEnd) then
          raise ERtmpAmf0Error.CreateFmt(
            'Invalid AMF0 object terminator marker $%.2x', [Marker]);
        Break;
      end;

      Name := ReadUtf8String(AReader, NameLength);
      Result.Add(Name, DecodeValue(AReader));
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TRtmpAmf0.ReadUtf8String(AReader: TRtmpByteReader;
  ALength: Integer): string;
begin
  Result := RtmpUtf8BytesToString(AReader.ReadBytes(ALength));
end;

class procedure TRtmpAmf0.WriteObject(AWriter: TRtmpByteWriter;
  AObject: TRtmpAmf0Object);
var
  I: Integer;
  NameBytes: TBytes;
begin
  if AObject <> nil then
    for I := 0 to AObject.Count - 1 do
    begin
      NameBytes := RtmpStringToUtf8Bytes(AObject[I].Name);
      if Length(NameBytes) > High(Word) then
        raise ERtmpAmf0Error.CreateFmt(
          'AMF0 object property name too long: %d bytes', [Length(NameBytes)]);
      AWriter.WriteUInt16BE(Length(NameBytes));
      AWriter.WriteBytes(NameBytes);
      EncodeValue(AWriter, AObject[I].Value);
    end;

  AWriter.WriteUInt16BE(0);
  AWriter.WriteUInt8(MarkerByte(amfObjectEnd));
end;

class procedure TRtmpAmf0.WriteUtf8String(AWriter: TRtmpByteWriter;
  const AValue: string);
var
  Utf8Bytes: TBytes;
begin
  Utf8Bytes := RtmpStringToUtf8Bytes(AValue);
  if Length(Utf8Bytes) > High(Word) then
    raise ERtmpAmf0Error.CreateFmt('AMF0 short string too long: %d bytes',
      [Length(Utf8Bytes)]);
  AWriter.WriteUInt16BE(Length(Utf8Bytes));
  AWriter.WriteBytes(Utf8Bytes);
end;

end.

unit TRTMP.RTMP.Protocol.Command;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  Math,
  TRTMP.RTMP.Protocol.AMF0;

type
  ERtmpCommandError = class(Exception);

  TRtmpCommandMessage = class
  private
    FValues: TRtmpAmf0ValueList;
    function GetArgument(Index: Integer): TRtmpAmf0Value;
    function TryGetStringArgument(const AIndexes: array of Integer;
      out AValue: string): Boolean;
  public
    constructor Create(const APayload: TBytes);
    destructor Destroy; override;

    function ArgumentCount: Integer;
    function CommandName: string;
    function CommandObject: TRtmpAmf0Value;
    function IsCommand(const AName: string): Boolean;
    function TransactionID: Double;
    function TryGetConnectInfo(out AApp, ATcUrl, AFlashVer: string): Boolean;
    function TryGetConnectEnhancedCodecs(out ACodecs: string): Boolean;
    function TryGetConnectCapsEx(out ACapabilities: UInt32): Boolean;
    function TryGetResultCapsEx(out ACapabilities: UInt32): Boolean;
    function TryGetCreateStreamInfo(out AStreamID: Double): Boolean;
    function TryGetPlayInfo(out AStreamName: string): Boolean;
    function TryGetPublishInfo(out APublishingName, APublishingType: string): Boolean;
    function TryGetReleaseStreamInfo(out AStreamName: string): Boolean;

    property Arguments[Index: Integer]: TRtmpAmf0Value read GetArgument; default;
  end;

implementation

function TryGetCapsExValue(AValue: TRtmpAmf0Value;
  out ACapabilities: UInt32): Boolean;
var
  NumberValue: Double;
  Obj: TRtmpAmf0Object;
  Value: TRtmpAmf0Value;
begin
  ACapabilities:=0;
  Result:=False;
  if NOT (AValue IS TRtmpAmf0Object) then
    Exit;
  Obj:=TRtmpAmf0Object(AValue);
  Value:=Obj.Find('capsEx');
  if NOT (Value IS TRtmpAmf0Number) then
    Exit;
  NumberValue:=TRtmpAmf0Number(Value).Value;
  if IsNan(NumberValue) OR IsInfinite(NumberValue) OR
    (NumberValue < 0) OR (NumberValue > 4294967295.0) OR
    (NumberValue <> Trunc(NumberValue)) then
    Exit;
  ACapabilities:=UInt32(Trunc(NumberValue));
  Result:=True;
end;

constructor TRtmpCommandMessage.Create(const APayload: TBytes);
begin
  inherited Create;
  FValues:=TRtmpAmf0.DecodeValues(APayload);
end;

destructor TRtmpCommandMessage.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

function TRtmpCommandMessage.ArgumentCount: Integer;
begin
  if FValues <> nil then
    Result:=FValues.Count
  else
    Result:=0;
end;

function TRtmpCommandMessage.CommandName: string;
begin
  if (ArgumentCount > 0) AND (FValues[0] IS TRtmpAmf0String) then
    Result:=TRtmpAmf0String(FValues[0]).Value
  else
    Result:='';
end;

function TRtmpCommandMessage.CommandObject: TRtmpAmf0Value;
begin
  if ArgumentCount > 2 then
    Result:=FValues[2]
  else
    Result:=nil;
end;

function TRtmpCommandMessage.GetArgument(Index: Integer): TRtmpAmf0Value;
begin
  if (Index < 0) OR (Index >= ArgumentCount) then
    raise ERtmpCommandError.CreateFmt('AMF command argument index %d out of range',
      [Index]);
  Result:=FValues[Index];
end;

function TRtmpCommandMessage.TryGetStringArgument(const AIndexes: array of Integer;
  out AValue: string): Boolean;
var
  I: Integer;
  Index: Integer;
  Value: TRtmpAmf0Value;
begin
  AValue:='';
  Result:=False;

  for I:=0 to High(AIndexes) do
  begin
    Index:=AIndexes[I];
    if (Index < 0) OR (Index >= ArgumentCount) then
      Continue;

    Value:=FValues[Index];
    if Value IS TRtmpAmf0String then
    begin
      AValue:=TRtmpAmf0String(Value).Value;
      if AValue <> '' then
        Exit(True);
    end;
  end;
end;

function TRtmpCommandMessage.IsCommand(const AName: string): Boolean;
begin
  Result:=SameText(CommandName, AName);
end;

function TRtmpCommandMessage.TransactionID: Double;
begin
  if (ArgumentCount > 1) AND (FValues[1] IS TRtmpAmf0Number) then
    Result:=TRtmpAmf0Number(FValues[1]).Value
  else
    Result:=0.0;
end;

function TRtmpCommandMessage.TryGetConnectInfo(out AApp, ATcUrl,
  AFlashVer: string): Boolean;
var
  Obj: TRtmpAmf0Object;
  Value: TRtmpAmf0Value;
begin
  AApp:='';
  ATcUrl:='';
  AFlashVer:='';
  Result:=False;

  if NOT IsCommand('connect') then
    Exit;

  Value:=CommandObject;
  if NOT (Value IS TRtmpAmf0Object) then
    Exit;

  Obj:=TRtmpAmf0Object(Value);
  AApp:=Obj.GetString('app');
  ATcUrl:=Obj.GetString('tcUrl');
  AFlashVer:=Obj.GetString('flashVer');
  Result:=True;
end;

function TRtmpCommandMessage.TryGetConnectEnhancedCodecs(
  out ACodecs: string): Boolean;
var
  ArrayValue: TRtmpAmf0StrictArray;
  I: Integer;
  ItemValue: TRtmpAmf0Value;
  J: Integer;
  Obj: TRtmpAmf0Object;
  Value: TRtmpAmf0Value;
begin
  ACodecs:='';
  Result:=False;
  if NOT IsCommand('connect') then
    Exit;
  Value:=CommandObject;
  if NOT (Value IS TRtmpAmf0Object) then
    Exit;
  Obj:=TRtmpAmf0Object(Value);
  Value:=Obj.Find('fourCcLive');
  if NOT (Value IS TRtmpAmf0StrictArray) then
    Exit;

  ArrayValue:=TRtmpAmf0StrictArray(Value);
  if ArrayValue.Count > 64 then
    Exit;
  for I:=0 to ArrayValue.Count - 1 do
  begin
    ItemValue:=ArrayValue[I];
    if NOT (ItemValue IS TRtmpAmf0String) then
      Exit;
    if Length(TRtmpAmf0String(ItemValue).Value) <> 4 then
      Exit;
    for J:=1 to 4 do
      if (Ord(TRtmpAmf0String(ItemValue).Value[J]) < 32) OR
        (Ord(TRtmpAmf0String(ItemValue).Value[J]) > 126) then
        Exit;
    if ACodecs <> '' then
      ACodecs:=ACodecs + ',';
    ACodecs:=ACodecs + TRtmpAmf0String(ItemValue).Value;
  end;
  Result:=True;
end;

function TRtmpCommandMessage.TryGetConnectCapsEx(
  out ACapabilities: UInt32): Boolean;
begin
  ACapabilities:=0;
  Result:=IsCommand('connect') AND
    TryGetCapsExValue(CommandObject, ACapabilities);
end;

function TRtmpCommandMessage.TryGetResultCapsEx(
  out ACapabilities: UInt32): Boolean;
var
  I: Integer;
begin
  ACapabilities:=0;
  Result:=False;
  if NOT IsCommand('_result') then
    Exit;
  for I:=2 to ArgumentCount - 1 do
    if TryGetCapsExValue(FValues[I], ACapabilities) then
      Exit(True);
end;

function TRtmpCommandMessage.TryGetCreateStreamInfo(out AStreamID: Double): Boolean;
begin
  AStreamID:=0.0;
  Result:=IsCommand('createStream');
end;

function TRtmpCommandMessage.TryGetPlayInfo(out AStreamName: string): Boolean;
begin
  AStreamName:='';
  Result:=False;

  if NOT IsCommand('play') then
    Exit;

  Result:=TryGetStringArgument([3, 2], AStreamName);
end;

function TRtmpCommandMessage.TryGetPublishInfo(out APublishingName,
  APublishingType: string): Boolean;
begin
  APublishingName:='';
  APublishingType:='';
  Result:=False;

  if NOT IsCommand('publish') then
    Exit;

  TryGetStringArgument([3, 2], APublishingName);
  TryGetStringArgument([4, 3], APublishingType);
  Result:=(APublishingName <> '') OR (APublishingType <> '');
end;

function TRtmpCommandMessage.TryGetReleaseStreamInfo(out AStreamName: string): Boolean;
begin
  AStreamName:='';
  Result:=False;

  if NOT (IsCommand('releaseStream') OR IsCommand('FCPublish')) then
    Exit;

  Result:=TryGetStringArgument([3, 2], AStreamName);
end;

end.

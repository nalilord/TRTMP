unit RtmpCommand;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  RtmpAmf0;

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
    function TryGetCreateStreamInfo(out AStreamID: Double): Boolean;
    function TryGetPlayInfo(out AStreamName: string): Boolean;
    function TryGetPublishInfo(out APublishingName, APublishingType: string): Boolean;
    function TryGetReleaseStreamInfo(out AStreamName: string): Boolean;

    property Arguments[Index: Integer]: TRtmpAmf0Value read GetArgument; default;
  end;

implementation

constructor TRtmpCommandMessage.Create(const APayload: TBytes);
begin
  inherited Create;
  FValues := TRtmpAmf0.DecodeValues(APayload);
end;

destructor TRtmpCommandMessage.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

function TRtmpCommandMessage.ArgumentCount: Integer;
begin
  if FValues <> nil then
    Result := FValues.Count
  else
    Result := 0;
end;

function TRtmpCommandMessage.CommandName: string;
begin
  if (ArgumentCount > 0) and (FValues[0] is TRtmpAmf0String) then
    Result := TRtmpAmf0String(FValues[0]).Value
  else
    Result := '';
end;

function TRtmpCommandMessage.CommandObject: TRtmpAmf0Value;
begin
  if ArgumentCount > 2 then
    Result := FValues[2]
  else
    Result := nil;
end;

function TRtmpCommandMessage.GetArgument(Index: Integer): TRtmpAmf0Value;
begin
  if (Index < 0) or (Index >= ArgumentCount) then
    raise ERtmpCommandError.CreateFmt('AMF command argument index %d out of range',
      [Index]);
  Result := FValues[Index];
end;

function TRtmpCommandMessage.TryGetStringArgument(const AIndexes: array of Integer;
  out AValue: string): Boolean;
var
  I: Integer;
  Index: Integer;
  Value: TRtmpAmf0Value;
begin
  AValue := '';
  Result := False;

  for I := 0 to High(AIndexes) do
  begin
    Index := AIndexes[I];
    if (Index < 0) or (Index >= ArgumentCount) then
      Continue;

    Value := FValues[Index];
    if Value is TRtmpAmf0String then
    begin
      AValue := TRtmpAmf0String(Value).Value;
      if AValue <> '' then
        Exit(True);
    end;
  end;
end;

function TRtmpCommandMessage.IsCommand(const AName: string): Boolean;
begin
  Result := SameText(CommandName, AName);
end;

function TRtmpCommandMessage.TransactionID: Double;
begin
  if (ArgumentCount > 1) and (FValues[1] is TRtmpAmf0Number) then
    Result := TRtmpAmf0Number(FValues[1]).Value
  else
    Result := 0.0;
end;

function TRtmpCommandMessage.TryGetConnectInfo(out AApp, ATcUrl,
  AFlashVer: string): Boolean;
var
  Obj: TRtmpAmf0Object;
  Value: TRtmpAmf0Value;
begin
  AApp := '';
  ATcUrl := '';
  AFlashVer := '';
  Result := False;

  if not IsCommand('connect') then
    Exit;

  Value := CommandObject;
  if not (Value is TRtmpAmf0Object) then
    Exit;

  Obj := TRtmpAmf0Object(Value);
  AApp := Obj.GetString('app');
  ATcUrl := Obj.GetString('tcUrl');
  AFlashVer := Obj.GetString('flashVer');
  Result := True;
end;

function TRtmpCommandMessage.TryGetCreateStreamInfo(out AStreamID: Double): Boolean;
begin
  AStreamID := 0.0;
  Result := IsCommand('createStream');
end;

function TRtmpCommandMessage.TryGetPlayInfo(out AStreamName: string): Boolean;
begin
  AStreamName := '';
  Result := False;

  if not IsCommand('play') then
    Exit;

  Result := TryGetStringArgument([3, 2], AStreamName);
end;

function TRtmpCommandMessage.TryGetPublishInfo(out APublishingName,
  APublishingType: string): Boolean;
begin
  APublishingName := '';
  APublishingType := '';
  Result := False;

  if not IsCommand('publish') then
    Exit;

  TryGetStringArgument([3, 2], APublishingName);
  TryGetStringArgument([4, 3], APublishingType);
  Result := (APublishingName <> '') or (APublishingType <> '');
end;

function TRtmpCommandMessage.TryGetReleaseStreamInfo(out AStreamName: string): Boolean;
begin
  AStreamName := '';
  Result := False;

  if not (IsCommand('releaseStream') or IsCommand('FCPublish')) then
    Exit;

  Result := TryGetStringArgument([3, 2], AStreamName);
end;

end.

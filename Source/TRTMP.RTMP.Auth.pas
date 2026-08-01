unit TRTMP.RTMP.Auth;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils;

type
  TRtmpAuthorizationDecision = record
    Allowed: Boolean;
    Code: string;
    Description: string;
    class function Allow: TRtmpAuthorizationDecision; static;
    class function Deny(const ACode,
      ADescription: string): TRtmpAuthorizationDecision; static;
  end;

  TRtmpConnectAuthorizationContext = record
    RemoteAddress: string;
    RemotePort: Word;
    App: string;
    TcUrl: string;
    FlashVersion: string;
    EnhancedCodecs: string;
    EnhancedCapabilities: UInt32;
    function Parameter(const AName: string): string;
  end;

  TRtmpPublishAuthorizationContext = record
    RemoteAddress: string;
    RemotePort: Word;
    App: string;
    TcUrl: string;
    StreamName: string;
    PublishType: string;
    function Parameter(const AName: string): string;
  end;

  IRtmpServerAuthorizer = interface(IInterface)
    ['{7155A2A3-8034-4D9B-B917-AB3E4DB13751}']
    function AuthorizeConnect(
      const AContext: TRtmpConnectAuthorizationContext): TRtmpAuthorizationDecision;
    function AuthorizePublish(
      const AContext: TRtmpPublishAuthorizationContext): TRtmpAuthorizationDecision;
  end;

function RtmpExtractQueryParameter(const AValue,
  AName: string): string;

implementation

function HexDigitValue(AValue: Char): Integer;
begin
  Result:=-1;

  if (AValue >= '0') AND (AValue <= '9') then
    Result:=Ord(AValue) - Ord('0')
  else if (AValue >= 'a') AND (AValue <= 'f') then
    Result:=Ord(AValue) - Ord('a') + 10
  else if (AValue >= 'A') AND (AValue <= 'F') then
    Result:=Ord(AValue) - Ord('A') + 10;
end;

function DecodeQueryComponent(const AValue: string): string;
var
  HighNibble: Integer;
  I: Integer;
  LowNibble: Integer;
begin
  Result:='';
  I:=1;

  while I <= Length(AValue) do
  begin
    if AValue[I] = '+' then
    begin
      Result:=Result + ' ';
      Inc(I);
    end else
    if (AValue[I] = '%') AND (I + 2 <= Length(AValue)) then
    begin
      HighNibble:=HexDigitValue(AValue[I + 1]);
      LowNibble:=HexDigitValue(AValue[I + 2]);
      if (HighNibble >= 0) AND (LowNibble >= 0) then
      begin
        Result:=Result + Char((HighNibble SHL 4) OR LowNibble);
        Inc(I, 3);
      end else
      begin
        Result:=Result + AValue[I];
        Inc(I);
      end;
    end else
    begin
      Result:=Result + AValue[I];
      Inc(I);
    end;
  end;
end;

function RtmpExtractQueryParameter(const AValue,
  AName: string): string;
var
  AmpersandPos: Integer;
  EqualsPos: Integer;
  FragmentPos: Integer;
  Item: string;
  ItemName: string;
  Query: string;
begin
  Result:='';
  Query:=AValue;
  FragmentPos:=Pos('?', Query);
  if FragmentPos > 0 then
    Delete(Query, 1, FragmentPos)
  else if (Pos('=', Query) = 0) AND (Pos('&', Query) = 0) then
    Exit;

  FragmentPos:=Pos('#', Query);
  if FragmentPos > 0 then
    SetLength(Query, FragmentPos - 1);

  while Query <> '' do
  begin
    AmpersandPos:=Pos('&', Query);
    if AmpersandPos > 0 then
    begin
      Item:=Copy(Query, 1, AmpersandPos - 1);
      Delete(Query, 1, AmpersandPos);
    end else
    begin
      Item:=Query;
      Query:='';
    end;

    EqualsPos:=Pos('=', Item);
    if EqualsPos > 0 then
    begin
      ItemName:=DecodeQueryComponent(Copy(Item, 1, EqualsPos - 1));
      if ItemName = AName then
      begin
        Result:=DecodeQueryComponent(Copy(Item, EqualsPos + 1, MaxInt));
        Exit;
      end;
    end;
  end;
end;

class function TRtmpAuthorizationDecision.Allow: TRtmpAuthorizationDecision;
begin
  Result:=Default(TRtmpAuthorizationDecision);
  Result.Allowed:=True;
end;

class function TRtmpAuthorizationDecision.Deny(const ACode,
  ADescription: string): TRtmpAuthorizationDecision;
begin
  Result:=Default(TRtmpAuthorizationDecision);
  Result.Allowed:=False;
  Result.Code:=ACode;
  Result.Description:=ADescription;
end;

function TRtmpConnectAuthorizationContext.Parameter(
  const AName: string): string;
begin
  Result:=RtmpExtractQueryParameter(TcUrl, AName);
  if Result = '' then
    Result:=RtmpExtractQueryParameter(App, AName);
end;

function TRtmpPublishAuthorizationContext.Parameter(
  const AName: string): string;
begin
  Result:=RtmpExtractQueryParameter(StreamName, AName);
  if Result = '' then
    Result:=RtmpExtractQueryParameter(TcUrl, AName);
  if Result = '' then
    Result:=RtmpExtractQueryParameter(App, AName);
end;

end.

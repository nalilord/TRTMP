program RtmpAmf0Smoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  Math,
  TRTMP.RTMP.Protocol.AMF0,
  TRTMP.Core.Bytes,
  TRTMP.RTMP.Protocol.Command;

procedure AssertTrue(const AMessage: string; ACondition: Boolean);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure TestStrictArrayRoundTrip;
var
  ArrayValue: TRtmpAmf0StrictArray;
  Bytes: TBytes;
  ConnectObject: TRtmpAmf0Object;
  DecodedArray: TRtmpAmf0StrictArray;
  DecodedObject: TRtmpAmf0Object;
  Values: TRtmpAmf0ValueList;
begin
  Values:=TRtmpAmf0ValueList.Create(True);
  try
    ConnectObject:=TRtmpAmf0Object.Create;
    ArrayValue:=TRtmpAmf0StrictArray.Create;
    ArrayValue.Add(TRtmpAmf0String.Create('hvc1'));
    ArrayValue.Add(TRtmpAmf0String.Create('av01'));
    ArrayValue.Add(TRtmpAmf0String.Create('vp09'));
    ConnectObject.Add('fourCcLive', ArrayValue);
    Values.AddValue(ConnectObject);

    Bytes:=TRtmpAmf0.EncodeValues(Values);
  finally
    Values.Free;
  end;

  Values:=TRtmpAmf0.DecodeValues(Bytes);
  try
    AssertTrue('strict array smoke: expected one outer value', Values.Count = 1);
    AssertTrue('strict array smoke: expected object', Values[0] IS TRtmpAmf0Object);
    DecodedObject:=TRtmpAmf0Object(Values[0]);
    AssertTrue('strict array smoke: fourCcLive missing',
      DecodedObject.Find('fourCcLive') IS TRtmpAmf0StrictArray);
    DecodedArray:=TRtmpAmf0StrictArray(DecodedObject.Find('fourCcLive'));
    AssertTrue('strict array smoke: expected three codecs', DecodedArray.Count = 3);
    AssertTrue('strict array smoke: HEVC value mismatch',
      DecodedArray[0].AsString = 'hvc1');
    AssertTrue('strict array smoke: AV1 value mismatch',
      DecodedArray[1].AsString = 'av01');
    AssertTrue('strict array smoke: VP9 value mismatch',
      DecodedArray[2].AsString = 'vp09');
  finally
    Values.Free;
  end;
end;

procedure TestStrictArrayCountGuard;
var
  Bytes: TBytes;
  RaisedExpectedError: Boolean;
  Values: TRtmpAmf0ValueList;
begin
  SetLength(Bytes, 5);
  Bytes[0]:=Byte(amfStrictArray);
  Bytes[1]:=0;
  Bytes[2]:=0;
  Bytes[3]:=0;
  Bytes[4]:=1;
  RaisedExpectedError:=False;
  Values:=nil;
  try
    try
      Values:=TRtmpAmf0.DecodeValues(Bytes);
    except
      on E: ERtmpAmf0Error do
        RaisedExpectedError:=Pos('exceeds remaining payload', E.Message) > 0;
    end;
  finally
    Values.Free;
  end;
  AssertTrue('strict array smoke: malformed count was not rejected',
    RaisedExpectedError);
end;

function BuildCapsExCommand(const AName: string; AValue: TRtmpAmf0Value): TBytes;
var
  Obj: TRtmpAmf0Object;
  Values: TRtmpAmf0ValueList;
begin
  Values:=TRtmpAmf0ValueList.Create(True);
  try
    Values.AddValue(TRtmpAmf0String.Create(AName));
    Values.AddValue(TRtmpAmf0Number.Create(1));
    Obj:=TRtmpAmf0Object.Create;
    Obj.Add('capsEx', AValue);
    Values.AddValue(Obj);
    Result:=TRtmpAmf0.EncodeValues(Values);
  finally
    Values.Free;
  end;
end;

function BuildResultCapsExInStatus(AValue: UInt32): TBytes;
var
  Obj: TRtmpAmf0Object;
  Values: TRtmpAmf0ValueList;
begin
  Values:=TRtmpAmf0ValueList.Create(True);
  try
    Values.AddValue(TRtmpAmf0String.Create('_result'));
    Values.AddValue(TRtmpAmf0Number.Create(1));
    Values.AddValue(TRtmpAmf0Null.Create);
    Obj:=TRtmpAmf0Object.Create;
    Obj.Add('capsEx', TRtmpAmf0Number.Create(AValue));
    Values.AddValue(Obj);
    Result:=TRtmpAmf0.EncodeValues(Values);
  finally
    Values.Free;
  end;
end;

procedure TestCapsExCommandParsing;
var
  Capabilities: UInt32;
  Command: TRtmpCommandMessage;
  Payload: TBytes;
begin
  Payload:=BuildCapsExCommand('connect', TRtmpAmf0Number.Create(6));
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: valid connect value rejected',
      Command.TryGetConnectCapsEx(Capabilities));
    AssertTrue('capsEx smoke: connect value mismatch', Capabilities = 6);
  finally
    Command.Free;
  end;

  Payload:=BuildCapsExCommand('_result',
    TRtmpAmf0Number.Create(4294967295.0));
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: UInt32 maximum rejected',
      Command.TryGetResultCapsEx(Capabilities));
    AssertTrue('capsEx smoke: UInt32 maximum mismatch',
      Capabilities = High(UInt32));
  finally
    Command.Free;
  end;

  Payload:=BuildResultCapsExInStatus(6);
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: status-object result value rejected',
      Command.TryGetResultCapsEx(Capabilities));
    AssertTrue('capsEx smoke: status-object result value mismatch',
      Capabilities = 6);
  finally
    Command.Free;
  end;

  Payload:=BuildCapsExCommand('connect', TRtmpAmf0Number.Create(6.5));
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: fractional value accepted',
      NOT Command.TryGetConnectCapsEx(Capabilities));
  finally
    Command.Free;
  end;

  Payload:=BuildCapsExCommand('connect', TRtmpAmf0Number.Create(-1));
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: negative value accepted',
      NOT Command.TryGetConnectCapsEx(Capabilities));
  finally
    Command.Free;
  end;

  Payload:=BuildCapsExCommand('connect',
    TRtmpAmf0Number.Create(4294967296.0));
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: overflow value accepted',
      NOT Command.TryGetConnectCapsEx(Capabilities));
  finally
    Command.Free;
  end;

  Payload:=BuildCapsExCommand('connect', TRtmpAmf0String.Create('6'));
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: string value accepted',
      NOT Command.TryGetConnectCapsEx(Capabilities));
  finally
    Command.Free;
  end;

  Payload:=BuildCapsExCommand('connect', TRtmpAmf0Number.Create(NaN));
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: NaN value accepted',
      NOT Command.TryGetConnectCapsEx(Capabilities));
  finally
    Command.Free;
  end;

  Payload:=BuildCapsExCommand('connect', TRtmpAmf0Number.Create(Infinity));
  Command:=TRtmpCommandMessage.Create(Payload);
  try
    AssertTrue('capsEx smoke: infinite value accepted',
      NOT Command.TryGetConnectCapsEx(Capabilities));
  finally
    Command.Free;
  end;
end;

begin
  TestStrictArrayRoundTrip;
  TestStrictArrayCountGuard;
  TestCapsExCommandParsing;
  WriteLn('AMF0 smoke passed: strict-array, count guard, and capsEx validation');
end.

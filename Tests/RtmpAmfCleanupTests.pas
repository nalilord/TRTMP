program RtmpAmfCleanupTests;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
uses SysUtils, TRTMP.RTMP.Protocol.AMF0;
var Payload: TBytes; Values: TRtmpAmf0ValueList; I: Integer; Rejected: Boolean;
begin
  SetLength(Payload, 2);
  Payload[0]:=$05;
  Payload[1]:=$FF;
  for I:=1 to 100 do
  begin
    Rejected:=False;
    try
      Values:=TRtmpAmf0.DecodeValues(Payload);
      Values.Free;
    except
      on E: ERtmpAmf0Error do Rejected:=True;
    end;
    if NOT Rejected then raise Exception.Create('Malformed AMF must be rejected');
  end;
  // Run with FPC -gh; the runner also verifies zero unfreed heap blocks.
  Writeln('RtmpAmfCleanupTests: PASS');
end.

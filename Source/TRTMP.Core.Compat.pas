unit TRTMP.Core.Compat;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  Math,
  SysUtils
  {$IFDEF MSWINDOWS}
  , Windows
  {$ENDIF}
  ;

type
  TRtmpTick = UInt64;

function RtmpGetTickCount64: TRtmpTick;
procedure RtmpMaskFloatingPointExceptions;
procedure RtmpSleepMS(AMilliseconds: Cardinal);

implementation

function RtmpGetTickCount64: TRtmpTick;
begin
  {$IFDEF MSWINDOWS}
  Result:=Windows.GetTickCount64;
  {$ELSE}
  Result:=SysUtils.GetTickCount64;
  {$ENDIF}
end;

procedure RtmpMaskFloatingPointExceptions;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
    exOverflow, exUnderflow, exPrecision]);
end;

procedure RtmpSleepMS(AMilliseconds: Cardinal);
begin
  {$IFDEF MSWINDOWS}
  Windows.Sleep(AMilliseconds);
  {$ELSE}
  SysUtils.Sleep(AMilliseconds);
  {$ENDIF}
end;

end.

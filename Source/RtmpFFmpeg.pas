unit RtmpFFmpeg;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  libavutil_error;

function RtmpFFmpegErrorText(AErrorCode: Integer): string;

implementation

function RtmpFFmpegErrorText(AErrorCode: Integer): string;
begin
  if AErrorCode < 0 then
    Result := UTF8Decode(AnsiString(av_err2str(AErrorCode)))
  else
    Result := '';
end;

end.

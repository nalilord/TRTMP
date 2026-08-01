unit TRTMP.RTMP.Log;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  TRTMP.RTMP.Types;

type
  TRtmpLogEvent = procedure(Sender: TObject; ALevel: TRtmpLogLevel;
    const ACategory, AMessage: string) of object;

  TRtmpLogSink = class
  private
    FOnLog: TRtmpLogEvent;
  public
    procedure Log(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    property OnLog: TRtmpLogEvent read FOnLog write FOnLog;
  end;

implementation

procedure TRtmpLogSink.Log(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Sender, ALevel, ACategory, AMessage);
end;

end.

program RtmpPreviewThreadTests;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
uses
  {$IFDEF UNIX}{$IFDEF FPC}cthreads,{$ENDIF}{$ENDIF}
  Classes, SysUtils, TRTMP.RTMP.Preview, TRTMP.RTMP.Types,
  TRTMP.RTMP.Server.Session, TRTMP.RTMP.Media.Packet;
type
  TCallbacks = class
    Count: Integer;
    StopCount: Integer;
    OwnerThread: TThreadID;
    StreamName: string;
    procedure Started(Sender: TObject; const AStream, AAddress: string; APort: Word);
    procedure Stopped(Sender: TObject; const AStream, AAddress: string; APort: Word);
  end;
  TPublisher = class(TThread)
    Preview: TRtmpPreview;
    Session: TRtmpServerSession;
    StopPublish: Boolean;
    procedure Execute; override;
  end;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if NOT ACondition then raise Exception.Create(AMessage);
end;

procedure TCallbacks.Started(Sender: TObject; const AStream, AAddress: string; APort: Word);
begin
  Check(TThread.CurrentThread.ThreadID = OwnerThread, 'Callback on network thread');
  Inc(Count);
  StreamName:=AStream;
end;

procedure TCallbacks.Stopped(Sender: TObject; const AStream, AAddress: string; APort: Word);
begin
  Check(TThread.CurrentThread.ThreadID = OwnerThread, 'Stop callback on network thread');
  Inc(StopCount);
end;

procedure TPublisher.Execute;
var Packet: TRtmpPacket; I: Integer;
begin
  if StopPublish then
  begin
    Preview.Server.OnPublishStopped(Preview.Server, Session);
    Exit;
  end;
  Packet:=TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
    TRtmpSharedPayload.Create(nil), [pfIsVideo], 0);
  try
    for I:=1 to 100 do Preview.Server.DispatchPacket(Session, Packet);
  finally Packet.Free; end;
end;

procedure Publish(APreview: TRtmpPreview; ASession: TRtmpServerSession; AStop: Boolean = False);
var Worker: TPublisher;
begin
  Worker:=TPublisher.Create(True);
  try
    Worker.Preview:=APreview;
    Worker.Session:=ASession;
    Worker.StopPublish:=AStop;
    Worker.Start;
    Worker.WaitFor;
    Check(Worker.FatalException = nil, 'Publisher failed');
  finally Worker.Free; end;
end;

var Preview: TRtmpPreview; Callbacks: TCallbacks;
  SessionA, SessionB: TRtmpServerSession; Config: TRtmpServerConfig;
begin
  Preview:=TRtmpPreview.Create;
  Callbacks:=TCallbacks.Create;
  SessionA:=TRtmpServerSession.Create('127.0.0.1', 30101);
  SessionB:=TRtmpServerSession.Create('127.0.0.1', 30102);
  try
    SessionA.StreamName:='A';
    SessionB.StreamName:='B';
    Callbacks.OwnerThread:=TThread.CurrentThread.ThreadID;
    Preview.OnStreamStarted:=Callbacks.Started;
    Preview.OnStreamStopped:=Callbacks.Stopped;
    Config:=Preview.Server.Config;
    Config.EnableAnalyzer:=False;
    Preview.Server.Config:=Config;
    Preview.SelectStream('A');
    Publish(Preview, SessionA);
    Publish(Preview, SessionB);
    Check(Callbacks.Count = 0, 'Callback delivered before Poll');
    Preview.Poll;
    Check((Callbacks.Count = 1) AND (Callbacks.StreamName = 'A'), 'Exact selection failed');
    // Switching while queued packets exist must discard the previous decoder input.
    Preview.SelectStream('B');
    Publish(Preview, SessionA);
    Publish(Preview, SessionB);
    Check(Callbacks.Count = 1, 'Switch callback delivered before Poll');
    Preview.Poll;
    Check((Callbacks.Count = 2) AND (Callbacks.StreamName = 'B'), 'Switch delivery failed');
    Publish(Preview, SessionB, True);
    Check(Callbacks.StopCount = 0, 'Stop callback delivered before Poll');
    Preview.Poll;
    Check(Callbacks.StopCount = 1, 'Stop callback was not delivered');
    Publish(Preview, SessionB);
    Preview.Stop;
    Preview.Poll;
    Check(Callbacks.Count = 2, 'Stop retained queued callbacks');
  finally
    Preview.Free;
    SessionB.Free;
    SessionA.Free;
    Callbacks.Free;
  end;
  Writeln('RtmpPreviewThreadTests: PASS');
end.

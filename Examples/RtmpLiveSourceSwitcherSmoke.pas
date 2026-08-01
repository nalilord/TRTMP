program RtmpLiveSourceSwitcherSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  {$IFDEF UNIX}
  {$IFDEF FPC}
  cthreads,
  {$ENDIF}
  {$ENDIF}
  SysUtils,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Pipeline.Switcher,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Types;

type
  TLiveSourceSwitcherSmoke = class
  private
    FBuffer: TRtmpCircularBuffer;
    FLastReason: string;
    FSwitchCount: Integer;
    FSwitcher: TRtmpLiveSourceSwitcher;
    procedure AssertTrue(const AMessage: string; AValue: Boolean);
    procedure HandleSourceChanged(Sender: TObject; const APreviousSourceID,
      ANewSourceID, AReason: string);
    procedure NotePacket(const ASourceID: string; AMessageType: TRtmpMessageType;
      ATimestamp: UInt32; ASequenceNo: UInt64; const APayload: TBytes;
      AFlags: TRtmpPacketFlags; AChunkStreamID: UInt32 = 6);
    procedure RunScenario;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result:=nil;
  SetLength(Result, Length(AValues));
  for I:=0 to High(AValues) do
    Result[I]:=AValues[I];
end;

constructor TLiveSourceSwitcherSmoke.Create;
begin
  inherited Create;
  FBuffer:=TRtmpCircularBuffer.Create(128, 1024 * 1024, 5000);
  FSwitcher:=TRtmpLiveSourceSwitcher.Create(FBuffer);
  FSwitcher.IdleTimeoutMS:=40;
  FSwitcher.EvaluationIntervalMS:=10;
  FSwitcher.OnActiveSourceChanged:=HandleSourceChanged;
  FSwitcher.RegisterSource('primary', 10);
  FSwitcher.RegisterSource('fallback', 20);
  FSwitchCount:=0;
  FLastReason:='';
end;

destructor TLiveSourceSwitcherSmoke.Destroy;
begin
  FSwitcher.Free;
  FBuffer.Free;
  inherited Destroy;
end;

procedure TLiveSourceSwitcherSmoke.AssertTrue(const AMessage: string;
  AValue: Boolean);
begin
  if NOT AValue then
    raise Exception.Create(AMessage);
end;

procedure TLiveSourceSwitcherSmoke.HandleSourceChanged(Sender: TObject;
  const APreviousSourceID, ANewSourceID, AReason: string);
begin
  Inc(FSwitchCount);
  FLastReason:=AReason;
end;

procedure TLiveSourceSwitcherSmoke.NotePacket(const ASourceID: string;
  AMessageType: TRtmpMessageType; ATimestamp: UInt32; ASequenceNo: UInt64;
  const APayload: TBytes; AFlags: TRtmpPacketFlags; AChunkStreamID: UInt32);
var
  Packet: TRtmpPacket;
begin
  Packet:=TRtmpPacket.Create(AMessageType, ATimestamp, 0, 1, AChunkStreamID,
    TRtmpSharedPayload.Create(APayload), AFlags, ASequenceNo);
  try
    FSwitcher.NoteSourcePacket(ASourceID, Packet);
  finally
    Packet.Free;
  end;
end;

procedure TLiveSourceSwitcherSmoke.RunScenario;
var
  Packets: TRtmpPacketArray;
  Stats: TRtmpLiveSourceSwitcherStats;
begin
  FSwitcher.NoteSourceStarted('fallback', 'fallback-loop');
  NotePacket('fallback', mtDataAMF0, 0, 1, Bytes([$02]), [pfIsMetadata], 5);
  NotePacket('fallback', mtAudio, 0, 2, Bytes([$AF, $00]), [pfIsAudio, pfIsCodecConfig], 4);
  NotePacket('fallback', mtVideo, 0, 3, Bytes([$17, $00]), [pfIsVideo, pfIsCodecConfig], 6);
  NotePacket('fallback', mtVideo, 0, 4, Bytes([$27, $01]), [pfIsVideo], 6);
  NotePacket('fallback', mtVideo, 40, 5, Bytes([$17, $01]), [pfIsVideo, pfIsKeyframe], 6);
  NotePacket('fallback', mtVideo, 80, 6, Bytes([$27, $01]), [pfIsVideo], 6);

  RtmpSleepMS(20);
  Stats:=FSwitcher.GetStats;
  AssertTrue('expected fallback to become active',
    SameText(Stats.ActiveSourceID, 'fallback'));
  AssertTrue('expected fallback bootstrap packets to be emitted',
    Stats.OutputPackets >= 5);

  FSwitcher.NoteSourceStarted('primary', 'primary-live');
  NotePacket('primary', mtDataAMF0, 0, 1, Bytes([$03]), [pfIsMetadata], 5);
  NotePacket('primary', mtAudio, 0, 2, Bytes([$AF, $00]), [pfIsAudio, pfIsCodecConfig], 4);
  NotePacket('primary', mtVideo, 0, 3, Bytes([$17, $00]), [pfIsVideo, pfIsCodecConfig], 6);
  NotePacket('primary', mtVideo, 20, 4, Bytes([$27, $01]), [pfIsVideo], 6);
  NotePacket('primary', mtVideo, 60, 5, Bytes([$17, $01]), [pfIsVideo, pfIsKeyframe], 6);
  NotePacket('primary', mtVideo, 100, 6, Bytes([$27, $01]), [pfIsVideo], 6);

  RtmpSleepMS(20);
  Stats:=FSwitcher.GetStats;
  AssertTrue('expected primary to preempt fallback',
    SameText(Stats.ActiveSourceID, 'primary'));
  AssertTrue('expected at least two source switches', Stats.SwitchCount >= 2);

  RtmpSleepMS(80);
  NotePacket('fallback', mtDataAMF0, 200, 7, Bytes([$04]), [pfIsMetadata], 5);
  NotePacket('fallback', mtAudio, 200, 8, Bytes([$AF, $00]), [pfIsAudio, pfIsCodecConfig], 4);
  NotePacket('fallback', mtVideo, 200, 9, Bytes([$17, $00]), [pfIsVideo, pfIsCodecConfig], 6);
  NotePacket('fallback', mtVideo, 240, 10, Bytes([$17, $01]), [pfIsVideo, pfIsKeyframe], 6);

  RtmpSleepMS(20);
  Stats:=FSwitcher.GetStats;
  AssertTrue('expected fallback to resume after primary idle timeout',
    SameText(Stats.ActiveSourceID, 'fallback'));
  AssertTrue('expected failover callback after fallback resumed',
    (FLastReason = 'idle-timeout') OR (FLastReason = 'activate'));
  AssertTrue('expected idle timeout counter to advance',
    Stats.IdleTimeoutCount >= 1);

  Packets:=FBuffer.GetSnapshot;
  AssertTrue('expected output buffer to contain forwarded packets',
    Length(Packets) >= 10);
  AssertTrue('expected monotonic output timestamps',
    Packets[High(Packets)].Timestamp >= Packets[High(Packets) - 1].Timestamp);
  AssertTrue('expected final output timestamp to advance across switches',
    Packets[High(Packets)].Timestamp >= 80);
end;

procedure TLiveSourceSwitcherSmoke.Run;
begin
  RunScenario;
  WriteLn('Live source switcher smoke passed.');
end;

var
  Smoke: TLiveSourceSwitcherSmoke;

begin
  Smoke:=TLiveSourceSwitcherSmoke.Create;
  try
    Smoke.Run;
  finally
    Smoke.Free;
  end;
end.

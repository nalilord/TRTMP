program RtmpPipelineSmoke;

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
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Pipeline,
  TRTMP.RTMP.Types;

type
  TPipelineSmoke = class
  private
    FBuffer: TRtmpCircularBuffer;
    FBufferSink: TRtmpBufferSink;
    FStatsNode: TRtmpPacketStatsNode;
    FSwitcherNode: TRtmpLiveSourceSwitcherNode;
    FTeeNode: TRtmpPacketTeeNode;
    procedure AssertTrue(const AMessage: string; AValue: Boolean);
    procedure FeedPacket(const ASourceID: string; AMessageType: TRtmpMessageType;
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

constructor TPipelineSmoke.Create;
begin
  inherited Create;
  FBuffer:=TRtmpCircularBuffer.Create(128, 1024 * 1024, 5000);
  FBufferSink:=TRtmpBufferSink.Create(FBuffer);
  FTeeNode:=TRtmpPacketTeeNode.Create;
  FStatsNode:=TRtmpPacketStatsNode.Create;
  FSwitcherNode:=TRtmpLiveSourceSwitcherNode.Create;

  FSwitcherNode.Switcher.RegisterSource('primary', 10);
  FSwitcherNode.Switcher.RegisterSource('backup', 20);
  FSwitcherNode.Switcher.IdleTimeoutMS:=40;
  FSwitcherNode.Switcher.EvaluationIntervalMS:=10;

  FSwitcherNode.AddSink(FStatsNode);
  FStatsNode.AddSink(FTeeNode);
  FTeeNode.AddSink(FBufferSink);
end;

destructor TPipelineSmoke.Destroy;
begin
  FSwitcherNode.Free;
  FStatsNode.Free;
  FTeeNode.Free;
  FBufferSink.Free;
  FBuffer.Free;
  inherited Destroy;
end;

procedure TPipelineSmoke.AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if NOT AValue then
    raise Exception.Create(AMessage);
end;

procedure TPipelineSmoke.FeedPacket(const ASourceID: string;
  AMessageType: TRtmpMessageType; ATimestamp: UInt32; ASequenceNo: UInt64;
  const APayload: TBytes; AFlags: TRtmpPacketFlags; AChunkStreamID: UInt32);
var
  Packet: TRtmpPacket;
begin
  Packet:=TRtmpPacket.Create(AMessageType, ATimestamp, 0, 1, AChunkStreamID,
    TRtmpSharedPayload.Create(APayload), AFlags, ASequenceNo);
  try
    FSwitcherNode.HandlePacket(ASourceID, Packet);
  finally
    Packet.Free;
  end;
end;

procedure TPipelineSmoke.RunScenario;
var
  OutputPackets: TRtmpPacketArray;
  Stats: TRtmpPipelineStats;
begin
  FSwitcherNode.HandleStreamStarted('backup', 'backup-loop');
  FeedPacket('backup', mtDataAMF0, 0, 1, Bytes([$02]), [pfIsMetadata], 5);
  FeedPacket('backup', mtAudio, 0, 2, Bytes([$AF, $00]), [pfIsAudio, pfIsCodecConfig], 4);
  FeedPacket('backup', mtVideo, 0, 3, Bytes([$17, $00]), [pfIsVideo, pfIsCodecConfig], 6);
  FeedPacket('backup', mtVideo, 40, 4, Bytes([$17, $01]), [pfIsVideo, pfIsKeyframe], 6);
  FeedPacket('backup', mtVideo, 80, 5, Bytes([$27, $01]), [pfIsVideo], 6);

  FSwitcherNode.HandleStreamStarted('primary', 'primary-live');
  FeedPacket('primary', mtDataAMF0, 0, 1, Bytes([$03]), [pfIsMetadata], 5);
  FeedPacket('primary', mtAudio, 0, 2, Bytes([$AF, $00]), [pfIsAudio, pfIsCodecConfig], 4);
  FeedPacket('primary', mtVideo, 0, 3, Bytes([$17, $00]), [pfIsVideo, pfIsCodecConfig], 6);
  FeedPacket('primary', mtVideo, 20, 4, Bytes([$27, $01]), [pfIsVideo], 6);
  FeedPacket('primary', mtVideo, 60, 5, Bytes([$17, $01]), [pfIsVideo, pfIsKeyframe], 6);

  Sleep(80);
  FeedPacket('backup', mtDataAMF0, 200, 6, Bytes([$04]), [pfIsMetadata], 5);
  FeedPacket('backup', mtAudio, 200, 7, Bytes([$AF, $00]), [pfIsAudio, pfIsCodecConfig], 4);
  FeedPacket('backup', mtVideo, 200, 8, Bytes([$17, $00]), [pfIsVideo, pfIsCodecConfig], 6);
  FeedPacket('backup', mtVideo, 240, 9, Bytes([$17, $01]), [pfIsVideo, pfIsKeyframe], 6);

  Stats:=FStatsNode.GetStats;
  OutputPackets:=FBuffer.GetSnapshot;

  AssertTrue('expected pipeline to count stream starts', Stats.StreamStarts >= 3);
  AssertTrue('expected pipeline to count at least one stop', Stats.StreamStops >= 1);
  AssertTrue('expected pipeline packet count to advance', Stats.Packets >= 8);
  AssertTrue('expected output buffer packets', Length(OutputPackets) >= 8);
  AssertTrue('expected final source to be backup',
    SameText(FSwitcherNode.Switcher.ActiveSourceID, 'backup'));
  AssertTrue('expected monotonic output timestamps',
    OutputPackets[High(OutputPackets)].Timestamp >=
      OutputPackets[High(OutputPackets) - 1].Timestamp);
end;

procedure TPipelineSmoke.Run;
begin
  RunScenario;
  WriteLn('Pipeline smoke passed.');
end;

var
  Smoke: TPipelineSmoke;

begin
  Smoke:=TPipelineSmoke.Create;
  try
    Smoke.Run;
  finally
    Smoke.Free;
  end;
end.

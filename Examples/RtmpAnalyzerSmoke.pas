program RtmpAnalyzerSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  RtmpAnalyzer,
  RtmpPacket,
  RtmpTypes;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

procedure AssertTrue(const AMessage: string; ACondition: Boolean);
begin
  if not ACondition then
    raise Exception.Create(AMessage);
end;

procedure AssertNear(const AMessage: string; AExpected, AActual,
  ATolerance: Double);
begin
  if Abs(AExpected - AActual) > ATolerance then
    raise Exception.CreateFmt('%s expected %.3f got %.3f',
      [AMessage, AExpected, AActual]);
end;

function Packet(AMessageType: TRtmpMessageType; ATimestamp: UInt32;
  const APayloadBytes: array of Byte; AFlags: TRtmpPacketFlags;
  AArrivalTick: UInt64; ASequenceNo: UInt64): TRtmpPacket;
begin
  Result := TRtmpPacket.Create(AMessageType, ATimestamp, 0, 1, 6,
    TRtmpSharedPayload.Create(Bytes(APayloadBytes)), AFlags, ASequenceNo,
    AArrivalTick);
end;

procedure FeedPacket(AAnalyzer: TRtmpAnalyzer; AMessageType: TRtmpMessageType;
  ATimestamp: UInt32; const APayloadBytes: array of Byte; AFlags: TRtmpPacketFlags;
  AArrivalTick: UInt64; ASequenceNo: UInt64);
var
  APacket: TRtmpPacket;
begin
  APacket := Packet(AMessageType, ATimestamp, APayloadBytes, AFlags,
    AArrivalTick, ASequenceNo);
  try
    AAnalyzer.Feed(APacket);
  finally
    APacket.Free;
  end;
end;

var
  Analyzer: TRtmpAnalyzer;
  Snapshot: TRtmpAnalysisSnapshot;
begin
  Analyzer := TRtmpAnalyzer.Create;
  try
    FeedPacket(Analyzer, mtAudio, 0, [$AE, $00, $11, $88, $56, $E5, $00],
      [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], 0, 0);
    FeedPacket(Analyzer, mtVideo, 0, [
      $17, $00, $00, $00, $00,
      $01, $42, $C0, $0B, $FF, $E1, $00, $17,
      $67, $42, $C0, $0B, $DA, $05, $07, $EC,
      $04, $40, $00, $00, $03, $00, $40, $00,
      $00, $03, $00, $A3, $C5, $0A, $A8, $01,
      $00, $04, $68, $CE, $0F, $C8
    ], [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], 0, 1);

    FeedPacket(Analyzer, mtAudio, 0, [$AE, $01, $12, $10], [pfIsAudio], 1000, 2);
    FeedPacket(Analyzer, mtVideo, 0, [$17, $01, $00, $00, $00, $11, $12, $13],
      [pfIsVideo, pfIsKeyframe], 1000, 3);
    FeedPacket(Analyzer, mtAudio, 40, [$AF, $01, $14, $15], [pfIsAudio], 1040, 4);
    FeedPacket(Analyzer, mtVideo, 40, [$27, $01, $00, $00, $00, $16, $17, $18],
      [pfIsVideo], 1045, 5);
    FeedPacket(Analyzer, mtAudio, 80, [$AF, $01, $19, $1A], [pfIsAudio], 1080, 6);
    FeedPacket(Analyzer, mtVideo, 80, [$27, $01, $00, $00, $00, $1B, $1C, $1D],
      [pfIsVideo], 1090, 7);
    FeedPacket(Analyzer, mtAudio, 120, [$AF, $01, $1E, $1F], [pfIsAudio], 1120, 8);
    FeedPacket(Analyzer, mtVideo, 120, [$17, $01, $00, $00, $00, $20, $21, $22],
      [pfIsVideo, pfIsKeyframe], 1135, 9);

    Snapshot := Analyzer.GetSnapshot;

    AssertTrue('analyzer smoke failed: expected AAC codec',
      Snapshot.AudioCodec = 'AAC');
    AssertTrue('analyzer smoke failed: expected AVC codec',
      Snapshot.VideoCodec = 'AVC');
    AssertTrue('analyzer smoke failed: expected sample rate 48000 from AAC config',
      Snapshot.AudioSampleRate = 48000);
    AssertTrue('analyzer smoke failed: expected mono audio from AAC config',
      Snapshot.AudioChannels = 1);
    AssertTrue('analyzer smoke failed: expected width 320 from AVC config',
      Snapshot.VideoWidth = 320);
    AssertTrue('analyzer smoke failed: expected height 240 from AVC config',
      Snapshot.VideoHeight = 240);
    AssertTrue('analyzer smoke failed: expected keyframe interval 120',
      Snapshot.KeyframeIntervalMS = 120);
    AssertTrue('analyzer smoke failed: expected drift 0',
      Snapshot.DriftMS = 0);
    AssertTrue('analyzer smoke failed: expected average jitter 5ms',
      Snapshot.JitterMS = 5);
    AssertNear('analyzer smoke failed: expected 25 fps', 25.0,
      Snapshot.VideoFPS, 0.2);

    WriteLn(Format(
      'Analyzer smoke passed: videoCodec=%s %dx%d audioCodec=%s %dHz ch=%d fps=%.2f jitter=%d drift=%d keyInt=%d',
      [Snapshot.VideoCodec, Snapshot.VideoWidth, Snapshot.VideoHeight,
       Snapshot.AudioCodec, Snapshot.AudioSampleRate, Snapshot.AudioChannels,
       Snapshot.VideoFPS, Snapshot.JitterMS, Snapshot.DriftMS,
       Snapshot.KeyframeIntervalMS]));
  finally
    Analyzer.Free;
  end;
end.

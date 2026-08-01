program RtmpAnalyzerEnhancedSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  TRTMP.RTMP.Media.Analyzer,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Types;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result:=nil;
  SetLength(Result, Length(AValues));
  for I:=0 to High(AValues) do
    Result[I]:=AValues[I];
end;

procedure AssertCodec(const AName, AExpected: string;
  AMessageType: TRtmpMessageType; const APayload: array of Byte;
  AFlags: TRtmpPacketFlags);
var
  Analyzer: TRtmpAnalyzer;
  Packet: TRtmpPacket;
  Snapshot: TRtmpAnalysisSnapshot;
begin
  Analyzer:=TRtmpAnalyzer.Create;
  Packet:=TRtmpPacket.Create(AMessageType, 0, 0, 1, 6,
    TRtmpSharedPayload.Create(Bytes(APayload)), AFlags, 1, 1);
  try
    Analyzer.Feed(Packet);
    Snapshot:=Analyzer.GetSnapshot;
    if AMessageType = mtVideo then
    begin
      if Snapshot.VideoCodec <> AExpected then
        raise Exception.CreateFmt('%s: expected %s, got %s',
          [AName, AExpected, Snapshot.VideoCodec]);
    end
    else if Snapshot.AudioCodec <> AExpected then
      raise Exception.CreateFmt('%s: expected %s, got %s',
        [AName, AExpected, Snapshot.AudioCodec]);
  finally
    Packet.Free;
    Analyzer.Free;
  end;
end;

procedure TestEnhancedWrappers;
var
  Analyzer: TRtmpAnalyzer;
  Packet: TRtmpPacket;
  Snapshot: TRtmpAnalysisSnapshot;
begin
  Analyzer:=TRtmpAnalyzer.Create;
  try
    Packet:=TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
      TRtmpSharedPayload.Create(Bytes([
        $96, $10, Ord('h'), Ord('v'), Ord('c'), Ord('1'),
        $00, $00, $00, $01, $AA,
        $01, $00, $00, $01, $BB])),
      [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], 1, 1);
    try
      Analyzer.Feed(Packet);
    finally
      Packet.Free;
    end;

    Packet:=TRtmpPacket.Create(mtAudio, 0, 0, 1, 6,
      TRtmpSharedPayload.Create(Bytes([
        $97, $02, $00, $00, $05, $05,
        $01, Ord('O'), Ord('p'), Ord('u'), Ord('s'), $00, $AA])),
      [pfIsAudio], 2, 2);
    try
      Analyzer.Feed(Packet);
    finally
      Packet.Free;
    end;

    Snapshot:=Analyzer.GetSnapshot;
    if (Snapshot.VideoCodec <> 'HEVC') OR
      (Snapshot.VideoTrackCount <> 2) OR
      (Snapshot.VideoMultitrackPackets <> 1) then
      raise Exception.Create('video multitrack analyzer metrics mismatch');
    if (Snapshot.AudioCodec <> 'Opus') OR
      (Snapshot.AudioTrackCount <> 1) OR
      (Snapshot.AudioMultitrackPackets <> 1) OR
      (Snapshot.AudioModExPackets <> 1) OR
      (Snapshot.AudioTimestampNanoOffset <> 5) then
      raise Exception.Create('audio ModEx/multitrack analyzer metrics mismatch');
  finally
    Analyzer.Free;
  end;
end;

begin
  AssertCodec('HEVC', 'HEVC', mtVideo,
    [$90, Ord('h'), Ord('v'), Ord('c'), Ord('1')],
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe]);
  AssertCodec('AV1', 'AV1', mtVideo,
    [$90, Ord('a'), Ord('v'), Ord('0'), Ord('1')],
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe]);
  AssertCodec('VP9', 'VP9', mtVideo,
    [$90, Ord('v'), Ord('p'), Ord('0'), Ord('9')],
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe]);
  AssertCodec('VP8', 'VP8', mtVideo,
    [$90, Ord('v'), Ord('p'), Ord('0'), Ord('8')],
    [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe]);
  AssertCodec('Opus', 'Opus', mtAudio,
    [$90, Ord('O'), Ord('p'), Ord('u'), Ord('s')],
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader]);
  AssertCodec('FLAC', 'FLAC', mtAudio,
    [$90, Ord('f'), Ord('L'), Ord('a'), Ord('C')],
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader]);
  AssertCodec('AC-3', 'AC-3', mtAudio,
    [$90, Ord('a'), Ord('c'), Ord('-'), Ord('3')],
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader]);
  AssertCodec('E-AC-3', 'E-AC-3', mtAudio,
    [$90, Ord('e'), Ord('c'), Ord('-'), Ord('3')],
    [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader]);
  TestEnhancedWrappers;
  WriteLn('Enhanced analyzer smoke passed: codecs, multitrack, and ModEx metrics');
end.

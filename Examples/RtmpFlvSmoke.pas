program RtmpFlvSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  TRTMP.RTMP.Protocol.FLV,
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

procedure AssertTrue(const AMessage: string; ACondition: Boolean);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure TestEnhancedVideo;
var
  Flags: TRtmpPacketFlags;
  Info: TRtmpFlvTagInfo;
begin
  AssertTrue('enhanced video sequence start was rejected',
    RtmpInspectFlvTag(mtVideo,
      Bytes([$90, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $01, $02]), Info));
  AssertTrue('enhanced video flag missing', Info.IsEnhanced);
  AssertTrue('enhanced video FourCC mismatch', Info.CodecFourCC = 'hvc1');
  AssertTrue('enhanced video packet type mismatch', Info.VideoPacketType = 0);
  AssertTrue('enhanced sequence start was not classified as config',
    Info.IsCodecConfig AND Info.IsSequenceHeader);
  AssertTrue('enhanced sequence start keyframe missing', Info.IsKeyframe);
  Flags:=RtmpPacketFlagsFromFlvTag(mtVideo, Info, False);
  AssertTrue('enhanced video config packet flags incomplete',
    (pfIsVideo IN Flags) AND (pfIsCodecConfig IN Flags) AND
    (pfIsSequenceHeader IN Flags) AND (pfIsKeyframe IN Flags));

  AssertTrue('enhanced coded frame was rejected',
    RtmpInspectFlvTag(mtVideo,
      Bytes([$91, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $FF, $FF, $FE, $42]),
      Info));
  AssertTrue('enhanced coded-frame FourCC mismatch', Info.CodecFourCC = 'hvc1');
  AssertTrue('negative composition offset was not sign extended',
    Info.CompositionTimeOffset = -2);
  AssertTrue('HEVC payload slice mismatch',
    (Info.PayloadOffset = 8) AND (Info.PayloadSize = 1));

  AssertTrue('short AV1 coded frame was rejected',
    RtmpInspectFlvTag(mtVideo,
      Bytes([$91, Ord('a'), Ord('v'), Ord('0'), Ord('1'), $42]), Info));
  AssertTrue('AV1 coded-frame FourCC mismatch', Info.CodecFourCC = 'av01');
  AssertTrue('AV1 coded frame received a false composition offset',
    Info.CompositionTimeOffset = 0);
  AssertTrue('AV1 payload slice mismatch',
    (Info.PayloadOffset = 5) AND (Info.PayloadSize = 1));

  AssertTrue('enhanced inter frame was rejected',
    RtmpInspectFlvTag(mtVideo,
      Bytes([$A3, Ord('v'), Ord('p'), Ord('0'), Ord('9'), $42]), Info));
  AssertTrue('enhanced inter frame incorrectly marked keyframe', NOT Info.IsKeyframe);
  AssertTrue('coded-frames-X offset must be implicit zero',
    Info.CompositionTimeOffset = 0);

  AssertTrue('enhanced metadata packet was rejected',
    RtmpInspectFlvTag(mtVideo,
      Bytes([$94, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $42]), Info));
  AssertTrue('enhanced metadata incorrectly marked keyframe', NOT Info.IsKeyframe);
end;

procedure TestEnhancedAudio;
var
  Flags: TRtmpPacketFlags;
  Info: TRtmpFlvTagInfo;
begin
  AssertTrue('enhanced audio sequence start was rejected',
    RtmpInspectFlvTag(mtAudio,
      Bytes([$90, Ord('O'), Ord('p'), Ord('u'), Ord('s'), $01, $02]), Info));
  AssertTrue('enhanced audio flag missing', Info.IsEnhanced);
  AssertTrue('enhanced audio FourCC mismatch', Info.CodecFourCC = 'Opus');
  AssertTrue('enhanced audio packet type mismatch', Info.AudioPacketType = 0);
  AssertTrue('enhanced audio sequence start was not classified as config',
    Info.IsCodecConfig AND Info.IsSequenceHeader);
  Flags:=RtmpPacketFlagsFromFlvTag(mtAudio, Info, False);
  AssertTrue('enhanced audio config packet flags incomplete',
    (pfIsAudio IN Flags) AND (pfIsCodecConfig IN Flags) AND
    (pfIsSequenceHeader IN Flags));

  AssertTrue('enhanced FLAC frame was rejected',
    RtmpInspectFlvTag(mtAudio,
      Bytes([$91, Ord('f'), Ord('L'), Ord('a'), Ord('C'), $42]), Info));
  AssertTrue('enhanced FLAC FourCC mismatch', Info.CodecFourCC = 'fLaC');
  AssertTrue('enhanced FLAC frame incorrectly marked config', NOT Info.IsCodecConfig);
  AssertTrue('enhanced FLAC payload slice mismatch',
    (Info.PayloadOffset = 5) AND (Info.PayloadSize = 1));
end;

procedure TestEnhancedMultitrack;
var
  Info: TRtmpFlvTagInfo;
begin
  AssertTrue('same-codec video multitrack was rejected',
    RtmpInspectFlvTag(mtVideo, Bytes([
      $96, $10, Ord('h'), Ord('v'), Ord('c'), Ord('1'),
      $00, $00, $00, $02, $AA, $BB,
      $01, $00, $00, $01, $CC]), Info));
  AssertTrue('video multitrack classification missing',
    Info.IsMultitrack AND (Info.MultitrackType = 1));
  AssertTrue('video multitrack packet type mismatch', Info.VideoPacketType = 0);
  AssertTrue('video multitrack config flags missing',
    Info.IsCodecConfig AND Info.IsSequenceHeader AND Info.IsKeyframe);
  AssertTrue('video multitrack shared FourCC mismatch',
    Info.CodecFourCC = 'hvc1');
  AssertTrue('video multitrack count mismatch', Info.TrackCount = 2);
  AssertTrue('video track zero slice mismatch',
    (Info.Tracks[0].TrackID = 0) AND
    (Info.Tracks[0].CodecFourCC = 'hvc1') AND
    (Info.Tracks[0].DataOffset = 10) AND
    (Info.Tracks[0].DataSize = 2));
  AssertTrue('video track one slice mismatch',
    (Info.Tracks[1].TrackID = 1) AND
    (Info.Tracks[1].DataOffset = 16) AND
    (Info.Tracks[1].DataSize = 1));
  AssertTrue('default video track payload offset mismatch',
    (Info.PayloadOffset = 10) AND (Info.PayloadSize = 2));

  AssertTrue('mixed-codec video multitrack was rejected',
    RtmpInspectFlvTag(mtVideo, Bytes([
      $96, $21,
      Ord('a'), Ord('v'), Ord('0'), Ord('1'), $00, $00, $00, $02, $12, $34,
      Ord('v'), Ord('p'), Ord('0'), Ord('9'), $01, $00, $00, $01, $56]),
      Info));
  AssertTrue('mixed-codec video track count mismatch', Info.TrackCount = 2);
  AssertTrue('mixed-codec default FourCC mismatch', Info.CodecFourCC = 'av01');
  AssertTrue('mixed-codec second FourCC mismatch',
    Info.Tracks[1].CodecFourCC = 'vp09');

  AssertTrue('one-track enhanced audio wrapper was rejected',
    RtmpInspectFlvTag(mtAudio, Bytes([
      $95, $01, Ord('O'), Ord('p'), Ord('u'), Ord('s'), $00, $AA, $BB]),
      Info));
  AssertTrue('one-track audio wrapper classification mismatch',
    Info.IsMultitrack AND (Info.MultitrackType = 0) AND
    (Info.AudioPacketType = 1) AND (Info.TrackCount = 1));
  AssertTrue('one-track audio slice mismatch',
    (Info.Tracks[0].TrackID = 0) AND
    (Info.Tracks[0].PayloadOffset = 7) AND
    (Info.Tracks[0].PayloadSize = 2));
end;

procedure TestEnhancedModEx;
var
  Info: TRtmpFlvTagInfo;
begin
  AssertTrue('video timestamp ModEx was rejected',
    RtmpInspectFlvTag(mtVideo, Bytes([
      $97, $02, $00, $01, $E2, $01,
      Ord('h'), Ord('v'), Ord('c'), Ord('1'), $FF, $FF, $FE, $AA]), Info));
  AssertTrue('video ModEx classification mismatch',
    Info.IsModEx AND (Info.ModExCount = 1));
  AssertTrue('video timestamp nano offset mismatch',
    Info.HasTimestampNanoOffset AND (Info.TimestampNanoOffset = 482));
  AssertTrue('video ModEx did not resolve packet type', Info.VideoPacketType = 1);
  AssertTrue('video ModEx composition offset mismatch',
    Info.CompositionTimeOffset = -2);
  AssertTrue('video ModEx payload offset mismatch', Info.PayloadOffset = 13);
  AssertTrue('video ModEx payload size mismatch', Info.PayloadSize = 1);

  AssertTrue('audio ModEx plus multitrack was rejected',
    RtmpInspectFlvTag(mtAudio, Bytes([
      $97, $02, $00, $00, $05, $05,
      $01, Ord('O'), Ord('p'), Ord('u'), Ord('s'), $00, $AA]), Info));
  AssertTrue('audio ModEx multitrack classification mismatch',
    Info.IsModEx AND Info.IsMultitrack AND
    (Info.TimestampNanoOffset = 5) AND (Info.AudioPacketType = 1));
  AssertTrue('audio ModEx track payload mismatch',
    (Info.TrackCount = 1) AND (Info.Tracks[0].PayloadOffset = 12) AND
    (Info.Tracks[0].PayloadSize = 1));
end;

procedure TestMalformedEnhancedHeaders;
var
  Info: TRtmpFlvTagInfo;
begin
  AssertTrue('truncated enhanced video header was accepted',
    NOT RtmpInspectFlvTag(mtVideo, Bytes([$90, Ord('h')]), Info));
  AssertTrue('truncated enhanced audio header was accepted',
    NOT RtmpInspectFlvTag(mtAudio, Bytes([$90, Ord('O')]), Info));
  AssertTrue('truncated enhanced coded-frame offset was accepted',
    NOT RtmpInspectFlvTag(mtVideo,
      Bytes([$91, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00]), Info));
  AssertTrue('reserved enhanced audio packet type was accepted',
    NOT RtmpInspectFlvTag(mtAudio,
      Bytes([$93, Ord('O'), Ord('p'), Ord('u'), Ord('s')]), Info));
  AssertTrue('unsupported enhanced video multitrack header was accepted',
    NOT RtmpInspectFlvTag(mtVideo,
      Bytes([$96, $10, Ord('h'), Ord('v'), Ord('c'), Ord('1')]), Info));
  AssertTrue('video multitrack header lost enhanced classification', Info.IsEnhanced);
  AssertTrue('video multitrack header was assigned a false FourCC',
    Info.CodecFourCC = '');
  AssertTrue('unsupported enhanced audio ModEx header was accepted',
    NOT RtmpInspectFlvTag(mtAudio,
      Bytes([$97, $00, Ord('O'), Ord('p'), Ord('u'), Ord('s')]), Info));
  AssertTrue('audio ModEx header lost enhanced classification', Info.IsEnhanced);
  AssertTrue('truncated ModEx timestamp was accepted',
    NOT RtmpInspectFlvTag(mtVideo,
      Bytes([$97, $01, $00, $00, $01,
        Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00]), Info));
  AssertTrue('out-of-range ModEx timestamp was accepted',
    NOT RtmpInspectFlvTag(mtVideo,
      Bytes([$97, $02, $0F, $42, $40, $01,
        Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00, $00, $00]), Info));
  AssertTrue('reserved multitrack type was accepted',
    NOT RtmpInspectFlvTag(mtVideo,
      Bytes([$96, $30, Ord('h'), Ord('v'), Ord('c'), Ord('1'), $00]), Info));
  AssertTrue('duplicate multitrack ID was accepted',
    NOT RtmpInspectFlvTag(mtAudio, Bytes([
      $95, $11, Ord('O'), Ord('p'), Ord('u'), Ord('s'),
      $00, $00, $00, $01, $AA,
      $00, $00, $00, $01, $BB]), Info));
  AssertTrue('oversized multitrack slice was accepted',
    NOT RtmpInspectFlvTag(mtVideo, Bytes([
      $96, $11, Ord('v'), Ord('p'), Ord('0'), Ord('9'),
      $00, $00, $01, $00, $AA]), Info));
end;

begin
  TestEnhancedVideo;
  TestEnhancedAudio;
  TestEnhancedMultitrack;
  TestEnhancedModEx;
  TestMalformedEnhancedHeaders;
  WriteLn('FLV smoke passed: enhanced single-track, multitrack, ModEx, and malformed guards');
end.

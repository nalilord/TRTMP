program RtmpBufferSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  TRTMP.RTMP.Media.Buffer,
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

function BytesEqual(const ALeft, ARight: TBytes): Boolean;
var
  I: Integer;
begin
  Result:=Length(ALeft) = Length(ARight);
  if NOT Result then
    Exit;
  for I:=0 to High(ALeft) do
    if ALeft[I] <> ARight[I] then
      Exit(False);
end;

procedure AssertEqualUInt64(const AMessage: string; AExpected, AActual: UInt64);
begin
  if AExpected <> AActual then
    raise Exception.CreateFmt('%s expected=%d actual=%d', [AMessage, AExpected, AActual]);
end;

procedure AssertEqualInt(const AMessage: string; AExpected, AActual: Integer);
begin
  if AExpected <> AActual then
    raise Exception.CreateFmt('%s expected=%d actual=%d', [AMessage, AExpected, AActual]);
end;

procedure AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if NOT AValue then
    raise Exception.Create(AMessage);
end;

procedure FreePacketArray(var APackets: TRtmpPacketArray);
var
  I: Integer;
begin
  for I:=0 to High(APackets) do
    APackets[I].Free;
  APackets:=nil;
end;

function MakePacket(AMessageType: TRtmpMessageType; ASequenceNo: UInt64;
  ATimestamp: UInt32; const AFlags: TRtmpPacketFlags;
  const APayload: array of Byte): TRtmpPacket;
begin
  Result:=TRtmpPacket.Create(AMessageType, ATimestamp, 0, 1, 6,
    TRtmpSharedPayload.Create(Bytes(APayload)), AFlags, ASequenceNo);
end;

procedure TestPacketLimitEviction;
var
  Buffer: TRtmpCircularBuffer;
  Packets: TRtmpPacketArray;
  Stats: TRtmpBufferStats;
begin
  Buffer:=TRtmpCircularBuffer.Create(2, 0);
  try
    Buffer.Push(MakePacket(mtVideo, 0, 0, [pfIsVideo], [$11]));
    Buffer.Push(MakePacket(mtVideo, 1, 40, [pfIsVideo], [$12]));
    Buffer.Push(MakePacket(mtVideo, 2, 80, [pfIsVideo], [$13]));

    Stats:=Buffer.GetStats;
    AssertEqualInt('packet-limit count', 2, Stats.PacketCount);
    AssertEqualUInt64('packet-limit evicted', 1, Stats.EvictedPackets);
    AssertEqualUInt64('packet-limit reason count', 1, Stats.EvictedByPacketLimit);
    AssertEqualUInt64('packet-limit trim events', 1, Stats.TrimEventsByPackets);

    Packets:=Buffer.GetSinceSequenceSnapshot(0);
    try
      AssertEqualInt('packet-limit snapshot count', 2, Length(Packets));
      AssertEqualUInt64('packet-limit first sequence', 1, Packets[0].SequenceNo);
      AssertEqualUInt64('packet-limit second sequence', 2, Packets[1].SequenceNo);
    finally
      FreePacketArray(Packets);
    end;
  finally
    Buffer.Free;
  end;
end;

procedure TestByteLimitEviction;
var
  Buffer: TRtmpCircularBuffer;
  Stats: TRtmpBufferStats;
begin
  Buffer:=TRtmpCircularBuffer.Create(0, 6);
  try
    Buffer.Push(MakePacket(mtVideo, 0, 0, [pfIsVideo], [$11, $22, $33]));
    Buffer.Push(MakePacket(mtVideo, 1, 40, [pfIsVideo], [$44, $55, $66]));
    Buffer.Push(MakePacket(mtVideo, 2, 80, [pfIsVideo], [$77, $88, $99]));

    Stats:=Buffer.GetStats;
    AssertEqualInt('byte-limit count', 2, Stats.PacketCount);
    AssertEqualUInt64('byte-limit bytes', 6, Stats.ByteCount);
    AssertEqualUInt64('byte-limit evicted', 1, Stats.EvictedPackets);
    AssertEqualUInt64('byte-limit reason count', 1, Stats.EvictedByByteLimit);
    AssertEqualUInt64('byte-limit trim events', 1, Stats.TrimEventsByBytes);
  finally
    Buffer.Free;
  end;
end;

procedure TestBootstrapRetention;
var
  BootstrapSequenceNo: UInt64;
  Buffer: TRtmpCircularBuffer;
  Headers: TRtmpPacketArray;
  Packets: TRtmpPacketArray;
  Stats: TRtmpBufferStats;
begin
  Buffer:=TRtmpCircularBuffer.Create(1, 0);
  try
    Buffer.Push(MakePacket(mtDataAMF0, 10, 0, [pfIsMetadata], [$02, $00]));
    Buffer.Push(MakePacket(mtAudio, 11, 0,
      [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader], [$AF, $00]));
    Buffer.Push(MakePacket(mtVideo, 12, 0,
      [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], [$17, $00]));
    Buffer.Push(MakePacket(mtVideo, 13, 40, [pfIsVideo, pfIsKeyframe], [$17, $01]));
    Buffer.Push(MakePacket(mtVideo, 14, 80, [pfIsVideo], [$27, $01]));

    Stats:=Buffer.GetStats;
    AssertEqualInt('bootstrap ring count', 1, Stats.PacketCount);
    AssertTrue('bootstrap metadata retained', Stats.HasMetadata);
    AssertTrue('bootstrap audio config retained', Stats.HasAudioConfig);
    AssertTrue('bootstrap video config retained', Stats.HasVideoConfig);
    AssertTrue('bootstrap keyframe retained', Stats.HasKeyframe);
    AssertEqualInt('bootstrap retained packet count', 4, Stats.RetainedPackets);

    Headers:=Buffer.GetCodecHeadersSnapshot;
    try
      AssertEqualInt('bootstrap header count', 3, Length(Headers));
      AssertEqualUInt64('bootstrap header metadata sequence', 10, Headers[0].SequenceNo);
      AssertEqualUInt64('bootstrap header audio sequence', 11, Headers[1].SequenceNo);
      AssertEqualUInt64('bootstrap header video sequence', 12, Headers[2].SequenceNo);
    finally
      FreePacketArray(Headers);
    end;

    BootstrapSequenceNo:=Buffer.GetBootstrapSequenceNo(999);
    AssertEqualUInt64('bootstrap sequence', 13, BootstrapSequenceNo);

    Packets:=Buffer.GetSinceSequenceSnapshot(BootstrapSequenceNo);
    try
      AssertEqualInt('bootstrap replay count', 2, Length(Packets));
      AssertEqualUInt64('bootstrap replay keyframe sequence', 13, Packets[0].SequenceNo);
      AssertEqualUInt64('bootstrap replay latest sequence', 14, Packets[1].SequenceNo);
    finally
      FreePacketArray(Packets);
    end;
  finally
    Buffer.Free;
  end;
end;

procedure TestDurationLimitEviction;
var
  Buffer: TRtmpCircularBuffer;
  Packets: TRtmpPacketArray;
  Stats: TRtmpBufferStats;
begin
  Buffer:=TRtmpCircularBuffer.Create(0, 0, 80);
  try
    Buffer.Push(MakePacket(mtVideo, 0, 0, [pfIsVideo, pfIsKeyframe], [$11]));
    Buffer.Push(MakePacket(mtVideo, 1, 40, [pfIsVideo], [$12]));
    Buffer.Push(MakePacket(mtVideo, 2, 120, [pfIsVideo], [$13]));

    Stats:=Buffer.GetStats;
    AssertEqualInt('duration-limit count', 2, Stats.PacketCount);
    AssertEqualUInt64('duration-limit evicted', 1, Stats.EvictedPackets);
    AssertEqualUInt64('duration-limit reason count', 1, Stats.EvictedByAgeLimit);
    AssertEqualUInt64('duration-limit trim events', 1, Stats.TrimEventsByAge);
    AssertEqualUInt64('duration-limit window', 80, Stats.WindowDurationMS);

    Packets:=Buffer.GetSinceSequenceSnapshot(0);
    try
      AssertEqualInt('duration-limit snapshot count', 3, Length(Packets));
      AssertEqualUInt64('duration-limit retained keyframe sequence', 0, Packets[0].SequenceNo);
      AssertEqualUInt64('duration-limit first ring sequence', 1, Packets[1].SequenceNo);
      AssertEqualUInt64('duration-limit second ring sequence', 2, Packets[2].SequenceNo);
    finally
      FreePacketArray(Packets);
    end;
  finally
    Buffer.Free;
  end;
end;

procedure TestEnhancedWrapperRetention;
var
  Buffer: TRtmpCircularBuffer;
  ExpectedConfig: TBytes;
  ExpectedModEx: TBytes;
  Headers: TRtmpPacketArray;
  Packets: TRtmpPacketArray;
begin
  ExpectedConfig:=Bytes([
    $96, $10, Ord('h'), Ord('v'), Ord('c'), Ord('1'),
    $00, $00, $00, $01, $AA,
    $01, $00, $00, $01, $BB]);
  ExpectedModEx:=Bytes([
    $97, $02, $00, $00, $05, $01,
    Ord('O'), Ord('p'), Ord('u'), Ord('s'), $AA]);
  Buffer:=TRtmpCircularBuffer.Create(1, 0);
  try
    Buffer.Push(TRtmpPacket.Create(mtVideo, 0, 0, 1, 6,
      TRtmpSharedPayload.Create(ExpectedConfig),
      [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe], 10));
    Buffer.Push(TRtmpPacket.Create(mtAudio, 20, 20, 1, 4,
      TRtmpSharedPayload.Create(ExpectedModEx), [pfIsAudio], 11));

    Headers:=Buffer.GetCodecHeadersSnapshot;
    try
      AssertEqualInt('enhanced wrapper header count', 1, Length(Headers));
      AssertTrue('multitrack config was not retained byte-exactly',
        BytesEqual(Headers[0].Payload.Bytes, ExpectedConfig));
    finally
      FreePacketArray(Headers);
    end;

    Packets:=Buffer.GetSinceSequenceSnapshot(11);
    try
      AssertTrue('ModEx packet missing from retained window',
        Length(Packets) >= 1);
      AssertTrue('ModEx packet was not retained byte-exactly',
        BytesEqual(Packets[High(Packets)].Payload.Bytes, ExpectedModEx));
    finally
      FreePacketArray(Packets);
    end;
  finally
    Buffer.Free;
  end;
end;

procedure TestTwitchVodAudioBootstrap;
var
  Buffer: TRtmpCircularBuffer;
  Headers: TRtmpPacketArray;
  Stats: TRtmpBufferStats;
begin
  Buffer:=TRtmpCircularBuffer.Create(1, 0);
  try
    Buffer.Push(MakePacket(mtAudio, 20, 0,
      [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader],
      [$AF, $00, $12, $10]));
    Buffer.Push(MakePacket(mtAudio, 21, 0,
      [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader],
      [$95, $00, Ord('m'), Ord('p'), Ord('4'), Ord('a'), $01, $12, $10]));

    AssertTrue('live audio track-zero config was not retained',
      Buffer.HasAudioTrackConfig(0));
    AssertTrue('Twitch VOD audio track-one config was not retained',
      Buffer.HasAudioTrackConfig(1));
    Stats:=Buffer.GetStats;
    AssertEqualInt('Twitch audio config track count', 2,
      Stats.AudioConfigTrackCount);

    Headers:=Buffer.GetCodecHeadersSnapshot;
    try
      AssertEqualInt('Twitch bootstrap audio header count', 2,
        Length(Headers));
      AssertTrue('Twitch bootstrap lost legacy live audio header',
        (Headers[0].Payload.Bytes[0] = $AF) OR
        (Headers[1].Payload.Bytes[0] = $AF));
      AssertTrue('Twitch bootstrap lost enhanced VOD audio header',
        (Headers[0].Payload.Bytes[0] = $95) OR
        (Headers[1].Payload.Bytes[0] = $95));
    finally
      FreePacketArray(Headers);
    end;

    Buffer.Clear;
    Buffer.Push(MakePacket(mtAudio, 10, 0,
      [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader],
      [$95, $10, Ord('m'), Ord('p'), Ord('4'), Ord('a'),
       $00, $00, $00, $02, $12, $10,
       $01, $00, $00, $02, $12, $10]));
    Buffer.Push(MakePacket(mtAudio, 20, 0,
      [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader],
      [$95, $00, Ord('m'), Ord('p'), Ord('4'), Ord('a'),
       $00, $11, $90]));
    Headers:=Buffer.GetCodecHeadersSnapshot;
    try
      AssertEqualInt('partial multitrack update header count', 2,
        Length(Headers));
      AssertEqualUInt64('partial update older combined header order', 10,
        Headers[0].SequenceNo);
      AssertEqualUInt64('partial update newer single header order', 20,
        Headers[1].SequenceNo);
    finally
      FreePacketArray(Headers);
    end;
  finally
    Buffer.Free;
  end;
end;

begin
  TestPacketLimitEviction;
  TestByteLimitEviction;
  TestBootstrapRetention;
  TestDurationLimitEviction;
  TestEnhancedWrapperRetention;
  TestTwitchVodAudioBootstrap;
  WriteLn('Buffer smoke passed.');
end.

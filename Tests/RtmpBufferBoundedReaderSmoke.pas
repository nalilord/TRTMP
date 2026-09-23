program RtmpBufferBoundedReaderSmoke;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

uses
  SysUtils,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Types;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure FreePackets(var APackets: TRtmpPacketArray);
var
  I: Integer;
begin
  for I:=0 to High(APackets) do
    APackets[I].Free;
  APackets:=nil;
end;

procedure PushPacket(ABuffer: TRtmpCircularBuffer; ASequenceNo: UInt64;
  ASize: Integer; AFlags: TRtmpPacketFlags; AArrivalTick: UInt64 = 0);
var
  Payload: IRtmpPayload;
begin
  Payload:=TRtmpSharedPayload.Create(ASize);
  ABuffer.Push(TRtmpPacket.Create(mtVideo, UInt32(ASequenceNo * 40),
    40, 1, 6, Payload, AFlags, ASequenceNo, AArrivalTick));
end;

var
  Buffer: TRtmpCircularBuffer;
  FirstAvailable: UInt64;
  I: Integer;
  NextSequenceNo: UInt64;
  Packets: TRtmpPacketArray;
  Truncated: Boolean;
begin
  Buffer:=TRtmpCircularBuffer.Create(4, 8);
  try
    for I:=1 to 6 do
      PushPacket(Buffer, I, 2, [pfIsVideo]);
    Packets:=Buffer.GetSinceSequenceSnapshotBounded(1, 2, 4, 0,
      FirstAvailable, NextSequenceNo);
    try
      Check((FirstAvailable = 3) AND (NextSequenceNo = 5) AND
        (Length(Packets) = 2), 'reader batch or sequence gap changed');
      Check((Packets[0].SequenceNo = 3) AND (Packets[1].SequenceNo = 4),
        'bounded reader returned wrong packet sequence');
      Buffer.Clear;
      Check(Packets[0].PayloadSize = 2,
        'owned snapshot did not survive source buffer clear');
    finally
      FreePackets(Packets);
    end;
    PushPacket(Buffer, 7, 4, [pfIsVideo]);
    Packets:=Buffer.GetSinceSequenceSnapshotBounded(7, 2, 2, 0,
      FirstAvailable, NextSequenceNo);
    Check((Length(Packets) = 0) AND (FirstAvailable = 7) AND
      (NextSequenceNo = 8), 'oversized reader point did not advance');
    FreePackets(Packets);
  finally
    Buffer.Free;
  end;
  Buffer:=TRtmpCircularBuffer.Create(4, 8);
  try
    PushPacket(Buffer, 1, 2, [pfIsVideo, pfIsKeyframe]);
    for I:=2 to 6 do
      PushPacket(Buffer, I, 2, [pfIsVideo]);
    Check(Buffer.GetCoherentBootstrapSequenceNo = 0,
      'stale pinned keyframe was accepted as coherent bootstrap');
    Packets:=Buffer.GetSinceSequenceSnapshotBounded(1, 4, 8, 0,
      FirstAvailable, NextSequenceNo);
    Check((FirstAvailable = 3) AND (Length(Packets) > 0) AND
      (Packets[0].SequenceNo = 3),
      'stale pinned keyframe entered bounded reader batch');
    FreePackets(Packets);
    PushPacket(Buffer, 7, 2, [pfIsVideo, pfIsKeyframe]);
    Check(Buffer.GetCoherentBootstrapSequenceNo = 7,
      'current retained keyframe was not selected');
  finally
    Buffer.Free;
  end;
  Buffer:=TRtmpCircularBuffer.Create(4, 8);
  try
    PushPacket(Buffer, 1, 2, [pfIsMetadata]);
    PushPacket(Buffer, 2, 2, [pfIsVideo, pfIsCodecConfig]);
    Packets:=Buffer.GetCodecHeadersSnapshotBounded(1, 2, Truncated);
    Check(Truncated AND (Length(Packets) = 1) AND
      (Packets[0].SequenceNo = 1),
      'bounded header snapshot exceeded packet or byte cap');
    FreePackets(Packets);
  finally
    Buffer.Free;
  end;
  Buffer:=TRtmpCircularBuffer.Create(4, 8);
  try
    PushPacket(Buffer, 1, 2, [pfIsVideo, pfIsKeyframe], 1);
    PushPacket(Buffer, 2, 2, [pfIsVideo]);
    Check(Buffer.GetCoherentBootstrapSequenceNo(1000) = 0,
      'expired keyframe was selected for lag recovery');
    Packets:=Buffer.GetSinceSequenceSnapshotBounded(1, 4, 8, 1000,
      FirstAvailable, NextSequenceNo);
    Check((Length(Packets) = 1) AND (FirstAvailable = 2) AND
      (NextSequenceNo = 3), 'lag limit did not skip expired media');
    FreePackets(Packets);
  finally
    Buffer.Free;
  end;
  Buffer:=TRtmpCircularBuffer.Create(4, 8);
  try
    Buffer.MaxRetainedBytes:=4;
    PushPacket(Buffer, 1, 3, [pfIsMetadata]);
    PushPacket(Buffer, 2, 3, [pfIsVideo, pfIsKeyframe]);
    Check((Buffer.GetStats.FPinnedBudgetBytes = 3) AND
      (Buffer.GetStats.FPinnedBudgetDrops = 1) AND
      (Buffer.GetLatestKeyframe = nil),
      'pinned payload cap did not reject a new keyframe');
    PushPacket(Buffer, 3, 2, [pfIsMetadata]);
    PushPacket(Buffer, 4, 2, [pfIsVideo, pfIsKeyframe]);
    Check((Buffer.GetStats.FPinnedBudgetBytes = 4) AND
      (Buffer.GetLatestKeyframe <> nil),
      'replacing a pin did not release its byte reservation');
    PushPacket(Buffer, 5, 5, [pfIsVideo, pfIsKeyframe]);
    Check((Buffer.GetStats.FPinnedBudgetBytes = 2) AND
      (Buffer.GetLatestKeyframe = nil),
      'oversized new pin left a stale keyframe');
    Buffer.Clear;
    Check(Buffer.GetStats.FPinnedBudgetBytes = 0,
      'clear did not release pinned byte reservations');
  finally
    Buffer.Free;
  end;
  WriteLn('RtmpBufferBoundedReaderSmoke: PASS');
end.

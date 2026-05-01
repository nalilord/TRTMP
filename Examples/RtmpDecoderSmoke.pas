program RtmpDecoderSmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  libavutil_error,
  RtmpDecoder,
  RtmpDecoderFFmpeg,
  RtmpPacket,
  RtmpTypes;

const
  AAC_EXTRADATA_HEX =
    '118856e500';
  AAC_PACKET_HEX =
    '00ea3518b68a568643a390e85c40170809420111005c2e73a97397ffb7f6fffe' +
    'fed23c752548f6e64973be78af59ec19cc8cafb76ef804777c6bba532def0e9b' +
    '335c7626411a887efce371cfc3357e78c3fa46ef986679866784b7db28e828c4' +
    '1c41d227489d227489d227489d2274901e495883883883883883883883883883' +
    '883883d5d5d5d4ff5dc0abd3fc9b2babababab0002bed66000000f7580073f7d' +
    '000052200017e9730e';
  AVC_EXTRADATA_HEX =
    '0142c00affe100156742c00adc96c0440000030004000003000a3c489e01000468ce0fc8';
  AVC_PACKET_HEX =
    '000002430605ffff3fdc45e9bde6d948b7962cd820d923eeef78323634202d20' +
    '636f726520313634202d20482e3236342f4d5045472d342041564320636f6465' +
    '63202d20436f70796c65667420323030332d32303234202d20687474703a2f2f' +
    '7777772e766964656f6c616e2e6f72672f783236342e68746d6c202d206f7074' +
    '696f6e733a2063616261633d30207265663d31206465626c6f636b3d303a303a' +
    '3020616e616c7973653d303a30206d653d646961207375626d653d3020707379' +
    '3d31207073795f72643d312e30303a302e3030206d697865645f7265663d3020' +
    '6d655f72616e67653d3136206368726f6d615f6d653d31207472656c6c69733d' +
    '30203878386463743d302063716d3d3020646561647a6f6e653d32312c313120' +
    '666173745f70736b69703d31206368726f6d615f71705f6f66667365743d3020' +
    '746872656164733d31206c6f6f6b61686561645f746872656164733d3120736c' +
    '696365645f746872656164733d30206e723d3020646563696d6174653d312069' +
    '6e7465726c616365643d3020626c757261795f636f6d7061743d3020636f6e73' +
    '747261696e65645f696e7472613d3020626672616d65733d3020776569676874' +
    '703d30206b6579696e743d31206b6579696e745f6d696e3d31207363656e6563' +
    '75743d3020696e7472615f726566726573683d302072633d637266206d627472' +
    '65653d30206372663d32332e302071636f6d703d302e36302071706d696e3d30' +
    '2071706d61783d3639207170737465703d342069705f726174696f3d312e3430' +
    '2061713d300080000000156588843a118a000218f1c00040f63800087949d75e';

function HexNibble(ACh: Char): Integer;
begin
  case ACh of
    '0'..'9': Result := Ord(ACh) - Ord('0');
    'a'..'f': Result := 10 + Ord(ACh) - Ord('a');
    'A'..'F': Result := 10 + Ord(ACh) - Ord('A');
  else
    raise Exception.CreateFmt('Invalid hex character "%s"', [ACh]);
  end;
end;

function HexToBytes(const AHex: string): TBytes;
var
  I: Integer;
  Clean: string;
begin
  Result := nil;
  Clean := StringReplace(AHex, ' ', '', [rfReplaceAll]);
  if (Length(Clean) mod 2) <> 0 then
    raise Exception.Create('Hex string must have an even number of digits');

  SetLength(Result, Length(Clean) div 2);
  for I := 0 to Length(Result) - 1 do
    Result[I] := Byte((HexNibble(Clean[(I * 2) + 1]) shl 4) or
      HexNibble(Clean[(I * 2) + 2]));
end;

function MakePacket(AMessageType: TRtmpMessageType; ATimestamp, ATimestampDelta: UInt32;
  const APayload: TBytes; const AFlags: TRtmpPacketFlags): TRtmpPacket;
begin
  Result := TRtmpPacket.Create(AMessageType, ATimestamp, ATimestampDelta, 1, 6,
    TRtmpSharedPayload.Create(APayload), AFlags, 1);
end;

procedure AssertTrue(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise Exception.Create(AMessage);
end;

procedure TestAudioConfigOpen;
var
  ConfigPacket: TRtmpPacket;
  Decoder: TRtmpFFmpegPacketDecoder;
  Payload: TBytes;
begin
  Payload := HexToBytes('ae00' + AAC_EXTRADATA_HEX);
  ConfigPacket := MakePacket(mtAudio, 0, 0, Payload, [pfIsAudio, pfIsCodecConfig, pfIsSequenceHeader]);
  Decoder := TRtmpFFmpegPacketDecoder.Create;
  try
    AssertTrue(Decoder.OpenFromConfig(ConfigPacket), Decoder.LastErrorText);
    AssertTrue(Decoder.MediaKind = dmAudio, 'Audio decoder media kind mismatch');
    AssertTrue(Decoder.CodecKind = dcAAC, 'Audio decoder codec mismatch');
  finally
    Decoder.Free;
    ConfigPacket.Free;
  end;
end;

procedure TestVideoDecode;
var
  ConfigPacket: TRtmpPacket;
  Decoder: TRtmpFFmpegPacketDecoder;
  FrameInfo: TRtmpDecodedFrameInfo;
  Payload: TBytes;
  RawPacket: TRtmpPacket;
  ResultCode: Integer;
begin
  Payload := HexToBytes('1700000000' + AVC_EXTRADATA_HEX);
  ConfigPacket := MakePacket(mtVideo, 0, 0, Payload, [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe]);
  Decoder := TRtmpFFmpegPacketDecoder.Create;
  try
    AssertTrue(Decoder.OpenFromConfig(ConfigPacket), Decoder.LastErrorText);

    Payload := HexToBytes('1701000000' + AVC_PACKET_HEX);
    RawPacket := MakePacket(mtVideo, 21, 200, Payload, [pfIsVideo, pfIsKeyframe]);
    try
      ResultCode := Decoder.SubmitPacket(RawPacket);
      AssertTrue(ResultCode >= 0, Decoder.LastErrorText);
      ResultCode := Decoder.ReceiveFrame(FrameInfo);
      AssertTrue(ResultCode >= 0, Decoder.LastErrorText);
      AssertTrue(FrameInfo.MediaKind = dmVideo, 'Video decoder returned wrong media kind');
      AssertTrue(FrameInfo.Codec = dcAVC, 'Video decoder returned wrong codec');
      AssertTrue(FrameInfo.Width = 32, 'Decoded video width mismatch');
      AssertTrue(FrameInfo.Height = 32, 'Decoded video height mismatch');
      AssertTrue(FrameInfo.IsKeyframe, 'Decoded video frame should be keyframe');
      Decoder.UnrefFrame;
    finally
      RawPacket.Free;
    end;
  finally
    Decoder.Free;
    ConfigPacket.Free;
  end;
end;

begin
  TestAudioConfigOpen;
  TestVideoDecode;
  WriteLn('Decoder smoke passed: AAC config-open and AVC decode paths are operational.');
end.

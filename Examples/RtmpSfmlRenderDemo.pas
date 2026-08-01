program RtmpSfmlRenderDemo;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  libavutil_pixfmt,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Decode,
  TRTMP.RTMP.Decode.FFmpeg,
  TRTMP.FFmpeg.FrameConvert,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Types,
  SfmlGraphics,
  SfmlSystem,
  SfmlWindow;

const
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
    '0'..'9': Result:=Ord(ACh) - Ord('0');
    'a'..'f': Result:=10 + Ord(ACh) - Ord('a');
    'A'..'F': Result:=10 + Ord(ACh) - Ord('A');
  else
    raise Exception.CreateFmt('Invalid hex character "%s"', [ACh]);
  end;
end;

function HexToBytes(const AHex: string): TBytes;
var
  Clean: string;
  I: Integer;
begin
  Result:=nil;
  Clean:=StringReplace(AHex, ' ', '', [rfReplaceAll]);
  if (Length(Clean) MOD 2) <> 0 then
    raise Exception.Create('Hex string must have an even number of digits');

  SetLength(Result, Length(Clean) DIV 2);
  for I:=0 to Length(Result) - 1 do
    Result[I]:=Byte((HexNibble(Clean[(I * 2) + 1]) SHL 4) OR
      HexNibble(Clean[(I * 2) + 2]));
end;

function MakePacket(AMessageType: TRtmpMessageType; ATimestamp,
  ATimestampDelta: UInt32; const APayload: TBytes;
  const AFlags: TRtmpPacketFlags): TRtmpPacket;
begin
  Result:=TRtmpPacket.Create(AMessageType, ATimestamp, ATimestampDelta, 1, 6,
    TRtmpSharedPayload.Create(APayload), AFlags, 1);
end;

procedure AssertTrue(ACondition: Boolean; const AMessage: string);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure DecodeFixtureFrame(out APixels: TBytes; out AWidth, AHeight: Integer;
  out AInfo: TRtmpDecodedFrameInfo);
var
  ConfigPacket: TRtmpPacket;
  Converter: TRtmpFFmpegFrameConverter;
  Decoder: TRtmpFFmpegPacketDecoder;
  Payload: TBytes;
  RawPacket: TRtmpPacket;
  ResultCode: Integer;
begin
  APixels:=nil;
  AWidth:=0;
  AHeight:=0;
  AInfo:=Default(TRtmpDecodedFrameInfo);

  Decoder:=TRtmpFFmpegPacketDecoder.Create;
  Converter:=TRtmpFFmpegFrameConverter.Create(AV_PIX_FMT_RGBA);
  ConfigPacket:=nil;
  RawPacket:=nil;
  try
    Payload:=HexToBytes('1700000000' + AVC_EXTRADATA_HEX);
    ConfigPacket:=MakePacket(mtVideo, 0, 0, Payload,
      [pfIsVideo, pfIsCodecConfig, pfIsSequenceHeader, pfIsKeyframe]);
    AssertTrue(Decoder.OpenFromConfig(ConfigPacket), Decoder.LastErrorText);

    Payload:=HexToBytes('1701000000' + AVC_PACKET_HEX);
    RawPacket:=MakePacket(mtVideo, 21, 200, Payload, [pfIsVideo, pfIsKeyframe]);
    ResultCode:=Decoder.SubmitPacket(RawPacket);
    AssertTrue(ResultCode >= 0, Decoder.LastErrorText);

    ResultCode:=Decoder.ReceiveFrame(AInfo);
    AssertTrue(ResultCode >= 0, Decoder.LastErrorText);
    AssertTrue(Converter.ConvertVideoFrame(Decoder.Frame), Converter.LastErrorText);

    AWidth:=Converter.Width;
    AHeight:=Converter.Height;
    SetLength(APixels, Converter.BufferSize);
    Move(Converter.Buffer^, APixels[0], Converter.BufferSize);

    Decoder.UnrefFrame;
  finally
    RawPacket.Free;
    ConfigPacket.Free;
    Converter.Free;
    Decoder.Free;
  end;
end;

procedure RunWindow;
var
  Event: TSfmlEvent;
  FrameInfo: TRtmpDecodedFrameInfo;
  Mode: TSfmlVideoMode;
  Pixels: TBytes;
  Scale: Single;
  ScaledHeight: Cardinal;
  ScaledWidth: Cardinal;
  Sprite: TSfmlSprite;
  Texture: TSfmlTexture;
  TextureSize: TSfmlVector2u;
  Window: TSfmlRenderWindow;
  WindowSize: TSfmlVector2u;
  WindowTitle: AnsiString;
  RawHeight: Integer;
  RawWidth: Integer;
begin
  DecodeFixtureFrame(Pixels, RawWidth, RawHeight, FrameInfo);
  AssertTrue((RawWidth > 0) AND (RawHeight > 0), 'Decoded frame has invalid size');

  Scale:=16.0;
  ScaledWidth:=Cardinal(RawWidth * Trunc(Scale));
  ScaledHeight:=Cardinal(RawHeight * Trunc(Scale));
  if ScaledWidth < 320 then
    ScaledWidth:=320;
  if ScaledHeight < 240 then
    ScaledHeight:=240;

  Mode:=SfmlVideoMode(ScaledWidth, ScaledHeight, 32);
  WindowTitle:=AnsiString(Format(
    'TRTMP SFML Demo - %dx%d %s ts=%dms',
    [FrameInfo.Width, FrameInfo.Height, RtmpDecoderCodecName(FrameInfo.Codec),
     FrameInfo.TimestampMS]));

  Window:=TSfmlRenderWindow.Create(Mode, WindowTitle, sfClose, sfWindowed);
  try
    Window.SetVerticalSyncEnabled(True);

    TextureSize:=SfmlVector2u(Cardinal(RawWidth), Cardinal(RawHeight));
    Texture:=TSfmlTexture.Create(TextureSize);
    try
      Texture.UpdateFromPixels(@Pixels[0], Cardinal(RawWidth), Cardinal(RawHeight), 0, 0);

      Sprite:=TSfmlSprite.Create(Texture);
      try
        Sprite.ScaleFactor:=SfmlVector2f(Scale, Scale);
        WindowSize:=Window.Size;
        Sprite.Position:=SfmlVector2f(
          (WindowSize.X - (RawWidth * Scale)) * 0.5,
          (WindowSize.Y - (RawHeight * Scale)) * 0.5);

        while Window.IsOpen do
        begin
          while Window.PollEvent(Event) do
          begin
            if Event.EventType = sfEvtClosed then
              Window.Close;
          end;

          Window.Clear(SfmlBlack);
          Window.Draw(Sprite, nil);
          Window.Display;
        end;
      finally
        Sprite.Free;
      end;
    finally
      Texture.Free;
    end;
  finally
    Window.Free;
  end;
end;

begin
  RtmpMaskFloatingPointExceptions;
  RunWindow;
end.

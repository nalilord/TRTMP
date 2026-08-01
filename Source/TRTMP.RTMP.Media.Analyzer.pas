unit TRTMP.RTMP.Media.Analyzer;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  SyncObjs,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Protocol.FLV,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Types;

type
  TRtmpAnalyzer = class
  private
    FConfiguredAudioChannels: Integer;
    FConfiguredAudioSampleRate: Integer;
    FFirstVideoFrameTimestamp: UInt32;
    FHasStarted: Boolean;
    FLock: TCriticalSection;
    FHasConfiguredAudio: Boolean;
    FHasFirstVideoFrame: Boolean;
    FStartedAt: TRtmpTick;
    FSnapshot: TRtmpAnalysisSnapshot;
    FTotalJitterMS: UInt64;
    FPacketCount: UInt64;
    FTotalBytes: UInt64;
    FAudioBytes: UInt64;
    FVideoBytes: UInt64;
    FVideoFrameCount: UInt64;
    FVideoJitterSamples: UInt64;
    FLastVideoArrivalTick: TRtmpTick;
    FHasVideoArrivalTick: Boolean;
    FLastAudioTimestamp: UInt32;
    FLastVideoTimestamp: UInt32;
    FHasAudioTimestamp: Boolean;
    FHasVideoTimestamp: Boolean;
    FLastKeyframeTimestamp: UInt32;
    FHasKeyframe: Boolean;
    procedure FeedAudio(const APacket: TRtmpPacket);
    procedure FeedVideo(const APacket: TRtmpPacket);
    procedure RecalculateSnapshot;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Feed(const APacket: TRtmpPacket);
    function GetSnapshot: TRtmpAnalysisSnapshot;
    procedure Reset;
  end;

implementation

type
  TBitReader = record
  private
    FBits: TBytes;
    FBitPosition: Integer;
  public
    constructor Create(const ABytes: TBytes);
    function BitsRemaining: Integer;
    function ReadBit: Integer;
    function ReadBits(ACount: Integer): UInt32;
    function ReadUE: UInt32;
    function ReadSE: Integer;
    procedure SkipBits(ACount: Integer);
  end;

constructor TBitReader.Create(const ABytes: TBytes);
begin
  FBits:=ABytes;
  FBitPosition:=0;
end;

function TBitReader.BitsRemaining: Integer;
begin
  Result:=(Length(FBits) * 8) - FBitPosition;
end;

function TBitReader.ReadBit: Integer;
var
  ByteIndex: Integer;
  ShiftCount: Integer;
begin
  if BitsRemaining <= 0 then
    raise Exception.Create('Bit reader underrun');

  ByteIndex:=FBitPosition DIV 8;
  ShiftCount:=7 - (FBitPosition MOD 8);
  Result:=(FBits[ByteIndex] SHR ShiftCount) AND $01;
  Inc(FBitPosition);
end;

function TBitReader.ReadBits(ACount: Integer): UInt32;
var
  I: Integer;
begin
  if ACount < 0 then
    raise Exception.Create('Negative bit count requested');
  if ACount > 32 then
    raise Exception.Create('Bit reader only supports up to 32 bits at once');

  Result:=0;
  for I:=0 to ACount - 1 do
    Result:=(Result SHL 1) OR UInt32(ReadBit);
end;

function TBitReader.ReadUE: UInt32;
var
  LeadingZeroBits: Integer;
  Suffix: UInt32;
begin
  LeadingZeroBits:=0;
  while (BitsRemaining > 0) AND (ReadBit = 0) do
    Inc(LeadingZeroBits);

  if LeadingZeroBits = 0 then
    Exit(0);

  Suffix:=ReadBits(LeadingZeroBits);
  Result:=(UInt32(1) SHL LeadingZeroBits) - 1 + Suffix;
end;

function TBitReader.ReadSE: Integer;
var
  CodeNum: UInt32;
begin
  CodeNum:=ReadUE;
  if (CodeNum AND 1) <> 0 then
    Result:=Integer((CodeNum + 1) DIV 2)
  else
    Result:=-Integer(CodeNum DIV 2);
end;

procedure TBitReader.SkipBits(ACount: Integer);
begin
  if ACount < 0 then
    raise Exception.Create('Negative bit skip requested');
  if ACount > BitsRemaining then
    raise Exception.Create('Bit reader underrun during skip');
  Inc(FBitPosition, ACount);
end;

function AudioCodecName(AFormat: Byte): string;
begin
  case AFormat of
    2: Result:='MP3';
    10: Result:='AAC';
    11: Result:='Speex';
  else
    Result:='Unknown';
  end;
end;

function EnhancedAudioCodecName(const AFourCC: string): string;
begin
  if AFourCC = 'Opus' then
    Result:='Opus'
  else if AFourCC = 'fLaC' then
    Result:='FLAC'
  else if AFourCC = 'ac-3' then
    Result:='AC-3'
  else if AFourCC = 'ec-3' then
    Result:='E-AC-3'
  else if AFourCC = '.mp3' then
    Result:='MP3'
  else if AFourCC = 'mp4a' then
    Result:='AAC'
  else
    Result:='Unknown (' + AFourCC + ')';
end;

function AudioSampleRateFromHeader(ARate: Byte): Integer;
begin
  case ARate of
    0: Result:=5512;
    1: Result:=11025;
    2: Result:=22050;
    3: Result:=44100;
  else
    Result:=0;
  end;
end;

function VideoCodecName(ACodecID: Byte): string;
begin
  case ACodecID of
    2: Result:='Sorenson Spark';
    3: Result:='Screen Video';
    4: Result:='VP6';
    5: Result:='VP6 Alpha';
    6: Result:='Screen Video v2';
    7: Result:='AVC';
    12: Result:='HEVC';
  else
    Result:='Unknown';
  end;
end;

function EnhancedVideoCodecName(const AFourCC: string): string;
begin
  if AFourCC = 'hvc1' then
    Result:='HEVC'
  else if AFourCC = 'av01' then
    Result:='AV1'
  else if AFourCC = 'vp09' then
    Result:='VP9'
  else if AFourCC = 'vp08' then
    Result:='VP8'
  else if AFourCC = 'avc1' then
    Result:='AVC'
  else if AFourCC = 'vvc1' then
    Result:='VVC'
  else
    Result:='Unknown (' + AFourCC + ')';
end;

function RemoveEmulationPreventionBytes(const ABytes: TBytes): TBytes;
var
  I: Integer;
  OutIndex: Integer;
begin
  Result:=nil;
  SetLength(Result, Length(ABytes));
  OutIndex:=0;
  I:=0;
  while I < Length(ABytes) do
  begin
    if (I + 2 < Length(ABytes)) AND (ABytes[I] = 0) AND (ABytes[I + 1] = 0) AND
      (ABytes[I + 2] = 3) then
    begin
      Result[OutIndex]:=0;
      Inc(OutIndex);
      Result[OutIndex]:=0;
      Inc(OutIndex);
      Inc(I, 3);
      Continue;
    end;

    Result[OutIndex]:=ABytes[I];
    Inc(OutIndex);
    Inc(I);
  end;
  SetLength(Result, OutIndex);
end;

procedure SkipScalingList(var AReader: TBitReader; ACount: Integer);
var
  DeltaScale: Integer;
  I: Integer;
  NextScale: Integer;
  Scale: Integer;
begin
  Scale:=8;
  NextScale:=8;
  for I:=0 to ACount - 1 do
  begin
    if NextScale <> 0 then
    begin
      DeltaScale:=AReader.ReadSE;
      NextScale:=(Scale + DeltaScale + 256) MOD 256;
    end;

    if NextScale <> 0 then
      Scale:=NextScale;
  end;
end;

function TryParseAacAudioSpecificConfig(const ABytes: TBytes;
  out ASampleRate, AChannels: Integer): Boolean;
const
  AAC_SAMPLE_RATES: array[0..12] of Integer = (
    96000, 88200, 64000, 48000, 44100, 32000, 24000,
    22050, 16000, 12000, 11025, 8000, 7350
  );
var
  AudioObjectType: UInt32;
  ChannelConfiguration: UInt32;
  FrequencyIndex: UInt32;
  Reader: TBitReader;
begin
  Result:=False;
  ASampleRate:=0;
  AChannels:=0;

  if Length(ABytes) < 2 then
    Exit;

  Reader:=TBitReader.Create(ABytes);
  try
    AudioObjectType:=Reader.ReadBits(5);
    FrequencyIndex:=Reader.ReadBits(4);
    if FrequencyIndex = $0F then
      ASampleRate:=Integer(Reader.ReadBits(24))
    else if FrequencyIndex <= High(AAC_SAMPLE_RATES) then
      ASampleRate:=AAC_SAMPLE_RATES[FrequencyIndex]
    else
      Exit;

    ChannelConfiguration:=Reader.ReadBits(4);
    case ChannelConfiguration of
      1: AChannels:=1;
      2: AChannels:=2;
      3: AChannels:=3;
      4: AChannels:=4;
      5: AChannels:=5;
      6: AChannels:=6;
      7: AChannels:=8;
    else
      AChannels:=0;
    end;

    Result:=(AudioObjectType > 0) AND (ASampleRate > 0);
  except
    Result:=False;
  end;
end;

function TryParseAvcSpsDimensions(const ASpsNal: TBytes;
  out AWidth, AHeight: Integer): Boolean;
var
  ChromaFormatIDC: UInt32;
  CropBottom: UInt32;
  CropLeft: UInt32;
  CropRight: UInt32;
  CropTop: UInt32;
  CropUnitX: Integer;
  CropUnitY: Integer;
  FrameCroppingFlag: Integer;
  FrameMbsOnlyFlag: Integer;
  I: Integer;
  NumRefFramesInPicOrderCntCycle: UInt32;
  PicHeightInMapUnitsMinus1: UInt32;
  PicOrderCntType: UInt32;
  PicWidthInMbsMinus1: UInt32;
  ProfileIDC: UInt32;
  RawRbsp: TBytes;
  Reader: TBitReader;
  SeparateColorPlaneFlag: Integer;
begin
  Result:=False;
  AWidth:=0;
  AHeight:=0;

  if Length(ASpsNal) < 4 then
    Exit;
  if (ASpsNal[0] AND $1F) <> 7 then
    Exit;

  RawRbsp:=nil;
  SetLength(RawRbsp, Length(ASpsNal) - 1);
  Move(ASpsNal[1], RawRbsp[0], Length(ASpsNal) - 1);
  RawRbsp:=RemoveEmulationPreventionBytes(RawRbsp);

  Reader:=TBitReader.Create(RawRbsp);
  try
    ProfileIDC:=Reader.ReadBits(8);
    Reader.SkipBits(8); // constraint flags + reserved bits
    Reader.SkipBits(8); // level_idc
    Reader.ReadUE; // seq_parameter_set_id

    ChromaFormatIDC:=1;
    SeparateColorPlaneFlag:=0;
    if ProfileIDC IN [100, 110, 122, 244, 44, 83, 86, 118, 128,
      138, 139, 134, 135] then
    begin
      ChromaFormatIDC:=Reader.ReadUE;
      if ChromaFormatIDC = 3 then
        SeparateColorPlaneFlag:=Reader.ReadBit;
      Reader.ReadUE; // bit_depth_luma_minus8
      Reader.ReadUE; // bit_depth_chroma_minus8
      Reader.ReadBit; // qpprime_y_zero_transform_bypass_flag
      if Reader.ReadBit <> 0 then
      begin
        if ChromaFormatIDC <> 3 then
          I:=8
        else
          I:=12;
        while I > 0 do
        begin
          if Reader.ReadBit <> 0 then
          begin
            if I > 6 then
              SkipScalingList(Reader, 64)
            else
              SkipScalingList(Reader, 16);
          end;
          Dec(I);
        end;
      end;
    end;

    Reader.ReadUE; // log2_max_frame_num_minus4
    PicOrderCntType:=Reader.ReadUE;
    if PicOrderCntType = 0 then
      Reader.ReadUE
    else if PicOrderCntType = 1 then
    begin
      Reader.ReadBit;
      Reader.ReadSE;
      Reader.ReadSE;
      NumRefFramesInPicOrderCntCycle:=Reader.ReadUE;
      for I:=0 to Integer(NumRefFramesInPicOrderCntCycle) - 1 do
        Reader.ReadSE;
    end;

    Reader.ReadUE; // max_num_ref_frames
    Reader.ReadBit; // gaps_in_frame_num_value_allowed_flag
    PicWidthInMbsMinus1:=Reader.ReadUE;
    PicHeightInMapUnitsMinus1:=Reader.ReadUE;
    FrameMbsOnlyFlag:=Reader.ReadBit;
    if FrameMbsOnlyFlag = 0 then
      Reader.ReadBit; // mb_adaptive_frame_field_flag
    Reader.ReadBit; // direct_8x8_inference_flag

    FrameCroppingFlag:=Reader.ReadBit;
    CropLeft:=0;
    CropRight:=0;
    CropTop:=0;
    CropBottom:=0;
    if FrameCroppingFlag <> 0 then
    begin
      CropLeft:=Reader.ReadUE;
      CropRight:=Reader.ReadUE;
      CropTop:=Reader.ReadUE;
      CropBottom:=Reader.ReadUE;
    end;

    case ChromaFormatIDC of
      0:
        begin
          CropUnitX:=1;
          CropUnitY:=2 - FrameMbsOnlyFlag;
        end;
      1:
        begin
          CropUnitX:=2;
          CropUnitY:=2 * (2 - FrameMbsOnlyFlag);
        end;
      2:
        begin
          CropUnitX:=2;
          CropUnitY:=2 - FrameMbsOnlyFlag;
        end;
    else
      begin
        if SeparateColorPlaneFlag <> 0 then
          CropUnitX:=1
        else
          CropUnitX:=1;
        CropUnitY:=2 - FrameMbsOnlyFlag;
      end;
    end;

    AWidth:=Integer((PicWidthInMbsMinus1 + 1) * 16) -
      Integer((CropLeft + CropRight) * UInt32(CropUnitX));
    AHeight:=Integer((PicHeightInMapUnitsMinus1 + 1) * 16 * UInt32(2 - FrameMbsOnlyFlag)) -
      Integer((CropTop + CropBottom) * UInt32(CropUnitY));
    Result:=(AWidth > 0) AND (AHeight > 0);
  except
    Result:=False;
  end;
end;

function TryParseAvcDecoderConfigurationRecord(const ABytes: TBytes;
  out AWidth, AHeight: Integer): Boolean;
var
  NalLength: Integer;
  NumSps: Integer;
  Offset: Integer;
  SpsBytes: TBytes;
begin
  Result:=False;
  AWidth:=0;
  AHeight:=0;

  if Length(ABytes) < 7 then
    Exit;
  if ABytes[0] <> 1 then
    Exit;

  Offset:=5;
  NumSps:=ABytes[Offset] AND $1F;
  Inc(Offset);
  if NumSps <= 0 then
    Exit;

  NalLength:=(Integer(ABytes[Offset]) SHL 8) OR Integer(ABytes[Offset + 1]);
  Inc(Offset, 2);
  if (NalLength <= 0) OR (Offset + NalLength > Length(ABytes)) then
    Exit;

  SetLength(SpsBytes, NalLength);
  Move(ABytes[Offset], SpsBytes[0], NalLength);
  Result:=TryParseAvcSpsDimensions(SpsBytes, AWidth, AHeight);
end;

constructor TRtmpAnalyzer.Create;
begin
  inherited Create;
  FLock:=TCriticalSection.Create;
  Reset;
end;

destructor TRtmpAnalyzer.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TRtmpAnalyzer.Feed(const APacket: TRtmpPacket);
begin
  if APacket = nil then
    Exit;

  FLock.Acquire;
  try
    if (NOT FHasStarted) AND
      (APacket.MessageType IN [mtAudio, mtVideo, mtAggregate]) then
    begin
      if APacket.ArrivalTick <> 0 then
        FStartedAt:=APacket.ArrivalTick
      else
        FStartedAt:=RtmpGetTickCount64;
      FHasStarted:=True;
    end;

    Inc(FPacketCount);
    Inc(FTotalBytes, UInt64(APacket.PayloadSize));

    if APacket.HasFlag(pfIsAudio) OR (APacket.MessageType = mtAudio) then
      FeedAudio(APacket)
    else if APacket.HasFlag(pfIsVideo) OR (APacket.MessageType = mtVideo) then
      FeedVideo(APacket);

    RecalculateSnapshot;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpAnalyzer.FeedAudio(const APacket: TRtmpPacket);
var
  ConfigChannels: Integer;
  ConfigSampleRate: Integer;
  Bytes: TBytes;
  Header: Byte;
  Info: TRtmpFlvTagInfo;
begin
  Inc(FAudioBytes, UInt64(APacket.PayloadSize));
  FLastAudioTimestamp:=APacket.Timestamp;
  FHasAudioTimestamp:=True;

  if Assigned(APacket.Payload) AND (APacket.Payload.Size > 0) then
  begin
    Bytes:=APacket.Payload.Bytes;
    Header:=Bytes[0];
    Info:=Default(TRtmpFlvTagInfo);
    if RtmpInspectFlvTag(mtAudio, Bytes, Info) AND Info.IsEnhanced then
    begin
      FSnapshot.AudioCodec:=EnhancedAudioCodecName(Info.CodecFourCC);
      if Info.CodecFourCC = 'Opus' then
        FSnapshot.AudioSampleRate:=48000;
      if Info.IsMultitrack then
      begin
        Inc(FSnapshot.AudioMultitrackPackets);
        if Info.TrackCount > FSnapshot.AudioTrackCount then
          FSnapshot.AudioTrackCount:=Info.TrackCount;
      end;
      if Info.IsModEx then
        Inc(FSnapshot.AudioModExPackets);
      if Info.HasTimestampNanoOffset then
        FSnapshot.AudioTimestampNanoOffset:=Info.TimestampNanoOffset;
    end
    else
    begin
      FSnapshot.AudioCodec:=AudioCodecName((Header SHR 4) AND $0F);
      FSnapshot.AudioSampleRate:=AudioSampleRateFromHeader((Header SHR 2) AND $03);
      if (Header AND $01) <> 0 then
        FSnapshot.AudioChannels:=2
      else
        FSnapshot.AudioChannels:=1;
    end;

    if (((Header SHR 4) AND $0F) = 10) AND (Length(Bytes) >= 4) AND
      (Bytes[1] = 0) AND
      TryParseAacAudioSpecificConfig(Copy(Bytes, 2, Length(Bytes) - 2),
        ConfigSampleRate, ConfigChannels) then
    begin
      if ConfigSampleRate > 0 then
        FConfiguredAudioSampleRate:=ConfigSampleRate;
      if ConfigChannels > 0 then
        FConfiguredAudioChannels:=ConfigChannels;
      FHasConfiguredAudio:=(FConfiguredAudioSampleRate > 0) OR
        (FConfiguredAudioChannels > 0);
    end;

    if FHasConfiguredAudio then
    begin
      if FConfiguredAudioSampleRate > 0 then
        FSnapshot.AudioSampleRate:=FConfiguredAudioSampleRate;
      if FConfiguredAudioChannels > 0 then
        FSnapshot.AudioChannels:=FConfiguredAudioChannels;
    end;
  end;
end;

procedure TRtmpAnalyzer.FeedVideo(const APacket: TRtmpPacket);
var
  ArrivalDeltaMS: Int64;
  Bytes: TBytes;
  Header: Byte;
  FrameType: Byte;
  JitterSampleMS: Int64;
  TimestampDeltaMS: Int64;
  Width: Integer;
  Height: Integer;
  Info: TRtmpFlvTagInfo;
begin
  Inc(FVideoBytes, UInt64(APacket.PayloadSize));

  if Assigned(APacket.Payload) AND (APacket.Payload.Size > 0) then
  begin
    Bytes:=APacket.Payload.Bytes;
    Header:=Bytes[0];
    Info:=Default(TRtmpFlvTagInfo);
    if RtmpInspectFlvTag(mtVideo, Bytes, Info) AND Info.IsEnhanced then
    begin
      FrameType:=Info.VideoFrameType;
      FSnapshot.VideoCodec:=EnhancedVideoCodecName(Info.CodecFourCC);
      if Info.IsMultitrack then
      begin
        Inc(FSnapshot.VideoMultitrackPackets);
        if Info.TrackCount > FSnapshot.VideoTrackCount then
          FSnapshot.VideoTrackCount:=Info.TrackCount;
      end;
      if Info.IsModEx then
        Inc(FSnapshot.VideoModExPackets);
      if Info.HasTimestampNanoOffset then
        FSnapshot.VideoTimestampNanoOffset:=Info.TimestampNanoOffset;
    end
    else
    begin
      FrameType:=(Header SHR 4) AND $0F;
      FSnapshot.VideoCodec:=VideoCodecName(Header AND $0F);
    end;

    if ((Header AND $0F) = 7) AND (Length(Bytes) >= 6) AND (Bytes[1] = 0) AND
      TryParseAvcDecoderConfigurationRecord(Copy(Bytes, 5, Length(Bytes) - 5),
        Width, Height) then
    begin
      FSnapshot.VideoWidth:=Width;
      FSnapshot.VideoHeight:=Height;
    end;

    if FrameType = 1 then
    begin
      if FHasKeyframe then
        FSnapshot.KeyframeIntervalMS:=Integer(APacket.Timestamp - FLastKeyframeTimestamp);
      FLastKeyframeTimestamp:=APacket.Timestamp;
      FHasKeyframe:=True;
    end;
  end;

  if NOT APacket.HasFlag(pfIsCodecConfig) then
  begin
    if NOT FHasFirstVideoFrame then
    begin
      FFirstVideoFrameTimestamp:=APacket.Timestamp;
      FHasFirstVideoFrame:=True;
    end;

    if FHasVideoTimestamp AND FHasVideoArrivalTick then
    begin
      TimestampDeltaMS:=Int64(APacket.Timestamp) - Int64(FLastVideoTimestamp);
      ArrivalDeltaMS:=Int64(APacket.ArrivalTick) - Int64(FLastVideoArrivalTick);
      JitterSampleMS:=Abs(ArrivalDeltaMS - TimestampDeltaMS);
      Inc(FTotalJitterMS, UInt64(JitterSampleMS));
      Inc(FVideoJitterSamples);
    end;

    Inc(FVideoFrameCount);
    FLastVideoTimestamp:=APacket.Timestamp;
    FHasVideoTimestamp:=True;
    FLastVideoArrivalTick:=APacket.ArrivalTick;
    FHasVideoArrivalTick:=True;
  end;
end;

function TRtmpAnalyzer.GetSnapshot: TRtmpAnalysisSnapshot;
begin
  FLock.Acquire;
  try
    RecalculateSnapshot;
    Result:=FSnapshot;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpAnalyzer.RecalculateSnapshot;
var
  UptimeMS: UInt64;
begin
  if FHasStarted then
    UptimeMS:=RtmpGetTickCount64 - FStartedAt
  else
    UptimeMS:=0;
  FSnapshot.StreamUptimeMS:=UptimeMS;

  if UptimeMS > 0 then
  begin
    FSnapshot.TotalBitrate:=(FTotalBytes * 8.0 * 1000.0) / UptimeMS;
    FSnapshot.AudioBitrate:=(FAudioBytes * 8.0 * 1000.0) / UptimeMS;
    FSnapshot.VideoBitrate:=(FVideoBytes * 8.0 * 1000.0) / UptimeMS;
    FSnapshot.PacketRate:=(FPacketCount * 1000.0) / UptimeMS;
  end
  else
  begin
    FSnapshot.TotalBitrate:=0.0;
    FSnapshot.AudioBitrate:=0.0;
    FSnapshot.VideoBitrate:=0.0;
    FSnapshot.PacketRate:=0.0;
  end;

  if FHasAudioTimestamp AND FHasVideoTimestamp then
    FSnapshot.DriftMS:=Integer(FLastAudioTimestamp) - Integer(FLastVideoTimestamp)
  else
    FSnapshot.DriftMS:=0;

  if (FVideoFrameCount > 1) AND FHasFirstVideoFrame AND
    (FLastVideoTimestamp > FFirstVideoFrameTimestamp) then
    FSnapshot.VideoFPS:=((FVideoFrameCount - 1) * 1000.0) /
      (FLastVideoTimestamp - FFirstVideoFrameTimestamp)
  else
    FSnapshot.VideoFPS:=0.0;

  if FVideoJitterSamples > 0 then
    FSnapshot.JitterMS:=Integer(FTotalJitterMS DIV FVideoJitterSamples)
  else
    FSnapshot.JitterMS:=0;
end;

procedure TRtmpAnalyzer.Reset;
begin
  FLock.Acquire;
  try
    FSnapshot:=Default(TRtmpAnalysisSnapshot);
    FStartedAt:=0;
    FHasStarted:=False;
    FPacketCount:=0;
    FTotalBytes:=0;
    FAudioBytes:=0;
    FVideoBytes:=0;
    FVideoFrameCount:=0;
    FVideoJitterSamples:=0;
    FTotalJitterMS:=0;
    FHasAudioTimestamp:=False;
    FHasVideoTimestamp:=False;
    FHasVideoArrivalTick:=False;
    FHasConfiguredAudio:=False;
    FHasFirstVideoFrame:=False;
    FHasKeyframe:=False;
    FConfiguredAudioSampleRate:=0;
    FConfiguredAudioChannels:=0;
    FFirstVideoFrameTimestamp:=0;
    FLastVideoArrivalTick:=0;
    FLastAudioTimestamp:=0;
    FLastVideoTimestamp:=0;
    FLastKeyframeTimestamp:=0;
  finally
    FLock.Release;
  end;
end;

end.

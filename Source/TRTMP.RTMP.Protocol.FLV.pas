unit TRTMP.RTMP.Protocol.FLV;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  TRTMP.RTMP.Protocol.Chunk,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Types;

type
  TRtmpFlvTrackInfo = record
    TrackID: Byte;
    CodecFourCC: string;
    DataOffset: Integer;
    DataSize: Integer;
    PayloadOffset: Integer;
    PayloadSize: Integer;
    CompositionTimeOffset: Integer;
  end;

  TRtmpFlvTrackInfoArray = array of TRtmpFlvTrackInfo;

  TRtmpFlvTagInfo = record
    IsAudio: Boolean;
    IsVideo: Boolean;
    IsMetadata: Boolean;
    IsKeyframe: Boolean;
    IsCodecConfig: Boolean;
    IsSequenceHeader: Boolean;
    IsEnhanced: Boolean;
    IsMultitrack: Boolean;
    IsModEx: Boolean;
    CodecFourCC: string;
    MultitrackType: Integer;
    ModExCount: Integer;
    HasTimestampNanoOffset: Boolean;
    TimestampNanoOffset: Integer;
    PayloadOffset: Integer;
    PayloadSize: Integer;
    TrackCount: Integer;
    Tracks: TRtmpFlvTrackInfoArray;
    AudioCodecID: Byte;
    AudioSampleRate: Integer;
    AudioChannels: Integer;
    AACPacketType: Integer;
    AudioPacketType: Integer;
    VideoCodecID: Byte;
    VideoFrameType: Byte;
    AVCPacketType: Integer;
    VideoPacketType: Integer;
    CompositionTimeOffset: Integer;
  end;

function RtmpInspectFlvTag(AMessageType: TRtmpMessageType;
  const APayload: TBytes; out AInfo: TRtmpFlvTagInfo): Boolean;
function RtmpPacketFlagsFromFlvTag(AMessageType: TRtmpMessageType;
  const AInfo: TRtmpFlvTagInfo; AHasExtendedTimestamp: Boolean): TRtmpPacketFlags;
function RtmpCreatePacketFromChunkMessage(const AMessage: TRtmpChunkMessage;
  ASequenceNo: UInt64): TRtmpPacket;

implementation

function FlvAudioSampleRate(ARateCode: Byte): Integer;
begin
  case ARateCode of
    0: Result:=5512;
    1: Result:=11025;
    2: Result:=22050;
    3: Result:=44100;
  else
    Result:=0;
  end;
end;

function SignExtend24(AValue: UInt32): Integer;
begin
  if (AValue AND $800000) <> 0 then
    Result:=Integer(AValue OR $FF000000)
  else
    Result:=Integer(AValue);
end;

function ReadFourCC(const ABytes: TBytes; AOffset: Integer): string;
var
  I: Integer;
begin
  Result:='';
  if (AOffset < 0) OR (AOffset + 4 > Length(ABytes)) then
    Exit;
  SetLength(Result, 4);
  for I:=0 to 3 do
    Result[I + 1]:=Char(ABytes[AOffset + I]);
end;

function ReadUI24(const ABytes: TBytes; AOffset: Integer;
  out AValue: Integer): Boolean;
begin
  Result:=(AOffset >= 0) AND (AOffset + 3 <= Length(ABytes));
  if NOT Result then
  begin
    AValue:=0;
    Exit;
  end;
  AValue:=(Integer(ABytes[AOffset]) SHL 16) OR
    (Integer(ABytes[AOffset + 1]) SHL 8) OR
    Integer(ABytes[AOffset + 2]);
end;

function ParseModExHeaders(const ABytes: TBytes; var AOffset,
  APacketType: Integer; var AInfo: TRtmpFlvTagInfo): Boolean;
var
  DataOffset: Integer;
  DataSize: Integer;
  ModExType: Integer;
  OptionByte: Byte;
  TimestampNano: Integer;
begin
  Result:=False;
  while APacketType = 7 do
  begin
    if AOffset >= Length(ABytes) then
      Exit;
    DataSize:=Integer(ABytes[AOffset]) + 1;
    Inc(AOffset);
    if DataSize = 256 then
    begin
      if AOffset + 2 > Length(ABytes) then
        Exit;
      DataSize:=(Integer(ABytes[AOffset]) SHL 8) OR
        Integer(ABytes[AOffset + 1]);
      Inc(DataSize);
      Inc(AOffset, 2);
    end;
    if (DataSize < 1) OR (AOffset + DataSize + 1 > Length(ABytes)) then
      Exit;

    DataOffset:=AOffset;
    Inc(AOffset, DataSize);
    OptionByte:=ABytes[AOffset];
    Inc(AOffset);
    ModExType:=(OptionByte SHR 4) AND $0F;
    APacketType:=OptionByte AND $0F;
    Inc(AInfo.ModExCount);
    AInfo.IsModEx:=True;

    if ModExType = 0 then
    begin
      if (DataSize < 3) OR
        (NOT ReadUI24(ABytes, DataOffset, TimestampNano)) OR
        (TimestampNano > 999999) then
        Exit;
      AInfo.HasTimestampNanoOffset:=True;
      AInfo.TimestampNanoOffset:=TimestampNano;
    end;
  end;
  Result:=True;
end;

function AddEnhancedTrack(const ABytes: TBytes; ATrackID: Byte;
  const AFourCC: string; ADataOffset, ADataSize: Integer; AIsVideo: Boolean;
  APacketType: Integer; var AInfo: TRtmpFlvTagInfo): Boolean;
var
  I: Integer;
  Track: TRtmpFlvTrackInfo;
  Value: Integer;
begin
  Result:=False;
  if (ADataOffset < 0) OR (ADataSize < 0) OR
    (ADataOffset + ADataSize > Length(ABytes)) then
    Exit;
  for I:=0 to AInfo.TrackCount - 1 do
    if AInfo.Tracks[I].TrackID = ATrackID then
      Exit;

  Track:=Default(TRtmpFlvTrackInfo);
  Track.TrackID:=ATrackID;
  Track.CodecFourCC:=AFourCC;
  Track.DataOffset:=ADataOffset;
  Track.DataSize:=ADataSize;
  Track.PayloadOffset:=ADataOffset;
  Track.PayloadSize:=ADataSize;
  if AIsVideo AND (APacketType = 1) AND
    ((AFourCC = 'hvc1') OR (AFourCC = 'avc1')) then
  begin
    if (ADataSize < 3) OR (NOT ReadUI24(ABytes, ADataOffset, Value)) then
      Exit;
    Track.CompositionTimeOffset:=SignExtend24(UInt32(Value));
    Inc(Track.PayloadOffset, 3);
    Dec(Track.PayloadSize, 3);
  end;

  SetLength(AInfo.Tracks, AInfo.TrackCount + 1);
  AInfo.Tracks[AInfo.TrackCount]:=Track;
  Inc(AInfo.TrackCount);
  Result:=True;
end;

function ParseEnhancedPayload(const ABytes: TBytes; AIsVideo: Boolean;
  var APacketType: Integer; var AInfo: TRtmpFlvTagInfo): Boolean;
const
  MULTITRACK_ONE = 0;
  MULTITRACK_MANY = 1;
  MULTITRACK_MANY_CODECS = 2;
var
  DataOffset: Integer;
  DataSize: Integer;
  FourCC: string;
  I: Integer;
  MultitrackPacketType: Integer;
  MultitrackSignal: Integer;
  Offset: Integer;
  SharedFourCC: string;
  TrackID: Byte;
begin
  Result:=False;
  Offset:=1;
  if NOT ParseModExHeaders(ABytes, Offset, APacketType, AInfo) then
    Exit;

  if AIsVideo then
    MultitrackSignal:=6
  else
    MultitrackSignal:=5;

  if APacketType = MultitrackSignal then
  begin
    if Offset >= Length(ABytes) then
      Exit;
    AInfo.IsMultitrack:=True;
    AInfo.MultitrackType:=(ABytes[Offset] SHR 4) AND $0F;
    MultitrackPacketType:=ABytes[Offset] AND $0F;
    Inc(Offset);
    if (AInfo.MultitrackType < MULTITRACK_ONE) OR
      (AInfo.MultitrackType > MULTITRACK_MANY_CODECS) OR
      (MultitrackPacketType = MultitrackSignal) OR
      (MultitrackPacketType = 7) then
      Exit;
    APacketType:=MultitrackPacketType;

    SharedFourCC:='';
    if AInfo.MultitrackType <> MULTITRACK_MANY_CODECS then
    begin
      if Offset + 4 > Length(ABytes) then
        Exit;
      SharedFourCC:=ReadFourCC(ABytes, Offset);
      Inc(Offset, 4);
    end;

    repeat
      FourCC:=SharedFourCC;
      if AInfo.MultitrackType = MULTITRACK_MANY_CODECS then
      begin
        if Offset + 4 > Length(ABytes) then
          Exit;
        FourCC:=ReadFourCC(ABytes, Offset);
        Inc(Offset, 4);
      end;
      if Offset >= Length(ABytes) then
        Exit;
      TrackID:=ABytes[Offset];
      Inc(Offset);

      if AInfo.MultitrackType = MULTITRACK_ONE then
        DataSize:=Length(ABytes) - Offset
      else
      begin
        if NOT ReadUI24(ABytes, Offset, DataSize) then
          Exit;
        Inc(Offset, 3);
      end;
      DataOffset:=Offset;
      if (DataSize < 0) OR (Offset + DataSize > Length(ABytes)) OR
        (NOT AddEnhancedTrack(ABytes, TrackID, FourCC, DataOffset,
          DataSize, AIsVideo, APacketType, AInfo)) then
        Exit;
      Inc(Offset, DataSize);
    until (AInfo.MultitrackType = MULTITRACK_ONE) OR
      (Offset = Length(ABytes));

    if (AInfo.TrackCount = 0) OR (Offset <> Length(ABytes)) then
      Exit;
    I:=0;
    while (I < AInfo.TrackCount) AND (AInfo.Tracks[I].TrackID <> 0) do
      Inc(I);
    if I >= AInfo.TrackCount then
      I:=0;
    AInfo.CodecFourCC:=AInfo.Tracks[I].CodecFourCC;
    AInfo.PayloadOffset:=AInfo.Tracks[I].PayloadOffset;
    AInfo.PayloadSize:=AInfo.Tracks[I].PayloadSize;
    AInfo.CompositionTimeOffset:=
      AInfo.Tracks[I].CompositionTimeOffset;
    Exit(True);
  end;

  if Offset + 4 > Length(ABytes) then
    Exit;
  AInfo.CodecFourCC:=ReadFourCC(ABytes, Offset);
  Inc(Offset, 4);
  AInfo.PayloadOffset:=Offset;
  if AIsVideo AND (APacketType = 1) AND
    ((AInfo.CodecFourCC = 'hvc1') OR
     (AInfo.CodecFourCC = 'avc1')) then
  begin
    if NOT ReadUI24(ABytes, Offset, DataSize) then
      Exit;
    AInfo.CompositionTimeOffset:=SignExtend24(UInt32(DataSize));
    Inc(AInfo.PayloadOffset, 3);
  end;
  AInfo.PayloadSize:=Length(ABytes) - AInfo.PayloadOffset;
  Result:=AInfo.PayloadOffset <= Length(ABytes);
end;

function RtmpInspectFlvTag(AMessageType: TRtmpMessageType;
  const APayload: TBytes; out AInfo: TRtmpFlvTagInfo): Boolean;
var
  Header: Byte;
begin
  Result:=False;
  AInfo:=Default(TRtmpFlvTagInfo);
  AInfo.AACPacketType:=-1;
  AInfo.AudioPacketType:=-1;
  AInfo.AVCPacketType:=-1;
  AInfo.VideoPacketType:=-1;

  case AMessageType of
    mtAudio:
      begin
        if Length(APayload) < 1 then
          Exit;

        Header:=APayload[0];
        AInfo.IsAudio:=True;
        AInfo.AudioCodecID:=(Header SHR 4) AND $0F;

        if AInfo.AudioCodecID = 9 then
        begin
          AInfo.IsEnhanced:=True;
          AInfo.AudioPacketType:=Header AND $0F;
          if NOT ParseEnhancedPayload(APayload, False,
            AInfo.AudioPacketType, AInfo) then
            Exit;
          if (AInfo.AudioPacketType = 3) OR
            (AInfo.AudioPacketType >= 5) then
            Exit;
          AInfo.AudioSampleRate:=0;
          AInfo.AudioChannels:=0;
          AInfo.IsCodecConfig:=AInfo.AudioPacketType = 0;
          AInfo.IsSequenceHeader:=AInfo.IsCodecConfig;
          Result:=True;
          Exit;
        end;

        AInfo.AudioSampleRate:=FlvAudioSampleRate((Header SHR 2) AND $03);
        if (Header AND $01) <> 0 then
          AInfo.AudioChannels:=2
        else
          AInfo.AudioChannels:=1;

        if (AInfo.AudioCodecID = 10) AND (Length(APayload) >= 2) then
        begin
          AInfo.AACPacketType:=APayload[1];
          AInfo.AudioPacketType:=AInfo.AACPacketType;
          AInfo.IsCodecConfig:=AInfo.AACPacketType = 0;
          AInfo.IsSequenceHeader:=AInfo.IsCodecConfig;
        end;
        Result:=True;
      end;
    mtVideo:
      begin
        if Length(APayload) < 1 then
          Exit;

        Header:=APayload[0];
        AInfo.IsVideo:=True;

        if (Header AND $80) <> 0 then
        begin
          AInfo.IsEnhanced:=True;
          AInfo.VideoFrameType:=(Header SHR 4) AND $07;
          AInfo.VideoPacketType:=Header AND $0F;
          if NOT ParseEnhancedPayload(APayload, True,
            AInfo.VideoPacketType, AInfo) then
            Exit;
          if AInfo.VideoPacketType >= 6 then
            Exit;
          AInfo.IsCodecConfig:=AInfo.VideoPacketType = 0;
          AInfo.IsSequenceHeader:=AInfo.IsCodecConfig;
          AInfo.IsKeyframe:=(AInfo.VideoFrameType = 1) AND
            (AInfo.VideoPacketType IN [0, 1, 3, 5]);
          Result:=True;
          Exit;
        end;

        AInfo.VideoFrameType:=(Header SHR 4) AND $0F;
        AInfo.VideoCodecID:=Header AND $0F;
        AInfo.IsKeyframe:=AInfo.VideoFrameType = 1;
        AInfo.AVCPacketType:=-1;
        AInfo.CompositionTimeOffset:=0;

        if (AInfo.VideoCodecID = 7) AND (Length(APayload) >= 5) then
        begin
          AInfo.AVCPacketType:=APayload[1];
          AInfo.VideoPacketType:=AInfo.AVCPacketType;
          AInfo.CompositionTimeOffset:=SignExtend24(
            (UInt32(APayload[2]) SHL 16) OR
            (UInt32(APayload[3]) SHL 8) OR
            UInt32(APayload[4]));
          AInfo.IsCodecConfig:=AInfo.AVCPacketType = 0;
          AInfo.IsSequenceHeader:=AInfo.IsCodecConfig;
        end;

        Result:=True;
      end;
    mtDataAMF0, mtDataAMF3:
      begin
        AInfo.IsMetadata:=True;
        Result:=True;
      end;
  end;
end;

function RtmpPacketFlagsFromFlvTag(AMessageType: TRtmpMessageType;
  const AInfo: TRtmpFlvTagInfo; AHasExtendedTimestamp: Boolean): TRtmpPacketFlags;
begin
  Result:=[];

  case AMessageType of
    mtAudio:
      Include(Result, pfIsAudio);
    mtVideo:
      Include(Result, pfIsVideo);
    mtDataAMF0, mtDataAMF3:
      Include(Result, pfIsMetadata);
  end;

  if AInfo.IsMetadata then
    Include(Result, pfIsMetadata);
  if AInfo.IsCodecConfig then
    Include(Result, pfIsCodecConfig);
  if AInfo.IsSequenceHeader then
    Include(Result, pfIsSequenceHeader);
  if AInfo.IsKeyframe then
    Include(Result, pfIsKeyframe);
  if AHasExtendedTimestamp then
    Include(Result, pfHasExtendedTimestamp);

  Include(Result, pfReconstructed);
end;

function RtmpCreatePacketFromChunkMessage(const AMessage: TRtmpChunkMessage;
  ASequenceNo: UInt64): TRtmpPacket;
var
  Info: TRtmpFlvTagInfo;
  Flags: TRtmpPacketFlags;
begin
  Info:=Default(TRtmpFlvTagInfo);
  RtmpInspectFlvTag(AMessage.MessageType, AMessage.Payload, Info);
  Flags:=RtmpPacketFlagsFromFlvTag(AMessage.MessageType, Info,
    AMessage.HasExtendedTimestamp);

  Result:=TRtmpPacket.Create(AMessage.MessageType, AMessage.Timestamp,
    AMessage.TimestampDelta, AMessage.MessageStreamID, AMessage.ChunkStreamID,
    TRtmpSharedPayload.Create(AMessage.Payload), Flags, ASequenceNo);
end;

end.

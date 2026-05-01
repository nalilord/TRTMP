unit RtmpFlv;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  RtmpChunkReassembler,
  RtmpPacket,
  RtmpTypes;

type
  TRtmpFlvTagInfo = record
    IsAudio: Boolean;
    IsVideo: Boolean;
    IsMetadata: Boolean;
    IsKeyframe: Boolean;
    IsCodecConfig: Boolean;
    IsSequenceHeader: Boolean;
    AudioCodecID: Byte;
    AudioSampleRate: Integer;
    AudioChannels: Integer;
    AACPacketType: Integer;
    VideoCodecID: Byte;
    VideoFrameType: Byte;
    AVCPacketType: Integer;
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
    0: Result := 5512;
    1: Result := 11025;
    2: Result := 22050;
    3: Result := 44100;
  else
    Result := 0;
  end;
end;

function SignExtend24(AValue: UInt32): Integer;
begin
  if (AValue and $800000) <> 0 then
    Result := Integer(AValue or $FF000000)
  else
    Result := Integer(AValue);
end;

function RtmpInspectFlvTag(AMessageType: TRtmpMessageType;
  const APayload: TBytes; out AInfo: TRtmpFlvTagInfo): Boolean;
var
  Header: Byte;
begin
  Result := False;
  AInfo := Default(TRtmpFlvTagInfo);

  case AMessageType of
    mtAudio:
      begin
        if Length(APayload) < 1 then
          Exit;

        Header := APayload[0];
        AInfo.IsAudio := True;
        AInfo.AudioCodecID := (Header shr 4) and $0F;
        AInfo.AudioSampleRate := FlvAudioSampleRate((Header shr 2) and $03);
        if (Header and $01) <> 0 then
          AInfo.AudioChannels := 2
        else
          AInfo.AudioChannels := 1;

        if (AInfo.AudioCodecID = 10) and (Length(APayload) >= 2) then
        begin
          AInfo.AACPacketType := APayload[1];
          AInfo.IsCodecConfig := AInfo.AACPacketType = 0;
          AInfo.IsSequenceHeader := AInfo.IsCodecConfig;
        end
        else
          AInfo.AACPacketType := -1;

        Result := True;
      end;
    mtVideo:
      begin
        if Length(APayload) < 1 then
          Exit;

        Header := APayload[0];
        AInfo.IsVideo := True;
        AInfo.VideoFrameType := (Header shr 4) and $0F;
        AInfo.VideoCodecID := Header and $0F;
        AInfo.IsKeyframe := AInfo.VideoFrameType = 1;
        AInfo.AVCPacketType := -1;
        AInfo.CompositionTimeOffset := 0;

        if (AInfo.VideoCodecID = 7) and (Length(APayload) >= 5) then
        begin
          AInfo.AVCPacketType := APayload[1];
          AInfo.CompositionTimeOffset := SignExtend24(
            (UInt32(APayload[2]) shl 16) or
            (UInt32(APayload[3]) shl 8) or
            UInt32(APayload[4]));
          AInfo.IsCodecConfig := AInfo.AVCPacketType = 0;
          AInfo.IsSequenceHeader := AInfo.IsCodecConfig;
        end;

        Result := True;
      end;
    mtDataAMF0, mtDataAMF3:
      begin
        AInfo.IsMetadata := True;
        Result := True;
      end;
  end;
end;

function RtmpPacketFlagsFromFlvTag(AMessageType: TRtmpMessageType;
  const AInfo: TRtmpFlvTagInfo; AHasExtendedTimestamp: Boolean): TRtmpPacketFlags;
begin
  Result := [];

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
  Info := Default(TRtmpFlvTagInfo);
  RtmpInspectFlvTag(AMessage.MessageType, AMessage.Payload, Info);
  Flags := RtmpPacketFlagsFromFlvTag(AMessage.MessageType, Info,
    AMessage.HasExtendedTimestamp);

  Result := TRtmpPacket.Create(AMessage.MessageType, AMessage.Timestamp,
    AMessage.TimestampDelta, AMessage.MessageStreamID, AMessage.ChunkStreamID,
    TRtmpSharedPayload.Create(AMessage.Payload), Flags, ASequenceNo);
end;

end.

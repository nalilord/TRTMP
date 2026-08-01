unit TRTMP.RTMP.Decode;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

type
  TRtmpDecoderMediaKind = (
    dmUnknown,
    dmAudio,
    dmVideo
  );

  TRtmpDecoderCodec = (
    dcUnknown,
    dcAAC,
    dcAVC,
    dcHEVC,
    dcOpus,
    dcAV1,
    dcVP9,
    dcFLAC,
    dcAC3,
    dcEAC3
  );

  TRtmpDecodedFrameInfo = record
    MediaKind: TRtmpDecoderMediaKind;
    Codec: TRtmpDecoderCodec;
    TrackID: Integer;
    TimestampMS: Int64;
    TimestampNS: Int64;
    TimestampNanoOffset: Integer;
    IsKeyframe: Boolean;
    Width: Integer;
    Height: Integer;
    SampleRate: Integer;
    Channels: Integer;
    SampleCount: Integer;
    FormatCode: Integer;
  end;

function RtmpDecoderMediaKindName(AMediaKind: TRtmpDecoderMediaKind): string;
function RtmpDecoderCodecName(ACodec: TRtmpDecoderCodec): string;

implementation

function RtmpDecoderMediaKindName(AMediaKind: TRtmpDecoderMediaKind): string;
begin
  case AMediaKind of
    dmAudio: Result:='audio';
    dmVideo: Result:='video';
  else
    Result:='unknown';
  end;
end;

function RtmpDecoderCodecName(ACodec: TRtmpDecoderCodec): string;
begin
  case ACodec of
    dcAAC: Result:='AAC';
    dcAVC: Result:='AVC';
    dcHEVC: Result:='HEVC';
    dcOpus: Result:='Opus';
    dcAV1: Result:='AV1';
    dcVP9: Result:='VP9';
    dcFLAC: Result:='FLAC';
    dcAC3: Result:='AC-3';
    dcEAC3: Result:='E-AC-3';
  else
    Result:='Unknown';
  end;
end;

end.

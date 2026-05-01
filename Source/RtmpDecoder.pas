unit RtmpDecoder;

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
    dcAVC
  );

  TRtmpDecodedFrameInfo = record
    MediaKind: TRtmpDecoderMediaKind;
    Codec: TRtmpDecoderCodec;
    TimestampMS: Int64;
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
    dmAudio: Result := 'audio';
    dmVideo: Result := 'video';
  else
    Result := 'unknown';
  end;
end;

function RtmpDecoderCodecName(ACodec: TRtmpDecoderCodec): string;
begin
  case ACodec of
    dcAAC: Result := 'AAC';
    dcAVC: Result := 'AVC';
  else
    Result := 'Unknown';
  end;
end;

end.

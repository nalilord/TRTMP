unit RtmpFFmpegApi;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  libavcodec,
  libavcodec_codec,
  libavcodec_codec_defs,
  libavcodec_codec_id,
  libavcodec_packet,
  libavutil,
  libavutil_error,
  libavutil_frame,
  libavutil_mem;

type
  TRtmpFFmpegApi = class
  public
    class function AllocDecoderContext(ACodec: PAVCodec): PAVCodecContext; static;
    class function AllocFrame: PAVFrame; static;
    class function AllocPacket: PAVPacket; static;
    class function FindDecoder(AID: TAVCodecID): PAVCodec; static;
    class procedure FlushDecoder(AContext: PAVCodecContext); static;
    class procedure FreeDecoderContext(var AContext: PAVCodecContext); static;
    class procedure FreeFrame(var AFrame: PAVFrame); static;
    class procedure FreePacket(var APacket: PAVPacket); static;
    class function LoadExtradata(AContext: PAVCodecContext;
      const AData: TBytes): Integer; static;
    class function LoadPacketBytes(APacket: PAVPacket; const AData: TBytes;
      AOffset: Integer; ATimestampMS: Int64; ADurationMS: Integer;
      AKeyframe: Boolean): Integer; static;
    class function OpenDecoder(AContext: PAVCodecContext; ACodec: PAVCodec): Integer; static;
    class function ReceiveFrame(AContext: PAVCodecContext; AFrame: PAVFrame): Integer; static;
    class function SendFlushPacket(AContext: PAVCodecContext): Integer; static;
    class function SendPacket(AContext: PAVCodecContext; APacket: PAVPacket): Integer; static;
    class procedure UnrefFrame(AFrame: PAVFrame); static;
    class procedure UnrefPacket(APacket: PAVPacket); static;
  end;

implementation

class function TRtmpFFmpegApi.AllocDecoderContext(ACodec: PAVCodec): PAVCodecContext;
begin
  Result := avcodec_alloc_context3(ACodec);
end;

class function TRtmpFFmpegApi.AllocFrame: PAVFrame;
begin
  Result := av_frame_alloc();
end;

class function TRtmpFFmpegApi.AllocPacket: PAVPacket;
begin
  Result := av_packet_alloc();
end;

class function TRtmpFFmpegApi.FindDecoder(AID: TAVCodecID): PAVCodec;
begin
  Result := avcodec_find_decoder(AID);
end;

class procedure TRtmpFFmpegApi.FlushDecoder(AContext: PAVCodecContext);
begin
  if Assigned(AContext) then
    avcodec_flush_buffers(AContext);
end;

class procedure TRtmpFFmpegApi.FreeDecoderContext(var AContext: PAVCodecContext);
begin
  avcodec_free_context(@AContext);
end;

class procedure TRtmpFFmpegApi.FreeFrame(var AFrame: PAVFrame);
begin
  av_frame_free(@AFrame);
end;

class procedure TRtmpFFmpegApi.FreePacket(var APacket: PAVPacket);
begin
  av_packet_free(@APacket);
end;

class function TRtmpFFmpegApi.LoadExtradata(AContext: PAVCodecContext;
  const AData: TBytes): Integer;
var
  Buffer: PByte;
begin
  if not Assigned(AContext) then
    Exit(AVERROR_EINVAL);

  if Assigned(AContext^.extradata) then
    av_free(AContext^.extradata);
  AContext^.extradata := nil;
  AContext^.extradata_size := 0;

  if Length(AData) = 0 then
    Exit(0);

  Buffer := av_mallocz(Length(AData) + AV_INPUT_BUFFER_PADDING_SIZE);
  if not Assigned(Buffer) then
    Exit(AVERROR_ENOMEM);

  Move(AData[0], Buffer^, Length(AData));
  AContext^.extradata := Buffer;
  AContext^.extradata_size := Length(AData);
  Result := 0;
end;

class function TRtmpFFmpegApi.LoadPacketBytes(APacket: PAVPacket; const AData: TBytes;
  AOffset: Integer; ATimestampMS: Int64; ADurationMS: Integer;
  AKeyframe: Boolean): Integer;
var
  Buffer: PByte;
  PacketSize: Integer;
begin
  if not Assigned(APacket) then
    Exit(AVERROR_EINVAL);
  if (AOffset < 0) or (AOffset > Length(AData)) then
    Exit(AVERROR_EINVAL);

  av_packet_unref(APacket);

  PacketSize := Length(AData) - AOffset;
  if PacketSize < 0 then
    Exit(AVERROR_EINVAL);

  Buffer := av_mallocz(PacketSize + AV_INPUT_BUFFER_PADDING_SIZE);
  if not Assigned(Buffer) then
    Exit(AVERROR_ENOMEM);

  if PacketSize > 0 then
    Move(AData[AOffset], Buffer^, PacketSize);

  Result := av_packet_from_data(APacket, Buffer, PacketSize);
  if Result < 0 then
  begin
    av_free(Buffer);
    Exit;
  end;

  APacket^.pts := ATimestampMS;
  APacket^.dts := ATimestampMS;
  APacket^.duration := ADurationMS;
  APacket^.time_base.num := 1;
  APacket^.time_base.den := 1000;
  if AKeyframe then
    APacket^.flags := APacket^.flags or AV_PKT_FLAG_KEY;
end;

class function TRtmpFFmpegApi.OpenDecoder(AContext: PAVCodecContext; ACodec: PAVCodec): Integer;
begin
  Result := avcodec_open2(AContext, ACodec, nil);
end;

class function TRtmpFFmpegApi.ReceiveFrame(AContext: PAVCodecContext; AFrame: PAVFrame): Integer;
begin
  Result := avcodec_receive_frame(AContext, AFrame);
end;

class function TRtmpFFmpegApi.SendFlushPacket(AContext: PAVCodecContext): Integer;
begin
  Result := avcodec_send_packet(AContext, nil);
end;

class function TRtmpFFmpegApi.SendPacket(AContext: PAVCodecContext; APacket: PAVPacket): Integer;
begin
  Result := avcodec_send_packet(AContext, APacket);
end;

class procedure TRtmpFFmpegApi.UnrefFrame(AFrame: PAVFrame);
begin
  av_frame_unref(AFrame);
end;

class procedure TRtmpFFmpegApi.UnrefPacket(APacket: PAVPacket);
begin
  av_packet_unref(APacket);
end;

end.

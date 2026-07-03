unit RtmpDecoderFFmpeg;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  libavcodec,
  libavcodec_codec,
  libavcodec_codec_id,
  libavcodec_packet,
  libavutil,
  libavutil_buffer,
  libavutil_error,
  libavutil_frame,
  libavutil_hwcontext,
  libavutil_pixfmt,
  RtmpDecoder,
  RtmpFFmpeg,
  RtmpFFmpegApi,
  RtmpPacket,
  RtmpTypes;

type
  TRtmpDecoderThreadMode = (
    dtmAuto,
    dtmSlice,
    dtmFrame
  );

  TRtmpDecoderHardwareMode = (
    dhmAuto,
    dhmOff,
    dhmVaapi,
    dhmQsv,
    dhmV4L2Request,
    dhmDrm
  );

  TRtmpFFmpegPacketDecoder = class
  private
    FCodec: PAVCodec;
    FCodecContext: PAVCodecContext;
    FCodecKind: TRtmpDecoderCodec;
    FDecodeFrame: PAVFrame;
    FFrame: PAVFrame;
    FHardwareDecodeActive: Boolean;
    FHardwareDecodeEnabled: Boolean;
    FHardwareDeviceCtx: PAVBufferRef;
    FHardwareMode: TRtmpDecoderHardwareMode;
    FHardwareDeviceName: string;
    FHardwarePixelFormat: TAVPixelFormat;
    FIsOpen: Boolean;
    FLastErrorCode: Integer;
    FLastErrorText: string;
    FMediaKind: TRtmpDecoderMediaKind;
    FNaluLengthSize: Integer;
    FPacket: PAVPacket;
    FPassthroughHardwareFrames: Boolean;
    FThreadCount: Integer;
    FThreadMode: TRtmpDecoderThreadMode;
    function ConvertAvccToAnnexB(const AData: TBytes; AOffset: Integer;
      out AConverted: TBytes): Boolean;
    {$IFDEF UNIX}
    function ActivateLinuxHardwareDecode: Boolean;
    function TryActivateLinuxHardwareDecode(const ADeviceName,
      APreferredDevice: AnsiString): Boolean;
    function TryCreateHardwareDevice(ADeviceType: TAVHWDeviceType;
      const APreferredDevice: AnsiString): Boolean;
    function SupportsLinuxHardwareDecode(ADeviceType: TAVHWDeviceType;
      out APixelFormat: TAVPixelFormat): Boolean;
    {$ENDIF}
    function CodecIDForKind(ACodecKind: TRtmpDecoderCodec): TAVCodecID;
    function PreferredDecoderName(AMediaKind: TRtmpDecoderMediaKind;
      ACodecKind: TRtmpDecoderCodec): AnsiString;
    function HandleHardwareFrameTransfer: Integer;
    function MapHardwareFrameToDrmPrime: Integer;
    procedure ResetError;
    procedure ResetHardwareDecode;
    function SelectPixelFormat(const AFmt: PAVPixelFormat): TAVPixelFormat;
    procedure SetError(AErrorCode: Integer; const AMessage: string = '');
    function TryExtractCodecConfig(const APacket: TRtmpPacket;
      out AMediaKind: TRtmpDecoderMediaKind; out ACodecKind: TRtmpDecoderCodec;
      out AExtradata: TBytes): Boolean;
    function TryExtractPacketPayload(const APacket: TRtmpPacket; out AOffset: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Close;
    function OpenFromConfig(const APacket: TRtmpPacket): Boolean;
    function ReceiveFrame(out AInfo: TRtmpDecodedFrameInfo): Integer;
    function SubmitPacket(const APacket: TRtmpPacket): Integer;
    procedure Flush;
    procedure UnrefFrame;

    property CodecContext: PAVCodecContext read FCodecContext;
    property CodecKind: TRtmpDecoderCodec read FCodecKind;
    property Frame: PAVFrame read FFrame;
    property HardwareDeviceName: string read FHardwareDeviceName;
    property HardwareMode: TRtmpDecoderHardwareMode read FHardwareMode write FHardwareMode;
    property IsOpen: Boolean read FIsOpen;
    property LastErrorCode: Integer read FLastErrorCode;
    property LastErrorText: string read FLastErrorText;
    property MediaKind: TRtmpDecoderMediaKind read FMediaKind;
    property PassthroughHardwareFrames: Boolean read FPassthroughHardwareFrames
      write FPassthroughHardwareFrames;
    property ThreadCount: Integer read FThreadCount write FThreadCount;
    property ThreadMode: TRtmpDecoderThreadMode read FThreadMode write FThreadMode;
  end;

implementation

{$IFDEF UNIX}
uses
  FfmpegLinuxV4L2RequestTypes;
{$ENDIF}

function RtmpDecoderGetFormat(s: PAVCodecContext; const fmt: PAVPixelFormat): TAVPixelFormat; cdecl;
var
  Decoder: TRtmpFFmpegPacketDecoder;
begin
  if Assigned(s) and Assigned(s^.opaque) then
  begin
    Decoder := TRtmpFFmpegPacketDecoder(s^.opaque);
    Result := Decoder.SelectPixelFormat(fmt);
    Exit;
  end;
  Result := avcodec_default_get_format(s, fmt);
end;

constructor TRtmpFFmpegPacketDecoder.Create;
begin
  inherited Create;
  FCodec := nil;
  FCodecContext := nil;
  FPacket := TRtmpFFmpegApi.AllocPacket;
  FFrame := TRtmpFFmpegApi.AllocFrame;
  FDecodeFrame := TRtmpFFmpegApi.AllocFrame;
  FHardwareDecodeActive := False;
  FHardwareDecodeEnabled := False;
  FHardwareDeviceCtx := nil;
  FHardwareMode := dhmAuto;
  FHardwareDeviceName := '';
  FHardwarePixelFormat := AV_PIX_FMT_NONE;
  FMediaKind := dmUnknown;
  FCodecKind := dcUnknown;
  FNaluLengthSize := 4;
  FPassthroughHardwareFrames := False;
  FThreadCount := 1;
  FThreadMode := dtmAuto;
  FIsOpen := False;
  ResetError;
end;

destructor TRtmpFFmpegPacketDecoder.Destroy;
begin
  Close;
  TRtmpFFmpegApi.FreeFrame(FDecodeFrame);
  TRtmpFFmpegApi.FreeFrame(FFrame);
  TRtmpFFmpegApi.FreePacket(FPacket);
  inherited Destroy;
end;

procedure TRtmpFFmpegPacketDecoder.Close;
begin
  FIsOpen := False;
  FCodec := nil;
  FMediaKind := dmUnknown;
  FCodecKind := dcUnknown;
  FNaluLengthSize := 4;
  if Assigned(FDecodeFrame) then
    TRtmpFFmpegApi.UnrefFrame(FDecodeFrame);
  if Assigned(FFrame) then
    TRtmpFFmpegApi.UnrefFrame(FFrame);
  if Assigned(FPacket) then
    TRtmpFFmpegApi.UnrefPacket(FPacket);
  ResetHardwareDecode;
  if Assigned(FCodecContext) then
    TRtmpFFmpegApi.FreeDecoderContext(FCodecContext);
end;

function TRtmpFFmpegPacketDecoder.ConvertAvccToAnnexB(const AData: TBytes;
  AOffset: Integer; out AConverted: TBytes): Boolean;
  function Fail(const AReason: string): Boolean;
  begin
    FLastErrorText := AReason;
    Result := False;
  end;
var
  InputIndex: Integer;
  NaluLength: UInt32;
  OutputIndex: Integer;
  SizeFieldIndex: Integer;
begin
  Result := False;
  AConverted := nil;

  if (FNaluLengthSize < 1) or (FNaluLengthSize > 4) then
    Exit(Fail(Format('Invalid NALU length size %d', [FNaluLengthSize])));
  if (AOffset < 0) or (AOffset > Length(AData)) then
    Exit(Fail(Format('Invalid AVC payload offset %d for %d-byte buffer',
      [AOffset, Length(AData)])));

  SetLength(AConverted, Length(AData) - AOffset + ((Length(AData) - AOffset) div 16 + 1) * 4);
  OutputIndex := 0;
  InputIndex := AOffset;
  while InputIndex < Length(AData) do
  begin
    if (Length(AData) - InputIndex) < FNaluLengthSize then
      Exit(Fail(Format('Truncated AVC length field at byte %d', [InputIndex - AOffset])));

    NaluLength := 0;
    for SizeFieldIndex := 0 to FNaluLengthSize - 1 do
      NaluLength := (NaluLength shl 8) or UInt32(AData[InputIndex + SizeFieldIndex]);
    Inc(InputIndex, FNaluLengthSize);

    if (NaluLength = 0) or (UInt32(Length(AData) - InputIndex) < NaluLength) then
      Exit(Fail(Format('Invalid AVC NALU length %d at byte %d with %d bytes remaining',
        [NaluLength, InputIndex - AOffset - FNaluLengthSize, Length(AData) - InputIndex])));

    if (Length(AConverted) - OutputIndex) < Integer(NaluLength) + 4 then
      SetLength(AConverted, OutputIndex + Integer(NaluLength) + 4);

    AConverted[OutputIndex] := 0;
    AConverted[OutputIndex + 1] := 0;
    AConverted[OutputIndex + 2] := 0;
    AConverted[OutputIndex + 3] := 1;
    Inc(OutputIndex, 4);

    Move(AData[InputIndex], AConverted[OutputIndex], Integer(NaluLength));
    Inc(OutputIndex, Integer(NaluLength));
    Inc(InputIndex, Integer(NaluLength));
  end;

  SetLength(AConverted, OutputIndex);
  Result := OutputIndex > 0;
end;

function TRtmpFFmpegPacketDecoder.CodecIDForKind(
  ACodecKind: TRtmpDecoderCodec): TAVCodecID;
begin
  case ACodecKind of
    dcAAC: Result := AV_CODEC_ID_AAC;
    dcAVC: Result := AV_CODEC_ID_H264;
  else
    Result := AV_CODEC_ID_NONE;
  end;
end;

function TRtmpFFmpegPacketDecoder.PreferredDecoderName(
  AMediaKind: TRtmpDecoderMediaKind; ACodecKind: TRtmpDecoderCodec): AnsiString;
begin
  Result := '';
  if (AMediaKind <> dmVideo) or (ACodecKind <> dcAVC) then
    Exit;

  case FHardwareMode of
    dhmQsv:
      Result := '';
  end;
end;

procedure TRtmpFFmpegPacketDecoder.Flush;
begin
  if not Assigned(FCodecContext) then
    Exit;
  TRtmpFFmpegApi.SendFlushPacket(FCodecContext);
  TRtmpFFmpegApi.FlushDecoder(FCodecContext);
  if Assigned(FDecodeFrame) then
    TRtmpFFmpegApi.UnrefFrame(FDecodeFrame);
  if Assigned(FFrame) then
    TRtmpFFmpegApi.UnrefFrame(FFrame);
end;

{$IFDEF UNIX}
function TRtmpFFmpegPacketDecoder.ActivateLinuxHardwareDecode: Boolean;
begin
  case FHardwareMode of
    dhmOff:
      Result := False;
    dhmVaapi:
      Result := TryActivateLinuxHardwareDecode('vaapi', '/dev/dri/renderD128');
    dhmQsv:
      Result := TryActivateLinuxHardwareDecode('qsv', '');
    dhmV4L2Request:
      Result := TryActivateLinuxHardwareDecode('v4l2request', '');
    dhmDrm:
      Result := TryActivateLinuxHardwareDecode('drm', '/dev/dri/renderD128');
  else
    Result :=
      TryActivateLinuxHardwareDecode('vaapi', '/dev/dri/renderD128') or
      TryActivateLinuxHardwareDecode('qsv', '') or
      TryActivateLinuxHardwareDecode('v4l2request', '') or
      TryActivateLinuxHardwareDecode('drm', '/dev/dri/renderD128');
  end;
end;

function TRtmpFFmpegPacketDecoder.TryActivateLinuxHardwareDecode(
  const ADeviceName, APreferredDevice: AnsiString): Boolean;
var
  DeviceType: TAVHWDeviceType;
  PixelFormat: TAVPixelFormat;
begin
  Result := False;

  DeviceType := av_hwdevice_find_type_by_name(PAnsiChar(ADeviceName));
  if Ord(DeviceType) = Ord(AV_HWDEVICE_TYPE_NONE) then
    Exit;
  if not SupportsLinuxHardwareDecode(DeviceType, PixelFormat) then
    Exit;
  if not TryCreateHardwareDevice(DeviceType, APreferredDevice) then
    Exit;

  FCodecContext^.hw_device_ctx := av_buffer_ref(FHardwareDeviceCtx);
  if not Assigned(FCodecContext^.hw_device_ctx) then
  begin
    av_buffer_unref(@FHardwareDeviceCtx);
    Exit;
  end;

  FCodecContext^.opaque := Self;
  FCodecContext^.get_format := @RtmpDecoderGetFormat;
  FHardwarePixelFormat := PixelFormat;
  FHardwareDeviceName := string(ADeviceName);
  FHardwareDecodeEnabled := True;
  Result := True;
end;

function TRtmpFFmpegPacketDecoder.TryCreateHardwareDevice(
  ADeviceType: TAVHWDeviceType; const APreferredDevice: AnsiString): Boolean;
var
  ErrorCode: Integer;
begin
  Result := False;

  if Assigned(FHardwareDeviceCtx) then
    av_buffer_unref(@FHardwareDeviceCtx);

  if APreferredDevice <> '' then
  begin
    ErrorCode := av_hwdevice_ctx_create(@FHardwareDeviceCtx, ADeviceType,
      PAnsiChar(APreferredDevice), nil, 0);
    if ErrorCode >= 0 then
      Exit(True);

    if Assigned(FHardwareDeviceCtx) then
      av_buffer_unref(@FHardwareDeviceCtx);
  end;

  ErrorCode := av_hwdevice_ctx_create(@FHardwareDeviceCtx, ADeviceType, nil, nil, 0);
  Result := ErrorCode >= 0;
  if (not Result) and Assigned(FHardwareDeviceCtx) then
    av_buffer_unref(@FHardwareDeviceCtx);
end;
{$ENDIF}

function TRtmpFFmpegPacketDecoder.OpenFromConfig(const APacket: TRtmpPacket): Boolean;
var
  CodecID: TAVCodecID;
  Extradata: TBytes;
  MediaKind: TRtmpDecoderMediaKind;
  CodecKind: TRtmpDecoderCodec;
  DecoderName: AnsiString;
begin
  Result := False;
  ResetError;

  if not TryExtractCodecConfig(APacket, MediaKind, CodecKind, Extradata) then
  begin
    SetError(AVERROR_EINVAL, 'Packet is not a supported codec-config message');
    Exit;
  end;

  CodecID := CodecIDForKind(CodecKind);
  if CodecID = AV_CODEC_ID_NONE then
  begin
    SetError(AVERROR_DECODER_NOT_FOUND, 'No decoder mapping for codec');
    Exit;
  end;

  Close;

  DecoderName := PreferredDecoderName(MediaKind, CodecKind);
  if DecoderName <> '' then
    FCodec := TRtmpFFmpegApi.FindDecoderByName(DecoderName)
  else
    FCodec := nil;
  if not Assigned(FCodec) then
    FCodec := TRtmpFFmpegApi.FindDecoder(CodecID);
  if not Assigned(FCodec) then
  begin
    SetError(AVERROR_DECODER_NOT_FOUND, 'Decoder not found');
    Exit;
  end;

  FCodecContext := TRtmpFFmpegApi.AllocDecoderContext(FCodec);
  if not Assigned(FCodecContext) then
  begin
    SetError(AVERROR_ENOMEM, 'Failed to allocate decoder context');
    Exit;
  end;

  FCodecContext^.codec_id := CodecID;
  FCodecContext^.pkt_timebase.num := 1;
  FCodecContext^.pkt_timebase.den := 1000;
  if FThreadCount > 0 then
    FCodecContext^.thread_count := FThreadCount
  else
    FCodecContext^.thread_count := 1;
  case FThreadMode of
    dtmSlice:
      FCodecContext^.thread_type := FF_THREAD_SLICE;
    dtmFrame:
      FCodecContext^.thread_type := FF_THREAD_FRAME;
  else
    FCodecContext^.thread_type := FF_THREAD_SLICE or FF_THREAD_FRAME;
  end;
  FCodecContext^.flags := FCodecContext^.flags or AV_CODEC_FLAG_LOW_DELAY;
  FCodecContext^.flags2 := FCodecContext^.flags2 or AV_CODEC_FLAG2_FAST;

  {$IFDEF UNIX}
  if MediaKind = dmVideo then
    ActivateLinuxHardwareDecode;
  {$ENDIF}
  if not FHardwareDecodeEnabled then
    FCodecContext^.flags2 := FCodecContext^.flags2 or AV_CODEC_FLAG2_CHUNKS;

  FLastErrorCode := TRtmpFFmpegApi.LoadExtradata(FCodecContext, Extradata);
  if FLastErrorCode < 0 then
  begin
    SetError(FLastErrorCode, 'Failed to load codec extradata');
    Close;
    Exit;
  end;

  FLastErrorCode := TRtmpFFmpegApi.OpenDecoder(FCodecContext, FCodec);
  if FLastErrorCode < 0 then
  begin
    SetError(FLastErrorCode, 'Failed to open decoder');
    Close;
    Exit;
  end;

  FMediaKind := MediaKind;
  FCodecKind := CodecKind;
  if (CodecKind = dcAVC) and (Length(Extradata) >= 5) then
    FNaluLengthSize := (Extradata[4] and $03) + 1
  else
    FNaluLengthSize := 4;
  FIsOpen := True;
  Result := True;
end;

function TRtmpFFmpegPacketDecoder.ReceiveFrame(
  out AInfo: TRtmpDecodedFrameInfo): Integer;
var
  DecodeFrame: PAVFrame;
begin
  AInfo := Default(TRtmpDecodedFrameInfo);
  if not Assigned(FCodecContext) then
  begin
    SetError(AVERROR_EINVAL, 'Decoder is not open');
    Exit(FLastErrorCode);
  end;

  if FHardwareDecodeEnabled then
    DecodeFrame := FDecodeFrame
  else
    DecodeFrame := FFrame;

  Result := TRtmpFFmpegApi.ReceiveFrame(FCodecContext, DecodeFrame);
  if Result < 0 then
  begin
    if (Result <> AVERROR_EAGAIN) and (Result <> AVERROR_EOF) then
      SetError(Result, 'Failed to receive decoded frame');
    Exit;
  end;

  if FHardwareDecodeEnabled then
  begin
    if FHardwareDecodeActive then
    begin
      if FPassthroughHardwareFrames then
      begin
        TRtmpFFmpegApi.UnrefFrame(FFrame);
        if FDecodeFrame^.format = Ord(AV_PIX_FMT_DRM_PRIME) then
          av_frame_move_ref(FFrame, FDecodeFrame)
        else
        begin
          Result := MapHardwareFrameToDrmPrime;
          if Result < 0 then
          begin
            SetError(Result, 'Failed to map hardware decoded frame to DRM_PRIME');
            Exit;
          end;
        end;
      end
      else
      begin
        Result := HandleHardwareFrameTransfer;
        if Result < 0 then
        begin
          SetError(Result, 'Failed to transfer hardware decoded frame');
          Exit;
        end;
      end;
    end
    else
    begin
      TRtmpFFmpegApi.UnrefFrame(FFrame);
      av_frame_move_ref(FFrame, FDecodeFrame);
    end;
  end;

  AInfo.MediaKind := FMediaKind;
  AInfo.Codec := FCodecKind;
  if FFrame^.best_effort_timestamp <> AV_NOPTS_VALUE then
    AInfo.TimestampMS := FFrame^.best_effort_timestamp
  else if FFrame^.pts <> AV_NOPTS_VALUE then
    AInfo.TimestampMS := FFrame^.pts
  else
    AInfo.TimestampMS := 0;
  AInfo.IsKeyframe := (FFrame^.flags and AV_FRAME_FLAG_KEY) <> 0;
  AInfo.Width := FFrame^.width;
  AInfo.Height := FFrame^.height;
  AInfo.SampleRate := FFrame^.sample_rate;
  AInfo.Channels := FFrame^.ch_layout.nb_channels;
  AInfo.SampleCount := FFrame^.nb_samples;
  AInfo.FormatCode := FFrame^.format;
end;

function TRtmpFFmpegPacketDecoder.HandleHardwareFrameTransfer: Integer;
begin
  TRtmpFFmpegApi.UnrefFrame(FFrame);
  FFrame^.format := Ord(AV_PIX_FMT_NONE);
  FFrame^.width := FDecodeFrame^.width;
  FFrame^.height := FDecodeFrame^.height;

  Result := av_hwframe_transfer_data(FFrame, FDecodeFrame, 0);
  if Result < 0 then
    Exit;

  Result := av_frame_copy_props(FFrame, FDecodeFrame);
  if Result < 0 then
  begin
    TRtmpFFmpegApi.UnrefFrame(FFrame);
    Exit;
  end;

  FFrame^.pts := FDecodeFrame^.pts;
  FFrame^.pkt_dts := FDecodeFrame^.pkt_dts;
  FFrame^.best_effort_timestamp := FDecodeFrame^.best_effort_timestamp;
  FFrame^.flags := FDecodeFrame^.flags;
  FFrame^.sample_rate := FDecodeFrame^.sample_rate;
  FFrame^.ch_layout := FDecodeFrame^.ch_layout;
  FFrame^.nb_samples := FDecodeFrame^.nb_samples;
end;

function TRtmpFFmpegPacketDecoder.MapHardwareFrameToDrmPrime: Integer;
begin
  TRtmpFFmpegApi.UnrefFrame(FFrame);
  FFrame^.format := Ord(AV_PIX_FMT_DRM_PRIME);
  FFrame^.width := FDecodeFrame^.width;
  FFrame^.height := FDecodeFrame^.height;

  Result := av_hwframe_map(FFrame, FDecodeFrame,
    Ord(AV_HWFRAME_MAP_READ) or Ord(AV_HWFRAME_MAP_DIRECT));
  if Result < 0 then
  begin
    TRtmpFFmpegApi.UnrefFrame(FFrame);
    Exit;
  end;

  Result := av_frame_copy_props(FFrame, FDecodeFrame);
  if Result < 0 then
  begin
    TRtmpFFmpegApi.UnrefFrame(FFrame);
    Exit;
  end;

  FFrame^.pts := FDecodeFrame^.pts;
  FFrame^.pkt_dts := FDecodeFrame^.pkt_dts;
  FFrame^.best_effort_timestamp := FDecodeFrame^.best_effort_timestamp;
  FFrame^.flags := FDecodeFrame^.flags;
  FFrame^.sample_rate := FDecodeFrame^.sample_rate;
  FFrame^.ch_layout := FDecodeFrame^.ch_layout;
  FFrame^.nb_samples := FDecodeFrame^.nb_samples;
end;

procedure TRtmpFFmpegPacketDecoder.ResetError;
begin
  FLastErrorCode := 0;
  FLastErrorText := '';
end;

procedure TRtmpFFmpegPacketDecoder.ResetHardwareDecode;
begin
  FHardwareDecodeActive := False;
  FHardwareDecodeEnabled := False;
  FHardwareDeviceName := '';
  FHardwarePixelFormat := AV_PIX_FMT_NONE;
  if Assigned(FCodecContext) then
  begin
    FCodecContext^.get_format := nil;
    FCodecContext^.opaque := nil;
    if Assigned(FCodecContext^.hw_device_ctx) then
      av_buffer_unref(@FCodecContext^.hw_device_ctx);
  end;
  if Assigned(FHardwareDeviceCtx) then
    av_buffer_unref(@FHardwareDeviceCtx);
end;

function TRtmpFFmpegPacketDecoder.SelectPixelFormat(
  const AFmt: PAVPixelFormat): TAVPixelFormat;
var
  Candidate: PAVPixelFormat;
begin
  FHardwareDecodeActive := False;
  if FHardwareDecodeEnabled and (FHardwarePixelFormat <> AV_PIX_FMT_NONE) then
  begin
    Candidate := AFmt;
    while Assigned(Candidate) and (Candidate^ <> AV_PIX_FMT_NONE) do
    begin
      if Candidate^ = FHardwarePixelFormat then
      begin
        FHardwareDecodeActive := True;
        Exit(FHardwarePixelFormat);
      end;
      Inc(Candidate);
    end;
  end;

  Result := avcodec_default_get_format(FCodecContext, AFmt);
end;

procedure TRtmpFFmpegPacketDecoder.SetError(AErrorCode: Integer;
  const AMessage: string);
begin
  FLastErrorCode := AErrorCode;
  if AMessage <> '' then
    FLastErrorText := AMessage + ': ' + RtmpFFmpegErrorText(AErrorCode)
  else
    FLastErrorText := RtmpFFmpegErrorText(AErrorCode);
end;

{$IFDEF UNIX}
function TRtmpFFmpegPacketDecoder.SupportsLinuxHardwareDecode(
  ADeviceType: TAVHWDeviceType; out APixelFormat: TAVPixelFormat): Boolean;
var
  Config: PAVCodecHWConfig;
  Index: Integer;
begin
  Result := False;
  APixelFormat := AV_PIX_FMT_NONE;
  if not Assigned(FCodec) then
    Exit;

  Index := 0;
  while True do
  begin
    Config := avcodec_get_hw_config(FCodec, Index);
    if not Assigned(Config) then
      Exit;

    if (Ord(Config^.device_type) = Ord(ADeviceType)) and
       (Config^.pix_fmt <> AV_PIX_FMT_NONE) and
       ((Config^.methods and AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) <> 0) then
    begin
      APixelFormat := Config^.pix_fmt;
      Exit(True);
    end;

    Inc(Index);
  end;
end;
{$ENDIF}

function TRtmpFFmpegPacketDecoder.SubmitPacket(const APacket: TRtmpPacket): Integer;
var
  ConfigCodecKind: TRtmpDecoderCodec;
  ConfigMediaKind: TRtmpDecoderMediaKind;
  ConvertedPayload: TBytes;
  DummyExtradata: TBytes;
  Offset: Integer;
begin
  if TryExtractCodecConfig(APacket, ConfigMediaKind, ConfigCodecKind, DummyExtradata) then
  begin
    if OpenFromConfig(APacket) then
      Exit(0);
    Exit(FLastErrorCode);
  end;

  if not FIsOpen or not Assigned(FCodecContext) then
  begin
    SetError(AVERROR_EINVAL, 'Decoder is not open');
    Exit(FLastErrorCode);
  end;

  if not TryExtractPacketPayload(APacket, Offset) then
  begin
    SetError(AVERROR_EINVAL, 'Packet payload is not supported for decode');
    Exit(FLastErrorCode);
  end;

  if (FCodecKind = dcAVC) and (FMediaKind = dmVideo) then
  begin
    if not ConvertAvccToAnnexB(APacket.Payload.Bytes, Offset, ConvertedPayload) then
    begin
      if FLastErrorText <> '' then
        SetError(AVERROR_INVALIDDATA, FLastErrorText)
      else
        SetError(AVERROR_INVALIDDATA, 'Failed to convert AVC payload to Annex B');
      Exit(FLastErrorCode);
    end;
    Result := TRtmpFFmpegApi.LoadPacketBytes(FPacket, ConvertedPayload, 0,
      APacket.Timestamp, Integer(APacket.TimestampDelta), APacket.HasFlag(pfIsKeyframe));
  end
  else
    Result := TRtmpFFmpegApi.LoadPacketBytes(FPacket, APacket.Payload.Bytes, Offset,
      APacket.Timestamp, Integer(APacket.TimestampDelta), APacket.HasFlag(pfIsKeyframe));
  if Result < 0 then
  begin
    SetError(Result, 'Failed to load decode packet');
    Exit;
  end;

  Result := TRtmpFFmpegApi.SendPacket(FCodecContext, FPacket);
  TRtmpFFmpegApi.UnrefPacket(FPacket);
  if Result < 0 then
    SetError(Result, 'Failed to send packet to decoder');
end;

function TRtmpFFmpegPacketDecoder.TryExtractCodecConfig(const APacket: TRtmpPacket;
  out AMediaKind: TRtmpDecoderMediaKind; out ACodecKind: TRtmpDecoderCodec;
  out AExtradata: TBytes): Boolean;
var
  Bytes: TBytes;
begin
  Result := False;
  AMediaKind := dmUnknown;
  ACodecKind := dcUnknown;
  AExtradata := nil;

  if (APacket = nil) or (APacket.Payload = nil) then
    Exit;

  Bytes := APacket.Payload.Bytes;
  case APacket.MessageType of
    mtAudio:
      begin
        if (Length(Bytes) < 3) or (((Bytes[0] shr 4) and $0F) <> 10) or (Bytes[1] <> 0) then
          Exit;
        AMediaKind := dmAudio;
        ACodecKind := dcAAC;
        AExtradata := Copy(Bytes, 2, Length(Bytes) - 2);
        Result := Length(AExtradata) > 0;
      end;
    mtVideo:
      begin
        if (Length(Bytes) < 6) or ((Bytes[0] and $0F) <> 7) or (Bytes[1] <> 0) then
          Exit;
        AMediaKind := dmVideo;
        ACodecKind := dcAVC;
        AExtradata := Copy(Bytes, 5, Length(Bytes) - 5);
        Result := Length(AExtradata) > 0;
      end;
  end;
end;

function TRtmpFFmpegPacketDecoder.TryExtractPacketPayload(const APacket: TRtmpPacket;
  out AOffset: Integer): Boolean;
var
  Bytes: TBytes;
begin
  Result := False;
  AOffset := 0;

  if (APacket = nil) or (APacket.Payload = nil) then
    Exit;

  Bytes := APacket.Payload.Bytes;
  case APacket.MessageType of
    mtAudio:
      begin
        if (Length(Bytes) < 3) or (((Bytes[0] shr 4) and $0F) <> 10) or (Bytes[1] <> 1) then
          Exit;
        if FMediaKind <> dmAudio then
          Exit;
        AOffset := 2;
        Result := True;
      end;
    mtVideo:
      begin
        if (Length(Bytes) < 6) or ((Bytes[0] and $0F) <> 7) or (Bytes[1] <> 1) then
          Exit;
        if FMediaKind <> dmVideo then
          Exit;
        AOffset := 5;
        Result := True;
      end;
  end;
end;

procedure TRtmpFFmpegPacketDecoder.UnrefFrame;
begin
  if Assigned(FDecodeFrame) then
    TRtmpFFmpegApi.UnrefFrame(FDecodeFrame);
  if Assigned(FFrame) then
    TRtmpFFmpegApi.UnrefFrame(FFrame);
end;

end.

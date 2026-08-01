unit TRTMP.RTMP.Decode.FFmpeg;

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
  libavutil_channel_layout,
  libavutil_error,
  libavutil_frame,
  libavutil_hwcontext,
  libavutil_pixfmt,
  TRTMP.RTMP.Decode,
  TRTMP.FFmpeg,
  TRTMP.FFmpeg.API,
  TRTMP.RTMP.Protocol.FLV,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Types;

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
    FTrackID: Integer;
    FActiveTrackID: Integer;
    function ConvertLengthPrefixedToAnnexB(const AData: TBytes; AOffset: Integer;
      ASize: Integer; out AConverted: TBytes): Boolean;
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
    procedure SetTrackID(AValue: Integer);
    function TrySelectTrack(const AInfo: TRtmpFlvTagInfo; ATrackID: Integer;
      out ATrack: TRtmpFlvTrackInfo): Boolean;
    function TryExtractCodecConfig(const APacket: TRtmpPacket;
      out AMediaKind: TRtmpDecoderMediaKind; out ACodecKind: TRtmpDecoderCodec;
      out AExtradata: TBytes; out ASelectedTrackID: Integer): Boolean;
    function TryExtractPacketPayload(const APacket: TRtmpPacket;
      out AOffset, ASize: Integer): Boolean;
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
    property ActiveTrackID: Integer read FActiveTrackID;
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
    property TrackID: Integer read FTrackID write SetTrackID;
  end;

implementation

{$IFDEF UNIX}
uses
  FfmpegLinuxV4L2RequestTypes;
{$ENDIF}

function EnhancedVideoCodecForFourCC(
  const AFourCC: string): TRtmpDecoderCodec;
begin
  if AFourCC = 'hvc1' then
    Result:=dcHEVC
  else if AFourCC = 'av01' then
    Result:=dcAV1
  else if AFourCC = 'vp09' then
    Result:=dcVP9
  else if AFourCC = 'avc1' then
    Result:=dcAVC
  else
    Result:=dcUnknown;
end;

function EnhancedVideoFourCCForCodec(
  ACodec: TRtmpDecoderCodec): string;
begin
  case ACodec of
    dcHEVC: Result:='hvc1';
    dcAV1: Result:='av01';
    dcVP9: Result:='vp09';
    dcAVC: Result:='avc1';
  else
    Result:='';
  end;
end;

function EnhancedAudioCodecForFourCC(
  const AFourCC: string): TRtmpDecoderCodec;
begin
  if AFourCC = 'Opus' then
    Result:=dcOpus
  else if AFourCC = 'fLaC' then
    Result:=dcFLAC
  else if AFourCC = 'ac-3' then
    Result:=dcAC3
  else if AFourCC = 'ec-3' then
    Result:=dcEAC3
  else if AFourCC = 'mp4a' then
    Result:=dcAAC
  else
    Result:=dcUnknown;
end;

function EnhancedAudioFourCCForCodec(
  ACodec: TRtmpDecoderCodec): string;
begin
  case ACodec of
    dcOpus: Result:='Opus';
    dcFLAC: Result:='fLaC';
    dcAC3: Result:='ac-3';
    dcEAC3: Result:='ec-3';
    dcAAC: Result:='mp4a';
  else
    Result:='';
  end;
end;

function RtmpDecoderGetFormat(s: PAVCodecContext; const fmt: PAVPixelFormat): TAVPixelFormat; cdecl;
var
  Decoder: TRtmpFFmpegPacketDecoder;
begin
  if Assigned(s) AND Assigned(s^.opaque) then
  begin
    Decoder:=TRtmpFFmpegPacketDecoder(s^.opaque);
    Result:=Decoder.SelectPixelFormat(fmt);
    Exit;
  end;
  Result:=avcodec_default_get_format(s, fmt);
end;

constructor TRtmpFFmpegPacketDecoder.Create;
begin
  inherited Create;
  FCodec:=nil;
  FCodecContext:=nil;
  FPacket:=TRtmpFFmpegApi.AllocPacket;
  FFrame:=TRtmpFFmpegApi.AllocFrame;
  FDecodeFrame:=TRtmpFFmpegApi.AllocFrame;
  FHardwareDecodeActive:=False;
  FHardwareDecodeEnabled:=False;
  FHardwareDeviceCtx:=nil;
  FHardwareMode:=dhmAuto;
  FHardwareDeviceName:='';
  FHardwarePixelFormat:=AV_PIX_FMT_NONE;
  FMediaKind:=dmUnknown;
  FCodecKind:=dcUnknown;
  FNaluLengthSize:=4;
  FPassthroughHardwareFrames:=False;
  FThreadCount:=1;
  FThreadMode:=dtmAuto;
  FTrackID:=-1;
  FActiveTrackID:=-1;
  FIsOpen:=False;
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
  FIsOpen:=False;
  FCodec:=nil;
  FMediaKind:=dmUnknown;
  FCodecKind:=dcUnknown;
  FActiveTrackID:=-1;
  FNaluLengthSize:=4;
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

function TRtmpFFmpegPacketDecoder.ConvertLengthPrefixedToAnnexB(const AData: TBytes;
  AOffset, ASize: Integer; out AConverted: TBytes): Boolean;
  function Fail(const AReason: string): Boolean;
  begin
    FLastErrorText:=AReason;
    Result:=False;
  end;
var
  InputIndex: Integer;
  NaluLength: UInt32;
  OutputIndex: Integer;
  SizeFieldIndex: Integer;
  InputEnd: Integer;
begin
  Result:=False;
  AConverted:=nil;

  if (FNaluLengthSize < 1) OR (FNaluLengthSize > 4) then
    Exit(Fail(Format('Invalid NALU length size %d', [FNaluLengthSize])));
  if (AOffset < 0) OR (ASize < 0) OR (AOffset > Length(AData)) OR
    (ASize > Length(AData) - AOffset) then
    Exit(Fail(Format('Invalid AVC payload slice offset=%d size=%d for %d-byte buffer',
      [AOffset, ASize, Length(AData)])));

  InputEnd:=AOffset + ASize;
  SetLength(AConverted, ASize + ((ASize DIV 16) + 1) * 4);
  OutputIndex:=0;
  InputIndex:=AOffset;
  while InputIndex < InputEnd do
  begin
    if (InputEnd - InputIndex) < FNaluLengthSize then
      Exit(Fail(Format('Truncated AVC length field at byte %d', [InputIndex - AOffset])));

    NaluLength:=0;
    for SizeFieldIndex:=0 to FNaluLengthSize - 1 do
      NaluLength:=(NaluLength SHL 8) OR UInt32(AData[InputIndex + SizeFieldIndex]);
    Inc(InputIndex, FNaluLengthSize);

    if (NaluLength = 0) OR (UInt32(InputEnd - InputIndex) < NaluLength) then
      Exit(Fail(Format('Invalid AVC NALU length %d at byte %d with %d bytes remaining',
        [NaluLength, InputIndex - AOffset - FNaluLengthSize, InputEnd - InputIndex])));

    if (Length(AConverted) - OutputIndex) < Integer(NaluLength) + 4 then
      SetLength(AConverted, OutputIndex + Integer(NaluLength) + 4);

    AConverted[OutputIndex]:=0;
    AConverted[OutputIndex + 1]:=0;
    AConverted[OutputIndex + 2]:=0;
    AConverted[OutputIndex + 3]:=1;
    Inc(OutputIndex, 4);

    Move(AData[InputIndex], AConverted[OutputIndex], Integer(NaluLength));
    Inc(OutputIndex, Integer(NaluLength));
    Inc(InputIndex, Integer(NaluLength));
  end;

  SetLength(AConverted, OutputIndex);
  Result:=OutputIndex > 0;
end;

function TRtmpFFmpegPacketDecoder.CodecIDForKind(
  ACodecKind: TRtmpDecoderCodec): TAVCodecID;
begin
  case ACodecKind of
    dcAAC: Result:=AV_CODEC_ID_AAC;
    dcAVC: Result:=AV_CODEC_ID_H264;
    dcHEVC: Result:=AV_CODEC_ID_HEVC;
    dcOpus: Result:=AV_CODEC_ID_OPUS;
    dcAV1: Result:=AV_CODEC_ID_AV1;
    dcVP9: Result:=AV_CODEC_ID_VP9;
    dcFLAC: Result:=AV_CODEC_ID_FLAC;
    dcAC3: Result:=AV_CODEC_ID_AC3;
    dcEAC3: Result:=AV_CODEC_ID_EAC3;
  else
    Result:=AV_CODEC_ID_NONE;
  end;
end;

function TRtmpFFmpegPacketDecoder.PreferredDecoderName(
  AMediaKind: TRtmpDecoderMediaKind; ACodecKind: TRtmpDecoderCodec): AnsiString;
begin
  Result:='';
  if (AMediaKind <> dmVideo) OR (ACodecKind <> dcAVC) then
    Exit;

  case FHardwareMode of
    dhmQsv:
      Result:='';
  end;
end;

procedure TRtmpFFmpegPacketDecoder.Flush;
begin
  if NOT Assigned(FCodecContext) then
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
      Result:=False;
    dhmVaapi:
      Result:=TryActivateLinuxHardwareDecode('vaapi', '/dev/dri/renderD128');
    dhmQsv:
      Result:=TryActivateLinuxHardwareDecode('qsv', '');
    dhmV4L2Request:
      Result:=TryActivateLinuxHardwareDecode('v4l2request', '');
    dhmDrm:
      Result:=TryActivateLinuxHardwareDecode('drm', '/dev/dri/renderD128');
  else
    Result:=
      TryActivateLinuxHardwareDecode('vaapi', '/dev/dri/renderD128') OR
      TryActivateLinuxHardwareDecode('qsv', '') OR
      TryActivateLinuxHardwareDecode('v4l2request', '') OR
      TryActivateLinuxHardwareDecode('drm', '/dev/dri/renderD128');
  end;
end;

function TRtmpFFmpegPacketDecoder.TryActivateLinuxHardwareDecode(
  const ADeviceName, APreferredDevice: AnsiString): Boolean;
var
  DeviceType: TAVHWDeviceType;
  PixelFormat: TAVPixelFormat;
begin
  Result:=False;

  DeviceType:=av_hwdevice_find_type_by_name(PAnsiChar(ADeviceName));
  if Ord(DeviceType) = Ord(AV_HWDEVICE_TYPE_NONE) then
    Exit;
  if NOT SupportsLinuxHardwareDecode(DeviceType, PixelFormat) then
    Exit;
  if NOT TryCreateHardwareDevice(DeviceType, APreferredDevice) then
    Exit;

  FCodecContext^.hw_device_ctx:=av_buffer_ref(FHardwareDeviceCtx);
  if NOT Assigned(FCodecContext^.hw_device_ctx) then
  begin
    av_buffer_unref(@FHardwareDeviceCtx);
    Exit;
  end;

  FCodecContext^.opaque:=Self;
  FCodecContext^.get_format:=@RtmpDecoderGetFormat;
  FHardwarePixelFormat:=PixelFormat;
  FHardwareDeviceName:=string(ADeviceName);
  FHardwareDecodeEnabled:=True;
  Result:=True;
end;

function TRtmpFFmpegPacketDecoder.TryCreateHardwareDevice(
  ADeviceType: TAVHWDeviceType; const APreferredDevice: AnsiString): Boolean;
var
  ErrorCode: Integer;
begin
  Result:=False;

  if Assigned(FHardwareDeviceCtx) then
    av_buffer_unref(@FHardwareDeviceCtx);

  if APreferredDevice <> '' then
  begin
    ErrorCode:=av_hwdevice_ctx_create(@FHardwareDeviceCtx, ADeviceType,
      PAnsiChar(APreferredDevice), nil, 0);
    if ErrorCode >= 0 then
      Exit(True);

    if Assigned(FHardwareDeviceCtx) then
      av_buffer_unref(@FHardwareDeviceCtx);
  end;

  ErrorCode:=av_hwdevice_ctx_create(@FHardwareDeviceCtx, ADeviceType, nil, nil, 0);
  Result:=ErrorCode >= 0;
  if (NOT Result) AND Assigned(FHardwareDeviceCtx) then
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
  SelectedTrackID: Integer;
begin
  Result:=False;
  ResetError;

  if NOT TryExtractCodecConfig(APacket, MediaKind, CodecKind, Extradata,
    SelectedTrackID) then
  begin
    SetError(AVERROR_EINVAL, 'Packet is not a supported codec-config message');
    Exit;
  end;

  CodecID:=CodecIDForKind(CodecKind);
  if CodecID = AV_CODEC_ID_NONE then
  begin
    SetError(AVERROR_DECODER_NOT_FOUND, 'No decoder mapping for codec');
    Exit;
  end;

  Close;

  DecoderName:=PreferredDecoderName(MediaKind, CodecKind);
  if DecoderName <> '' then
    FCodec:=TRtmpFFmpegApi.FindDecoderByName(DecoderName)
  else
    FCodec:=nil;
  if NOT Assigned(FCodec) then
    FCodec:=TRtmpFFmpegApi.FindDecoder(CodecID);
  if NOT Assigned(FCodec) then
  begin
    SetError(AVERROR_DECODER_NOT_FOUND, 'Decoder not found');
    Exit;
  end;

  FCodecContext:=TRtmpFFmpegApi.AllocDecoderContext(FCodec);
  if NOT Assigned(FCodecContext) then
  begin
    SetError(AVERROR_ENOMEM, 'Failed to allocate decoder context');
    Exit;
  end;

  FCodecContext^.codec_id:=CodecID;
  FCodecContext^.pkt_timebase.num:=1;
  FCodecContext^.pkt_timebase.den:=1000000000;
  if (CodecKind = dcOpus) AND (Length(Extradata) >= 10) AND
    (Extradata[0] = Ord('O')) AND (Extradata[1] = Ord('p')) AND
    (Extradata[2] = Ord('u')) AND (Extradata[3] = Ord('s')) AND
    (Extradata[4] = Ord('H')) AND (Extradata[5] = Ord('e')) AND
    (Extradata[6] = Ord('a')) AND (Extradata[7] = Ord('d')) AND
    (Extradata[9] > 0) then
  begin
    { Opus always decodes at 48 kHz.  Seed the context from OpusHead because
      raw Enhanced RTMP has no AVCodecParameters layer to do this for us. }
    FCodecContext^.sample_rate:=48000;
    av_channel_layout_default(@FCodecContext^.ch_layout, Extradata[9]);
  end;
  if FThreadCount > 0 then
    FCodecContext^.thread_count:=FThreadCount
  else
    FCodecContext^.thread_count:=1;
  case FThreadMode of
    dtmSlice:
      FCodecContext^.thread_type:=FF_THREAD_SLICE;
    dtmFrame:
      FCodecContext^.thread_type:=FF_THREAD_FRAME;
  else
    FCodecContext^.thread_type:=FF_THREAD_SLICE OR FF_THREAD_FRAME;
  end;
  FCodecContext^.flags:=FCodecContext^.flags OR AV_CODEC_FLAG_LOW_DELAY;
  FCodecContext^.flags2:=FCodecContext^.flags2 OR AV_CODEC_FLAG2_FAST;

  {$IFDEF UNIX}
  if MediaKind = dmVideo then
    ActivateLinuxHardwareDecode;
  {$ENDIF}
  if NOT FHardwareDecodeEnabled then
    FCodecContext^.flags2:=FCodecContext^.flags2 OR AV_CODEC_FLAG2_CHUNKS;

  FLastErrorCode:=TRtmpFFmpegApi.LoadExtradata(FCodecContext, Extradata);
  if FLastErrorCode < 0 then
  begin
    SetError(FLastErrorCode, 'Failed to load codec extradata');
    Close;
    Exit;
  end;

  FLastErrorCode:=TRtmpFFmpegApi.OpenDecoder(FCodecContext, FCodec);
  if FLastErrorCode < 0 then
  begin
    SetError(FLastErrorCode, 'Failed to open decoder');
    Close;
    Exit;
  end;

  FMediaKind:=MediaKind;
  FCodecKind:=CodecKind;
  FActiveTrackID:=SelectedTrackID;
  if (CodecKind = dcAVC) AND (Length(Extradata) >= 5) then
    FNaluLengthSize:=(Extradata[4] AND $03) + 1
  else if (CodecKind = dcHEVC) AND (Length(Extradata) >= 22) then
    FNaluLengthSize:=(Extradata[21] AND $03) + 1
  else
    FNaluLengthSize:=4;
  FIsOpen:=True;
  Result:=True;
end;

function TRtmpFFmpegPacketDecoder.ReceiveFrame(
  out AInfo: TRtmpDecodedFrameInfo): Integer;
var
  DecodeFrame: PAVFrame;
begin
  AInfo:=Default(TRtmpDecodedFrameInfo);
  if NOT Assigned(FCodecContext) then
  begin
    SetError(AVERROR_EINVAL, 'Decoder is not open');
    Exit(FLastErrorCode);
  end;

  if FHardwareDecodeEnabled then
    DecodeFrame:=FDecodeFrame
  else
    DecodeFrame:=FFrame;

  Result:=TRtmpFFmpegApi.ReceiveFrame(FCodecContext, DecodeFrame);
  if Result < 0 then
  begin
    if (Result <> AVERROR_EAGAIN) AND (Result <> AVERROR_EOF) then
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
          Result:=MapHardwareFrameToDrmPrime;
          if Result < 0 then
          begin
            SetError(Result, 'Failed to map hardware decoded frame to DRM_PRIME');
            Exit;
          end;
        end;
      end
      else
      begin
        Result:=HandleHardwareFrameTransfer;
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

  AInfo.MediaKind:=FMediaKind;
  AInfo.Codec:=FCodecKind;
  AInfo.TrackID:=FActiveTrackID;
  if FFrame^.best_effort_timestamp <> AV_NOPTS_VALUE then
    AInfo.TimestampNS:=FFrame^.best_effort_timestamp
  else if FFrame^.pts <> AV_NOPTS_VALUE then
    AInfo.TimestampNS:=FFrame^.pts
  else
    AInfo.TimestampNS:=0;
  AInfo.TimestampMS:=AInfo.TimestampNS DIV 1000000;
  AInfo.TimestampNanoOffset:=Integer(AInfo.TimestampNS MOD 1000000);
  AInfo.IsKeyframe:=(FFrame^.flags AND AV_FRAME_FLAG_KEY) <> 0;
  AInfo.Width:=FFrame^.width;
  AInfo.Height:=FFrame^.height;
  AInfo.SampleRate:=FFrame^.sample_rate;
  AInfo.Channels:=FFrame^.ch_layout.nb_channels;
  if (AInfo.SampleRate = 0) AND Assigned(FCodecContext) then
    AInfo.SampleRate:=FCodecContext^.sample_rate;
  if (AInfo.Channels = 0) AND Assigned(FCodecContext) then
    AInfo.Channels:=FCodecContext^.ch_layout.nb_channels;
  AInfo.SampleCount:=FFrame^.nb_samples;
  AInfo.FormatCode:=FFrame^.format;
end;

function TRtmpFFmpegPacketDecoder.HandleHardwareFrameTransfer: Integer;
begin
  TRtmpFFmpegApi.UnrefFrame(FFrame);
  FFrame^.format:=Ord(AV_PIX_FMT_NONE);
  FFrame^.width:=FDecodeFrame^.width;
  FFrame^.height:=FDecodeFrame^.height;

  Result:=av_hwframe_transfer_data(FFrame, FDecodeFrame, 0);
  if Result < 0 then
    Exit;

  Result:=av_frame_copy_props(FFrame, FDecodeFrame);
  if Result < 0 then
  begin
    TRtmpFFmpegApi.UnrefFrame(FFrame);
    Exit;
  end;

  FFrame^.pts:=FDecodeFrame^.pts;
  FFrame^.pkt_dts:=FDecodeFrame^.pkt_dts;
  FFrame^.best_effort_timestamp:=FDecodeFrame^.best_effort_timestamp;
  FFrame^.flags:=FDecodeFrame^.flags;
  FFrame^.sample_rate:=FDecodeFrame^.sample_rate;
  FFrame^.ch_layout:=FDecodeFrame^.ch_layout;
  FFrame^.nb_samples:=FDecodeFrame^.nb_samples;
end;

function TRtmpFFmpegPacketDecoder.MapHardwareFrameToDrmPrime: Integer;
begin
  TRtmpFFmpegApi.UnrefFrame(FFrame);
  FFrame^.format:=Ord(AV_PIX_FMT_DRM_PRIME);
  FFrame^.width:=FDecodeFrame^.width;
  FFrame^.height:=FDecodeFrame^.height;

  Result:=av_hwframe_map(FFrame, FDecodeFrame,
    Ord(AV_HWFRAME_MAP_READ) OR Ord(AV_HWFRAME_MAP_DIRECT));
  if Result < 0 then
  begin
    TRtmpFFmpegApi.UnrefFrame(FFrame);
    Exit;
  end;

  Result:=av_frame_copy_props(FFrame, FDecodeFrame);
  if Result < 0 then
  begin
    TRtmpFFmpegApi.UnrefFrame(FFrame);
    Exit;
  end;

  FFrame^.pts:=FDecodeFrame^.pts;
  FFrame^.pkt_dts:=FDecodeFrame^.pkt_dts;
  FFrame^.best_effort_timestamp:=FDecodeFrame^.best_effort_timestamp;
  FFrame^.flags:=FDecodeFrame^.flags;
  FFrame^.sample_rate:=FDecodeFrame^.sample_rate;
  FFrame^.ch_layout:=FDecodeFrame^.ch_layout;
  FFrame^.nb_samples:=FDecodeFrame^.nb_samples;
end;

procedure TRtmpFFmpegPacketDecoder.ResetError;
begin
  FLastErrorCode:=0;
  FLastErrorText:='';
end;

procedure TRtmpFFmpegPacketDecoder.ResetHardwareDecode;
begin
  FHardwareDecodeActive:=False;
  FHardwareDecodeEnabled:=False;
  FHardwareDeviceName:='';
  FHardwarePixelFormat:=AV_PIX_FMT_NONE;
  if Assigned(FCodecContext) then
  begin
    FCodecContext^.get_format:=nil;
    FCodecContext^.opaque:=nil;
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
  FHardwareDecodeActive:=False;
  if FHardwareDecodeEnabled AND (FHardwarePixelFormat <> AV_PIX_FMT_NONE) then
  begin
    Candidate:=AFmt;
    while Assigned(Candidate) AND (Candidate^ <> AV_PIX_FMT_NONE) do
    begin
      if Candidate^ = FHardwarePixelFormat then
      begin
        FHardwareDecodeActive:=True;
        Exit(FHardwarePixelFormat);
      end;
      Inc(Candidate);
    end;
  end;

  Result:=avcodec_default_get_format(FCodecContext, AFmt);
end;

procedure TRtmpFFmpegPacketDecoder.SetError(AErrorCode: Integer;
  const AMessage: string);
begin
  FLastErrorCode:=AErrorCode;
  if AMessage <> '' then
    FLastErrorText:=AMessage + ': ' + RtmpFFmpegErrorText(AErrorCode)
  else
    FLastErrorText:=RtmpFFmpegErrorText(AErrorCode);
end;

procedure TRtmpFFmpegPacketDecoder.SetTrackID(AValue: Integer);
begin
  if (AValue < -1) OR (AValue > 255) then
    raise ERangeError.CreateFmt('Enhanced RTMP track ID %d is outside -1..255',
      [AValue]);
  if FTrackID = AValue then
    Exit;
  Close;
  FTrackID:=AValue;
end;

function TRtmpFFmpegPacketDecoder.TrySelectTrack(
  const AInfo: TRtmpFlvTagInfo; ATrackID: Integer;
  out ATrack: TRtmpFlvTrackInfo): Boolean;
var
  I: Integer;
begin
  ATrack:=Default(TRtmpFlvTrackInfo);
  Result:=False;
  if NOT AInfo.IsMultitrack OR (AInfo.TrackCount <= 0) then
    Exit;

  if ATrackID >= 0 then
  begin
    for I:=0 to AInfo.TrackCount - 1 do
      if AInfo.Tracks[I].TrackID = ATrackID then
      begin
        ATrack:=AInfo.Tracks[I];
        Exit(True);
      end;
    Exit;
  end;

  for I:=0 to AInfo.TrackCount - 1 do
    if AInfo.Tracks[I].TrackID = 0 then
    begin
      ATrack:=AInfo.Tracks[I];
      Exit(True);
    end;
  ATrack:=AInfo.Tracks[0];
  Result:=True;
end;

{$IFDEF UNIX}
function TRtmpFFmpegPacketDecoder.SupportsLinuxHardwareDecode(
  ADeviceType: TAVHWDeviceType; out APixelFormat: TAVPixelFormat): Boolean;
var
  Config: PAVCodecHWConfig;
  Index: Integer;
begin
  Result:=False;
  APixelFormat:=AV_PIX_FMT_NONE;
  if NOT Assigned(FCodec) then
    Exit;

  Index:=0;
  while True do
  begin
    Config:=avcodec_get_hw_config(FCodec, Index);
    if NOT Assigned(Config) then
      Exit;

    if (Ord(Config^.device_type) = Ord(ADeviceType)) AND
       (Config^.pix_fmt <> AV_PIX_FMT_NONE) AND
       ((Config^.methods AND AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) <> 0) then
    begin
      APixelFormat:=Config^.pix_fmt;
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
  DummyTrackID: Integer;
  Info: TRtmpFlvTagInfo;
  Offset: Integer;
  PayloadSize: Integer;
  SelectedFourCC: string;
  SelectedTrack: TRtmpFlvTrackInfo;
  CompositionTimeOffset: Integer;
  DecodeTimestampNS: Int64;
  DurationNS: Int64;
  PresentationTimestampNS: Int64;
  TimestampNanoOffset: Integer;
begin
  if TryExtractCodecConfig(APacket, ConfigMediaKind, ConfigCodecKind,
    DummyExtradata, DummyTrackID) then
  begin
    if OpenFromConfig(APacket) then
      Exit(0);
    Exit(FLastErrorCode);
  end;

  if NOT FIsOpen OR NOT Assigned(FCodecContext) then
  begin
    SetError(AVERROR_EINVAL, 'Decoder is not open');
    Exit(FLastErrorCode);
  end;
  if (APacket = nil) OR (APacket.Payload = nil) then
  begin
    SetError(AVERROR_EINVAL, 'Packet payload is not supported for decode');
    Exit(FLastErrorCode);
  end;

  { Enhanced RTMP sequence-end packets contain no compressed frame.  Send
    FFmpeg its drain marker so delayed video frames remain available through
    ReceiveFrame, rather than reporting the control packet as bad media. }
  Info:=Default(TRtmpFlvTagInfo);
  RtmpInspectFlvTag(APacket.MessageType, APacket.Payload.Bytes, Info);
  SelectedFourCC:=Info.CodecFourCC;
  PayloadSize:=Info.PayloadSize;
  CompositionTimeOffset:=Info.CompositionTimeOffset;
  if Info.IsEnhanced AND Info.IsMultitrack then
  begin
    if NOT TrySelectTrack(Info, FActiveTrackID, SelectedTrack) then
    begin
      ResetError;
      Exit(0);
    end;
    SelectedFourCC:=SelectedTrack.CodecFourCC;
    PayloadSize:=SelectedTrack.PayloadSize;
    CompositionTimeOffset:=SelectedTrack.CompositionTimeOffset;
  end;

  if Info.IsEnhanced AND
    ((((FCodecKind IN [dcAVC, dcHEVC, dcAV1, dcVP9]) AND
      (SelectedFourCC = EnhancedVideoFourCCForCodec(FCodecKind))) AND
      (Info.VideoPacketType = 2)) OR
     ((FCodecKind IN [dcAAC, dcOpus, dcFLAC, dcAC3, dcEAC3]) AND
      (SelectedFourCC = EnhancedAudioFourCCForCodec(FCodecKind)) AND
      (Info.AudioPacketType = 2))) then
  begin
    Result:=TRtmpFFmpegApi.SendFlushPacket(FCodecContext);
    if Result < 0 then
      SetError(Result, 'Failed to drain decoder at sequence end');
    if Result >= 0 then
      ResetError;
    Exit;
  end;

  { Enhanced video metadata and MPEG-2 TS sequence-start packets, plus the
    enhanced-audio multichannel configuration packet, describe the stream
    but carry no compressed frame for avcodec_send_packet. }
  if Info.IsEnhanced AND
    ((((FCodecKind IN [dcAVC, dcHEVC, dcAV1, dcVP9]) AND
      (SelectedFourCC = EnhancedVideoFourCCForCodec(FCodecKind))) AND
      (Info.VideoPacketType IN [4, 5])) OR
     ((FCodecKind IN [dcAAC, dcOpus, dcFLAC, dcAC3, dcEAC3]) AND
      (SelectedFourCC = EnhancedAudioFourCCForCodec(FCodecKind)) AND
      (Info.AudioPacketType = 4))) then
  begin
    ResetError;
    Exit(0);
  end;

  { FFmpeg may terminate an enhanced audio stream with an empty coded-frame
    envelope. It carries no packet for the codec and is safe to ignore. }
  if Info.IsEnhanced AND (APacket.MessageType = mtAudio) AND
    (Info.AudioPacketType = 1) AND (PayloadSize = 0) AND
    (FCodecKind IN [dcAAC, dcOpus, dcFLAC, dcAC3, dcEAC3]) AND
    (SelectedFourCC = EnhancedAudioFourCCForCodec(FCodecKind)) then
  begin
    ResetError;
    Exit(0);
  end;

  if NOT TryExtractPacketPayload(APacket, Offset, PayloadSize) then
  begin
    SetError(AVERROR_EINVAL, 'Packet payload is not supported for decode');
    Exit(FLastErrorCode);
  end;

  if Info.HasTimestampNanoOffset then
    TimestampNanoOffset:=Info.TimestampNanoOffset
  else
    TimestampNanoOffset:=0;
  DecodeTimestampNS:=Int64(APacket.Timestamp) * 1000000 +
    TimestampNanoOffset;
  PresentationTimestampNS:=DecodeTimestampNS +
    Int64(CompositionTimeOffset) * 1000000;
  DurationNS:=Int64(APacket.TimestampDelta) * 1000000;

  { The AVC decoder accepts Annex B alongside avcC extradata.  For HEVC,
    retain the length-prefixed access unit described by hvcC; converting it
    while leaving hvcC installed makes FFmpeg interpret the Annex B start
    code as a NAL-unit length. }
  if (FCodecKind = dcAVC) AND (FMediaKind = dmVideo) then
  begin
    if NOT ConvertLengthPrefixedToAnnexB(APacket.Payload.Bytes, Offset,
      PayloadSize,
      ConvertedPayload) then
    begin
      if FLastErrorText <> '' then
        SetError(AVERROR_INVALIDDATA, FLastErrorText)
      else
        SetError(AVERROR_INVALIDDATA,
          'Failed to convert length-prefixed video payload to Annex B');
      Exit(FLastErrorCode);
    end;
    Result:=TRtmpFFmpegApi.LoadPacketBytes(FPacket, ConvertedPayload, 0,
      Length(ConvertedPayload), PresentationTimestampNS, DecodeTimestampNS,
      DurationNS, APacket.HasFlag(pfIsKeyframe));
  end
  else
    Result:=TRtmpFFmpegApi.LoadPacketBytes(FPacket, APacket.Payload.Bytes,
      Offset, PayloadSize,
      PresentationTimestampNS, DecodeTimestampNS, DurationNS,
      APacket.HasFlag(pfIsKeyframe));
  if Result < 0 then
  begin
    SetError(Result, 'Failed to load decode packet');
    Exit;
  end;

  Result:=TRtmpFFmpegApi.SendPacket(FCodecContext, FPacket);
  TRtmpFFmpegApi.UnrefPacket(FPacket);
  if Result < 0 then
    SetError(Result, 'Failed to send packet to decoder');
end;

function TRtmpFFmpegPacketDecoder.TryExtractCodecConfig(const APacket: TRtmpPacket;
  out AMediaKind: TRtmpDecoderMediaKind; out ACodecKind: TRtmpDecoderCodec;
  out AExtradata: TBytes; out ASelectedTrackID: Integer): Boolean;
var
  Bytes: TBytes;
  Info: TRtmpFlvTagInfo;
  Track: TRtmpFlvTrackInfo;
begin
  Result:=False;
  AMediaKind:=dmUnknown;
  ACodecKind:=dcUnknown;
  AExtradata:=nil;
  ASelectedTrackID:=-1;

  if (APacket = nil) OR (APacket.Payload = nil) then
    Exit;

  Bytes:=APacket.Payload.Bytes;
  case APacket.MessageType of
    mtAudio:
      begin
        Info:=Default(TRtmpFlvTagInfo);
        if RtmpInspectFlvTag(mtAudio, Bytes, Info) AND Info.IsEnhanced AND
          (Info.AudioPacketType = 0) then
        begin
          if Info.IsMultitrack then
          begin
            if NOT TrySelectTrack(Info, FTrackID, Track) then
              Exit;
          end
          else
          begin
            if FTrackID > 0 then
              Exit;
            Track:=Default(TRtmpFlvTrackInfo);
            Track.TrackID:=0;
            Track.CodecFourCC:=Info.CodecFourCC;
            Track.PayloadOffset:=Info.PayloadOffset;
            Track.PayloadSize:=Info.PayloadSize;
          end;
          ACodecKind:=EnhancedAudioCodecForFourCC(Track.CodecFourCC);
          if ACodecKind <> dcUnknown then
          begin
            AMediaKind:=dmAudio;
            ASelectedTrackID:=Track.TrackID;
            AExtradata:=Copy(Bytes, Track.PayloadOffset, Track.PayloadSize);
            Result:=(ACodecKind IN [dcAC3, dcEAC3]) OR
              (Length(AExtradata) > 0);
            Exit;
          end;
        end;
        if FTrackID > 0 then
          Exit;
        if (Length(Bytes) < 3) OR (((Bytes[0] SHR 4) AND $0F) <> 10) OR (Bytes[1] <> 0) then
          Exit;
        AMediaKind:=dmAudio;
        ACodecKind:=dcAAC;
        ASelectedTrackID:=0;
        AExtradata:=Copy(Bytes, 2, Length(Bytes) - 2);
        Result:=Length(AExtradata) > 0;
      end;
    mtVideo:
      begin
        Info:=Default(TRtmpFlvTagInfo);
        if RtmpInspectFlvTag(mtVideo, Bytes, Info) AND Info.IsEnhanced AND
          (Info.VideoPacketType = 0) then
        begin
          if Info.IsMultitrack then
          begin
            if NOT TrySelectTrack(Info, FTrackID, Track) then
              Exit;
          end
          else
          begin
            if FTrackID > 0 then
              Exit;
            Track:=Default(TRtmpFlvTrackInfo);
            Track.TrackID:=0;
            Track.CodecFourCC:=Info.CodecFourCC;
            Track.PayloadOffset:=Info.PayloadOffset;
            Track.PayloadSize:=Info.PayloadSize;
          end;
          ACodecKind:=EnhancedVideoCodecForFourCC(Track.CodecFourCC);
          if ACodecKind <> dcUnknown then
          begin
            AMediaKind:=dmVideo;
            ASelectedTrackID:=Track.TrackID;
            AExtradata:=Copy(Bytes, Track.PayloadOffset, Track.PayloadSize);
            Result:=Length(AExtradata) > 0;
            Exit;
          end;
        end;
        if FTrackID > 0 then
          Exit;
        if (Length(Bytes) < 6) OR ((Bytes[0] AND $0F) <> 7) OR (Bytes[1] <> 0) then
          Exit;
        AMediaKind:=dmVideo;
        ACodecKind:=dcAVC;
        ASelectedTrackID:=0;
        AExtradata:=Copy(Bytes, 5, Length(Bytes) - 5);
        Result:=Length(AExtradata) > 0;
      end;
  end;
end;

function TRtmpFFmpegPacketDecoder.TryExtractPacketPayload(const APacket: TRtmpPacket;
  out AOffset, ASize: Integer): Boolean;
var
  Bytes: TBytes;
  Info: TRtmpFlvTagInfo;
  Track: TRtmpFlvTrackInfo;
begin
  Result:=False;
  AOffset:=0;
  ASize:=0;

  if (APacket = nil) OR (APacket.Payload = nil) then
    Exit;

  Bytes:=APacket.Payload.Bytes;
  case APacket.MessageType of
    mtAudio:
      begin
        Info:=Default(TRtmpFlvTagInfo);
        if RtmpInspectFlvTag(mtAudio, Bytes, Info) AND Info.IsEnhanced then
        begin
          if Info.IsMultitrack then
          begin
            if NOT TrySelectTrack(Info, FActiveTrackID, Track) then
              Exit;
          end
          else
          begin
            if FActiveTrackID <> 0 then
              Exit;
            Track:=Default(TRtmpFlvTrackInfo);
            Track.CodecFourCC:=Info.CodecFourCC;
            Track.PayloadOffset:=Info.PayloadOffset;
            Track.PayloadSize:=Info.PayloadSize;
          end;
          if (Track.CodecFourCC <> EnhancedAudioFourCCForCodec(FCodecKind)) OR
            (Info.AudioPacketType <> 1) OR (FMediaKind <> dmAudio) OR
            (NOT (FCodecKind IN [dcAAC, dcOpus, dcFLAC, dcAC3, dcEAC3])) then
            Exit;
          AOffset:=Track.PayloadOffset;
          ASize:=Track.PayloadSize;
          Result:=ASize > 0;
          Exit;
        end;
        if (Length(Bytes) < 3) OR (((Bytes[0] SHR 4) AND $0F) <> 10) OR (Bytes[1] <> 1) then
          Exit;
        if FMediaKind <> dmAudio then
          Exit;
        AOffset:=2;
        ASize:=Length(Bytes) - AOffset;
        Result:=ASize > 0;
      end;
    mtVideo:
      begin
        Info:=Default(TRtmpFlvTagInfo);
        if RtmpInspectFlvTag(mtVideo, Bytes, Info) AND Info.IsEnhanced then
        begin
          if Info.IsMultitrack then
          begin
            if NOT TrySelectTrack(Info, FActiveTrackID, Track) then
              Exit;
          end
          else
          begin
            if FActiveTrackID <> 0 then
              Exit;
            Track:=Default(TRtmpFlvTrackInfo);
            Track.CodecFourCC:=Info.CodecFourCC;
            Track.PayloadOffset:=Info.PayloadOffset;
            Track.PayloadSize:=Info.PayloadSize;
          end;
          if (Track.CodecFourCC <> EnhancedVideoFourCCForCodec(FCodecKind)) OR
            (NOT (Info.VideoPacketType IN [1, 3])) OR
            (FMediaKind <> dmVideo) OR
            (NOT (FCodecKind IN [dcAVC, dcHEVC, dcAV1, dcVP9])) then
            Exit;
          AOffset:=Track.PayloadOffset;
          ASize:=Track.PayloadSize;
          Result:=ASize > 0;
          Exit;
        end;
        if (Length(Bytes) < 6) OR ((Bytes[0] AND $0F) <> 7) OR (Bytes[1] <> 1) then
          Exit;
        if FMediaKind <> dmVideo then
          Exit;
        AOffset:=5;
        ASize:=Length(Bytes) - AOffset;
        Result:=ASize > 0;
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

unit TRTMP.FFmpeg.FrameConvert;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  libavutil_frame,
  libavutil_imgutils,
  libavutil_pixfmt,
  libswscale;

type
  TRtmpFFmpegFrameConverter = class
  private
    FBuffer: PByte;
    FBufferSize: NativeInt;
    FContext: PSwsContext;
    FData: array[0..AV_NUM_DATA_POINTERS - 1] of PByte;
    FDestinationFormat: TAVPixelFormat;
    FHeight: Integer;
    FLastErrorText: string;
    FLineSizes: array[0..AV_NUM_DATA_POINTERS - 1] of Integer;
    FSourceFormat: TAVPixelFormat;
    FStride: Integer;
    FWidth: Integer;
    procedure ClearBuffer;
    procedure ClearContext;
    function EnsureBuffer(AWidth, AHeight: Integer): Boolean;
    function EnsureContext(const AFrame: PAVFrame): Boolean;
    function PlaneCountForFormat: Integer;
    procedure SetError(const AMessage: string);
  public
    constructor Create(ADestinationFormat: TAVPixelFormat = AV_PIX_FMT_RGBA);
    destructor Destroy; override;

    procedure Close;
    function ConvertVideoFrame(const AFrame: PAVFrame): Boolean;

    property Buffer: PByte read FBuffer;
    property BufferSize: NativeInt read FBufferSize;
    property DestinationFormat: TAVPixelFormat read FDestinationFormat;
    property Height: Integer read FHeight;
    property LastErrorText: string read FLastErrorText;
    function PlaneCount: Integer;
    function PlaneHeight(AIndex: Integer): Integer;
    function PlaneOffset(AIndex: Integer): Integer;
    property Stride: Integer read FStride;
    function PlaneStride(AIndex: Integer): Integer;
    function PlaneWidth(AIndex: Integer): Integer;
    property Width: Integer read FWidth;
  end;

implementation

constructor TRtmpFFmpegFrameConverter.Create(
  ADestinationFormat: TAVPixelFormat);
begin
  inherited Create;
  FBuffer:=nil;
  FBufferSize:=0;
  FContext:=nil;
  FDestinationFormat:=ADestinationFormat;
  FHeight:=0;
  FLastErrorText:='';
  FSourceFormat:=AV_PIX_FMT_NONE;
  FStride:=0;
  FWidth:=0;
end;

destructor TRtmpFFmpegFrameConverter.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TRtmpFFmpegFrameConverter.ClearBuffer;
begin
  if Assigned(FBuffer) then
    FreeMem(FBuffer);
  FBuffer:=nil;
  FBufferSize:=0;
  FillChar(FData, SizeOf(FData), 0);
  FillChar(FLineSizes, SizeOf(FLineSizes), 0);
  FStride:=0;
  FWidth:=0;
  FHeight:=0;
end;

procedure TRtmpFFmpegFrameConverter.ClearContext;
begin
  if Assigned(FContext) then
    sws_freeContext(FContext);
  FContext:=nil;
  FSourceFormat:=AV_PIX_FMT_NONE;
end;

procedure TRtmpFFmpegFrameConverter.Close;
begin
  ClearContext;
  ClearBuffer;
  FLastErrorText:='';
end;

function TRtmpFFmpegFrameConverter.ConvertVideoFrame(
  const AFrame: PAVFrame): Boolean;
var
  DestinationData: array[0..AV_NUM_DATA_POINTERS - 1] of PByte;
  DestinationStride: array[0..AV_NUM_DATA_POINTERS - 1] of Integer;
  ConvertedHeight: Integer;
begin
  Result:=False;
  FLastErrorText:='';

  if NOT Assigned(AFrame) then
  begin
    SetError('Frame is nil');
    Exit;
  end;
  if (AFrame^.width <= 0) OR (AFrame^.height <= 0) then
  begin
    SetError('Frame dimensions are invalid');
    Exit;
  end;

  if NOT EnsureContext(AFrame) then
    Exit;
  if NOT EnsureBuffer(AFrame^.width, AFrame^.height) then
    Exit;

  Move(FData, DestinationData, SizeOf(DestinationData));
  Move(FLineSizes, DestinationStride, SizeOf(DestinationStride));

  ConvertedHeight:=sws_scale(FContext, @AFrame^.data[0], @AFrame^.linesize[0],
    0, AFrame^.height, @DestinationData[0], @DestinationStride[0]);
  if ConvertedHeight <> AFrame^.height then
  begin
    SetError(Format('sws_scale converted %d of %d rows',
      [ConvertedHeight, AFrame^.height]));
    Exit;
  end;

  Result:=True;
end;

function TRtmpFFmpegFrameConverter.EnsureBuffer(AWidth, AHeight: Integer): Boolean;
var
  FilledSize: Integer;
  RequiredSize: NativeInt;
begin
  Result:=False;

  RequiredSize:=av_image_get_buffer_size(FDestinationFormat, AWidth, AHeight, 1);
  if RequiredSize <= 0 then
  begin
    SetError(Format('av_image_get_buffer_size failed for %dx%d',
      [AWidth, AHeight]));
    Exit;
  end;

  if (FBufferSize <> RequiredSize) OR (FWidth <> AWidth) OR (FHeight <> AHeight) then
  begin
    ClearBuffer;
    GetMem(FBuffer, RequiredSize);
    FillChar(FBuffer^, RequiredSize, 0);
    FBufferSize:=RequiredSize;
    FWidth:=AWidth;
    FHeight:=AHeight;
  end;

  FilledSize:=av_image_fill_arrays(@FData[0], @FLineSizes[0], FBuffer,
    FDestinationFormat, AWidth, AHeight, 1);
  if FilledSize <= 0 then
  begin
    SetError(Format('av_image_fill_arrays failed for %dx%d',
      [AWidth, AHeight]));
    Exit;
  end;

  FStride:=FLineSizes[0];
  Result:=Assigned(FBuffer);
end;

function TRtmpFFmpegFrameConverter.EnsureContext(
  const AFrame: PAVFrame): Boolean;
var
  FrameFormat: TAVPixelFormat;
begin
  Result:=False;
  FrameFormat:=TAVPixelFormat(AFrame^.format);

  if Assigned(FContext) AND (FWidth = AFrame^.width) AND (FHeight = AFrame^.height)
    AND (FSourceFormat = FrameFormat) then
  begin
    Result:=True;
    Exit;
  end;

  ClearContext;

  FContext:=sws_getContext(AFrame^.width, AFrame^.height, FrameFormat,
    AFrame^.width, AFrame^.height, FDestinationFormat, SWS_FAST_BILINEAR, nil, nil, nil);
  if NOT Assigned(FContext) then
  begin
    SetError('sws_getContext failed');
    Exit;
  end;

  FSourceFormat:=FrameFormat;
  Result:=True;
end;

procedure TRtmpFFmpegFrameConverter.SetError(const AMessage: string);
begin
  FLastErrorText:=AMessage;
end;

function TRtmpFFmpegFrameConverter.PlaneCountForFormat: Integer;
begin
  case FDestinationFormat of
    AV_PIX_FMT_RGBA:
      Result:=1;
    AV_PIX_FMT_YUV420P:
      Result:=3;
    AV_PIX_FMT_NV12:
      Result:=2;
  else
    Result:=1;
  end;
end;

function TRtmpFFmpegFrameConverter.PlaneCount: Integer;
begin
  Result:=PlaneCountForFormat;
end;

function TRtmpFFmpegFrameConverter.PlaneHeight(AIndex: Integer): Integer;
begin
  case FDestinationFormat of
    AV_PIX_FMT_YUV420P:
      case AIndex of
        0:
          Result:=FHeight;
        1, 2:
          Result:=(FHeight + 1) DIV 2;
      else
        Result:=0;
      end;
    AV_PIX_FMT_NV12:
      case AIndex of
        0:
          Result:=FHeight;
        1:
          Result:=(FHeight + 1) DIV 2;
      else
        Result:=0;
      end;
  else
    if AIndex = 0 then
      Result:=FHeight
    else
      Result:=0;
  end;
end;

function TRtmpFFmpegFrameConverter.PlaneOffset(AIndex: Integer): Integer;
begin
  if (AIndex < 0) OR (AIndex >= PlaneCountForFormat) OR
    (FBuffer = nil) OR (FData[AIndex] = nil) then
    Exit(-1);
  Result:=NativeUInt(FData[AIndex]) - NativeUInt(FBuffer);
end;

function TRtmpFFmpegFrameConverter.PlaneStride(AIndex: Integer): Integer;
begin
  if (AIndex < 0) OR (AIndex >= PlaneCountForFormat) then
    Exit(0);
  Result:=FLineSizes[AIndex];
end;

function TRtmpFFmpegFrameConverter.PlaneWidth(AIndex: Integer): Integer;
begin
  case FDestinationFormat of
    AV_PIX_FMT_YUV420P:
      case AIndex of
        0:
          Result:=FWidth;
        1, 2:
          Result:=(FWidth + 1) DIV 2;
      else
        Result:=0;
      end;
    AV_PIX_FMT_NV12:
      case AIndex of
        0, 1:
          Result:=FWidth;
      else
        Result:=0;
      end;
  else
    if AIndex = 0 then
      Result:=FWidth
    else
      Result:=0;
  end;
end;

end.

unit RtmpPreview;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF UNIX}
  FfmpegLinuxHwAccelProbe,
  {$ENDIF}
  Contnrs,
  SyncObjs,
  SysUtils,
  libavutil_error,
  libavutil_frame,
  libavutil_pixfmt,
  RtmpCompat,
  RtmpDecoder,
  RtmpDecoderFFmpeg,
  RtmpFFmpegApi,
  RtmpFrameConvertFFmpeg,
  RtmpLog,
  RtmpPacket,
  RtmpPreviewHardwareFrame,
  RtmpServer,
  RtmpServerSession,
  RtmpTypes;

type
  TRtmpPreviewStreamSelectionMode = (
    psmFirstActive,
    psmLatestActive,
    psmExact
  );

  TRtmpPreviewDropPolicy = (
    pdpDropOldest,
    pdpDropToLatestKeyframe
  );

  TRtmpPreviewPixelFormat = (
    ppfUnknown,
    ppfRgba32,
    ppfDrmPrime,
    ppfYuv420p
  );

  TRtmpPreviewPlaneInfo = record
    Offset: Integer;
    Stride: Integer;
    Width: Integer;
    Height: Integer;
  end;

  TRtmpPreviewConfig = record
    Server: TRtmpServerConfig;
    LogLevel: TRtmpLogLevel;
    OutputPixelFormat: TAVPixelFormat;
    DecoderThreadCount: Integer;
    DecoderThreadMode: TRtmpDecoderThreadMode;
    PassthroughHardwareFrames: Boolean;
    SelectionMode: TRtmpPreviewStreamSelectionMode;
    TargetStreamName: string;
    PacketQueueMax: Integer;
    PacketQueueMaxDurationMS: Cardinal;
    DropPolicy: TRtmpPreviewDropPolicy;
  end;

  TRtmpPreviewFrame = record
    StreamName: string;
    StreamPublisher: string;
    TimestampMS: Int64;
    ArrivalTick: UInt64;
    SequenceNo: UInt64;
    DecodeTick: UInt64;
    DecodeLatencyMS: UInt64;
    FrameIntervalMS: Integer;
    QueuePacketsAtEmit: Integer;
    QueueBytesAtEmit: UInt64;
    Width: Integer;
    Height: Integer;
    Stride: Integer;
    PixelFormat: TRtmpPreviewPixelFormat;
    PlaneCount: Integer;
    Planes: array[0..3] of TRtmpPreviewPlaneInfo;
    Codec: TRtmpDecoderCodec;
    HardwareFrame: IRtmpPreviewHardwareFrame;
    IsKeyframe: Boolean;
    Pixels: TBytes;
  end;

  TRtmpPreviewStats = record
    ActiveStreamName: string;
    ActivePublisher: string;
    QueuePackets: Integer;
    QueueBytes: UInt64;
    QueueDurationMS: Cardinal;
    QueuePacketsHighWater: Integer;
    QueueBytesHighWater: UInt64;
    QueueDurationHighWaterMS: Cardinal;
    EnqueuedPackets: UInt64;
    EnqueuedBytes: UInt64;
    ProcessedPackets: UInt64;
    ProcessedBytes: UInt64;
    DroppedPackets: UInt64;
    DroppedBytes: UInt64;
    DropEvents: UInt64;
    DropToLatestKeyframeEvents: UInt64;
    ConfigPacketsSeen: UInt64;
    DecoderOpenCount: UInt64;
    DeferredDecoderOpenAttempts: UInt64;
    DecoderSubmitErrors: UInt64;
    DecoderReceiveErrors: UInt64;
    ConvertErrors: UInt64;
    FramesDecoded: UInt64;
    SwitchCount: UInt64;
    SelectionRejects: UInt64;
    LastFrameTimestampMS: Int64;
    LastFrameSequenceNo: UInt64;
    LastFrameArrivalTick: UInt64;
    LastFrameDecodeTick: UInt64;
    LastFrameAgeMS: UInt64;
    MaxFrameAgeMS: UInt64;
    AverageFrameAgeMS: Double;
    LastDecoderSubmitMS: UInt64;
    LastDecoderReceiveMS: UInt64;
    LastConvertMS: UInt64;
    CurrentFPS: Double;
    AverageFPS: Double;
    Width: Integer;
    Height: Integer;
  end;

  TRtmpPreviewFrameEvent = procedure(Sender: TObject;
    const AFrame: TRtmpPreviewFrame) of object;
  TRtmpPreviewLogEvent = procedure(Sender: TObject; ALevel: TRtmpLogLevel;
    const ACategory, AMessage: string) of object;
  TRtmpPreviewStreamEvent = procedure(Sender: TObject; const AStreamName,
    ARemoteAddress: string; ARemotePort: Word) of object;

  TRtmpPreview = class
  private
    FActiveSessionKey: string;
    FConfig: TRtmpPreviewConfig;
    FConverter: TRtmpFFmpegFrameConverter;
    FCurrentPacketArrivalTick: UInt64;
    FCurrentPacketQueueBytes: UInt64;
    FCurrentPacketQueueDepth: Integer;
    FCurrentPacketSequenceNo: UInt64;
    FCumulativeFrameAgeMS: UInt64;
    FDecoder: TRtmpFFmpegPacketDecoder;
    FDrainFrame: PAVFrame;
    FLastReceiveDurationMS: UInt64;
    FLastSubmitDurationMS: UInt64;
    FLastDecodedFrameTimestampMS: Int64;
    FLastFpsFrames: UInt64;
    FLastFpsTick: UInt64;
    FLatestVideoConfig: TRtmpPacket;
    FLock: TCriticalSection;
    FOnFrame: TRtmpPreviewFrameEvent;
    FOnLog: TRtmpPreviewLogEvent;
    FOnStreamStarted: TRtmpPreviewStreamEvent;
    FOnStreamStopped: TRtmpPreviewStreamEvent;
    FPackets: TObjectList;
    FQueuedBytes: UInt64;
    FResetPending: Boolean;
    FSelectedPublisher: string;
    FSelectedRemoteAddress: string;
    FSelectedRemotePort: Word;
    FSelectedStreamName: string;
    FServer: TRtmpServer;
    FStartedAt: UInt64;
    FStats: TRtmpPreviewStats;
    FWaitingForVideoKeyframe: Boolean;
    procedure ApplyPendingReset;
    procedure ClearActiveSelectionLocked;
    procedure ClearPacketQueueLocked;
    procedure DrainDecodeFrames;
    procedure DrainPackets;
    procedure EmitFrame(const AInfo: TRtmpDecodedFrameInfo;
      const ASourceFrame: PAVFrame);
    procedure EmitLog(ALevel: TRtmpLogLevel; const ACategory, AMessage: string);
    procedure EnqueuePacket(APacket: TRtmpPacket);
    function GetStats: TRtmpPreviewStats;
    function QueuedDurationMSLocked: Cardinal;
    procedure HandleClientDisconnected(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleData(Sender: TObject; Session: TRtmpServerSession; Packet: TRtmpPacket);
    procedure HandlePublishStarted(Sender: TObject; Session: TRtmpServerSession);
    procedure HandlePublishStopped(Sender: TObject; Session: TRtmpServerSession);
    procedure HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
      const ACategory, AMessage: string);
    function MatchesSelection(const AStreamName: string): Boolean;
    function PublisherLabel(const Session: TRtmpServerSession): string;
    procedure ResetSessionStatsLocked;
    procedure ResetDecoderState;
    function SessionKey(const Session: TRtmpServerSession): string;
    function SessionStreamName(const Session: TRtmpServerSession): string;
    procedure TrimPacketQueueLocked;
    procedure UpdateFrameRateLocked(ANowTick: UInt64);
  public
    constructor Create;
    destructor Destroy; override;

    procedure ClearSelection;
    procedure FollowFirstActive;
    procedure FollowLatestActive;
    procedure Poll;
    procedure SelectStream(const AStreamName: string);
    procedure Start;
    procedure Stop;

    property Config: TRtmpPreviewConfig read FConfig write FConfig;
    property OnFrame: TRtmpPreviewFrameEvent read FOnFrame write FOnFrame;
    property OnLog: TRtmpPreviewLogEvent read FOnLog write FOnLog;
    property OnStreamStarted: TRtmpPreviewStreamEvent read FOnStreamStarted write FOnStreamStarted;
    property OnStreamStopped: TRtmpPreviewStreamEvent read FOnStreamStopped write FOnStreamStopped;
    property SelectedPublisher: string read FSelectedPublisher;
    property SelectedStreamName: string read FSelectedStreamName;
    property Server: TRtmpServer read FServer;
    property Stats: TRtmpPreviewStats read GetStats;
  end;

function DefaultRtmpPreviewConfig: TRtmpPreviewConfig;
function RtmpPreviewPixelFormatName(AFormat: TRtmpPreviewPixelFormat): string;

implementation

function PreviewPixelFormatFromAvPixelFormat(
  AFormat: TAVPixelFormat): TRtmpPreviewPixelFormat;
begin
  case AFormat of
    AV_PIX_FMT_RGBA:
      Result := ppfRgba32;
    AV_PIX_FMT_DRM_PRIME:
      Result := ppfDrmPrime;
    AV_PIX_FMT_YUV420P:
      Result := ppfYuv420p;
  else
    Result := ppfUnknown;
  end;
end;

function DefaultRtmpPreviewConfig: TRtmpPreviewConfig;
begin
  Result := Default(TRtmpPreviewConfig);
  Result.Server := DefaultRtmpServerConfig;
  Result.LogLevel := llInfo;
  Result.OutputPixelFormat := AV_PIX_FMT_RGBA;
  Result.DecoderThreadCount := 1;
  Result.DecoderThreadMode := dtmAuto;
  Result.PassthroughHardwareFrames := False;
  Result.SelectionMode := psmFirstActive;
  Result.TargetStreamName := '';
  Result.PacketQueueMax := 256;
  Result.PacketQueueMaxDurationMS := 250;
  Result.DropPolicy := pdpDropToLatestKeyframe;
end;

function RtmpPreviewPixelFormatName(AFormat: TRtmpPreviewPixelFormat): string;
begin
  case AFormat of
    ppfRgba32:
      Result := 'rgba32';
    ppfDrmPrime:
      Result := 'drm_prime';
    ppfYuv420p:
      Result := 'yuv420p';
  else
    Result := 'unknown';
  end;
end;

constructor TRtmpPreview.Create;
begin
  inherited Create;
  FConfig := DefaultRtmpPreviewConfig;
  FConverter := TRtmpFFmpegFrameConverter.Create(FConfig.OutputPixelFormat);
  FDecoder := TRtmpFFmpegPacketDecoder.Create;
  FDrainFrame := TRtmpFFmpegApi.AllocFrame;
  FDecoder.ThreadCount := FConfig.DecoderThreadCount;
  FDecoder.PassthroughHardwareFrames := FConfig.PassthroughHardwareFrames;
  FLatestVideoConfig := nil;
  FLock := TCriticalSection.Create;
  FPackets := TObjectList.Create(True);
  FResetPending := False;
  FSelectedStreamName := '';
  FSelectedPublisher := '';
  FSelectedRemoteAddress := '';
  FSelectedRemotePort := 0;
  FActiveSessionKey := '';
  FQueuedBytes := 0;
  FWaitingForVideoKeyframe := False;
  FCurrentPacketArrivalTick := 0;
  FCurrentPacketQueueBytes := 0;
  FCurrentPacketQueueDepth := 0;
  FCurrentPacketSequenceNo := 0;
  FCumulativeFrameAgeMS := 0;
  FLastReceiveDurationMS := 0;
  FLastSubmitDurationMS := 0;
  FStartedAt := RtmpGetTickCount64;
  FLastFpsTick := FStartedAt;
  FLastFpsFrames := 0;
  FLastDecodedFrameTimestampMS := -1;
  FStats := Default(TRtmpPreviewStats);
  FStats.LastFrameTimestampMS := -1;
  FWaitingForVideoKeyframe := False;

  FServer := TRtmpServer.Create;
  FServer.LogSink.OnLog := HandleServerLog;
  FServer.OnPublishStarted := HandlePublishStarted;
  FServer.OnPublishStopped := HandlePublishStopped;
  FServer.OnClientDisconnected := HandleClientDisconnected;
  FServer.OnData := HandleData;
end;

destructor TRtmpPreview.Destroy;
begin
  Stop;
  FreeAndNil(FLatestVideoConfig);
  FPackets.Free;
  FLock.Free;
  FConverter.Free;
  TRtmpFFmpegApi.FreeFrame(FDrainFrame);
  FDecoder.Free;
  FServer.Free;
  inherited Destroy;
end;

procedure TRtmpPreview.ResetSessionStatsLocked;
begin
  FStats := Default(TRtmpPreviewStats);
  FStats.LastFrameTimestampMS := -1;
  FLastDecodedFrameTimestampMS := -1;
  FLastReceiveDurationMS := 0;
  FLastSubmitDurationMS := 0;
  FCumulativeFrameAgeMS := 0;
  FLastFpsTick := RtmpGetTickCount64;
  FLastFpsFrames := 0;
end;

procedure TRtmpPreview.ApplyPendingReset;
var
  NeedReset: Boolean;
begin
  NeedReset := False;
  FLock.Acquire;
  try
    NeedReset := FResetPending;
    FResetPending := False;
  finally
    FLock.Release;
  end;

  if NeedReset then
    ResetDecoderState;
end;

procedure TRtmpPreview.ClearActiveSelectionLocked;
begin
  FActiveSessionKey := '';
  FSelectedStreamName := '';
  FSelectedPublisher := '';
  FSelectedRemoteAddress := '';
  FSelectedRemotePort := 0;
end;

procedure TRtmpPreview.ClearPacketQueueLocked;
begin
  FPackets.Clear;
  FQueuedBytes := 0;
  FStats.QueuePackets := 0;
  FStats.QueueBytes := 0;
  FStats.QueueDurationMS := 0;
end;

procedure TRtmpPreview.ClearSelection;
begin
  FollowFirstActive;
end;

procedure TRtmpPreview.DrainDecodeFrames;
var
  HaveFrame: Boolean;
  LatestFrameInfo: TRtmpDecodedFrameInfo;
  ReceiveStartedAt: UInt64;
  FrameInfo: TRtmpDecodedFrameInfo;
  ResultCode: Integer;
begin
  HaveFrame := False;
  while FDecoder.IsOpen do
  begin
    ReceiveStartedAt := RtmpGetTickCount64;
    ResultCode := FDecoder.ReceiveFrame(FrameInfo);
    FLastReceiveDurationMS := RtmpGetTickCount64 - ReceiveStartedAt;
    if (ResultCode = AVERROR_EAGAIN) or (ResultCode = AVERROR_EOF) then
      Break;
    if ResultCode < 0 then
    begin
      FLock.Acquire;
      try
        Inc(FStats.DecoderReceiveErrors);
      finally
        FLock.Release;
      end;
      EmitLog(llWarning, 'preview', 'Decode receive failed: ' + FDecoder.LastErrorText);
      Break;
    end;

    if HaveFrame then
      TRtmpFFmpegApi.UnrefFrame(FDrainFrame);
    av_frame_move_ref(FDrainFrame, FDecoder.Frame);
    LatestFrameInfo := FrameInfo;
    HaveFrame := True;
  end;

  if HaveFrame then
  begin
    EmitFrame(LatestFrameInfo, FDrainFrame);
    TRtmpFFmpegApi.UnrefFrame(FDrainFrame);
  end;
end;

procedure TRtmpPreview.DrainPackets;
var
  I: Integer;
  OpenResult: Boolean;
  Packet: TRtmpPacket;
  PacketSize: Integer;
  Pending: TObjectList;
  PendingBytes: UInt64;
  ResultCode: Integer;
  SubmitStartedAt: UInt64;
begin
  Pending := TObjectList.Create(True);
  try
    PendingBytes := 0;
    FLock.Acquire;
    try
      while FPackets.Count > 0 do
      begin
        Packet := TRtmpPacket(FPackets.Extract(FPackets[0]));
        Pending.Add(Packet);
        Inc(PendingBytes, UInt64(Packet.PayloadSize));
      end;
      FStats.QueuePackets := 0;
      FStats.QueueBytes := 0;
      FStats.QueueDurationMS := 0;
      FQueuedBytes := 0;
    finally
      FLock.Release;
    end;

    for I := 0 to Pending.Count - 1 do
    begin
      Packet := TRtmpPacket(Pending[I]);
      PacketSize := Packet.PayloadSize;

      FLock.Acquire;
      try
        Inc(FStats.ProcessedPackets);
        Inc(FStats.ProcessedBytes, UInt64(PacketSize));
        if Packet.HasFlag(pfIsCodecConfig) then
          Inc(FStats.ConfigPacketsSeen);
      finally
        FLock.Release;
      end;

      if Packet.HasFlag(pfIsCodecConfig) then
      begin
        OpenResult := FDecoder.OpenFromConfig(Packet);
        if OpenResult then
        begin
          FLock.Acquire;
          try
            Inc(FStats.DecoderOpenCount);
          finally
            FLock.Release;
          end;
        end
        else
          EmitLog(llWarning, 'preview', 'Video config open failed: ' + FDecoder.LastErrorText);

        Dec(PendingBytes, UInt64(PacketSize));
        Continue;
      end;

      if FWaitingForVideoKeyframe and Packet.HasFlag(pfIsVideo) then
      begin
        if not Packet.HasFlag(pfIsKeyframe) then
        begin
          FLock.Acquire;
          try
            Inc(FStats.DroppedPackets);
            Inc(FStats.DroppedBytes, UInt64(PacketSize));
            Inc(FStats.DropEvents);
          finally
            FLock.Release;
          end;
          Dec(PendingBytes, UInt64(PacketSize));
          Continue;
        end;

        FDecoder.Flush;
        FWaitingForVideoKeyframe := False;
        EmitLog(llInfo, 'preview', 'Decoder resynchronized on keyframe after backlog trim');
      end;

      if not FDecoder.IsOpen then
      begin
        if FLatestVideoConfig <> nil then
        begin
          FLock.Acquire;
          try
            Inc(FStats.DeferredDecoderOpenAttempts);
          finally
            FLock.Release;
          end;

          OpenResult := FDecoder.OpenFromConfig(FLatestVideoConfig);
          if not OpenResult then
          begin
            EmitLog(llWarning, 'preview',
              'Deferred video config open failed: ' + FDecoder.LastErrorText);
            Dec(PendingBytes, UInt64(PacketSize));
            Continue;
          end;

          FLock.Acquire;
          try
            Inc(FStats.DecoderOpenCount);
          finally
            FLock.Release;
          end;
        end
        else
        begin
          Dec(PendingBytes, UInt64(PacketSize));
          Continue;
        end;
      end;

      FCurrentPacketArrivalTick := Packet.ArrivalTick;
      FCurrentPacketSequenceNo := Packet.SequenceNo;
      FCurrentPacketQueueDepth := Pending.Count - I - 1;
      if PendingBytes >= UInt64(PacketSize) then
        FCurrentPacketQueueBytes := PendingBytes - UInt64(PacketSize)
      else
        FCurrentPacketQueueBytes := 0;

      SubmitStartedAt := RtmpGetTickCount64;
      ResultCode := FDecoder.SubmitPacket(Packet);
      FLastSubmitDurationMS := RtmpGetTickCount64 - SubmitStartedAt;
      if ResultCode < 0 then
      begin
        FLock.Acquire;
        try
          Inc(FStats.DecoderSubmitErrors);
        finally
          FLock.Release;
        end;
        EmitLog(llWarning, 'preview', 'Video packet submit failed: ' + FDecoder.LastErrorText);
        Dec(PendingBytes, UInt64(PacketSize));
        Continue;
      end;

      DrainDecodeFrames;
      Dec(PendingBytes, UInt64(PacketSize));
    end;
  finally
    Pending.Free;
  end;
end;

procedure TRtmpPreview.EmitFrame(const AInfo: TRtmpDecodedFrameInfo;
  const ASourceFrame: PAVFrame);
var
  ConvertStartedAt: UInt64;
  ConvertDurationMS: UInt64;
  Frame: TRtmpPreviewFrame;
  HardwareFrameData: IRtmpPreviewHardwareFrame;
  I: Integer;
  NowTick: UInt64;
begin
  if not Assigned(ASourceFrame) then
    Exit;

  ConvertDurationMS := 0;
  HardwareFrameData := nil;
  if FConfig.PassthroughHardwareFrames and
    (ASourceFrame^.format = Ord(AV_PIX_FMT_DRM_PRIME)) then
  begin
    HardwareFrameData := CreateDrmPrimeHardwareFrame(ASourceFrame);
    if not Assigned(HardwareFrameData) then
    begin
      FLock.Acquire;
      try
        Inc(FStats.ConvertErrors);
      finally
        FLock.Release;
      end;
      EmitLog(llWarning, 'preview',
        'Failed to build DRM_PRIME preview payload');
      Exit;
    end;
  end;
  if not Assigned(HardwareFrameData) then
  begin
    ConvertStartedAt := RtmpGetTickCount64;
    if not FConverter.ConvertVideoFrame(ASourceFrame) then
    begin
      FLock.Acquire;
      try
        Inc(FStats.ConvertErrors);
      finally
        FLock.Release;
      end;
      EmitLog(llWarning, 'preview',
        'Frame conversion failed: ' + FConverter.LastErrorText);
      Exit;
    end;
    ConvertDurationMS := RtmpGetTickCount64 - ConvertStartedAt;
  end;

  NowTick := RtmpGetTickCount64;
  Frame := Default(TRtmpPreviewFrame);
  Frame.StreamName := FSelectedStreamName;
  Frame.StreamPublisher := FSelectedPublisher;
  Frame.TimestampMS := AInfo.TimestampMS;
  Frame.ArrivalTick := FCurrentPacketArrivalTick;
  Frame.SequenceNo := FCurrentPacketSequenceNo;
  Frame.DecodeTick := NowTick;
  if (FLastDecodedFrameTimestampMS >= 0) and (AInfo.TimestampMS >= FLastDecodedFrameTimestampMS) then
    Frame.FrameIntervalMS := Integer(AInfo.TimestampMS - FLastDecodedFrameTimestampMS)
  else
    Frame.FrameIntervalMS := -1;
  if (Frame.ArrivalTick > 0) and (NowTick >= Frame.ArrivalTick) then
    Frame.DecodeLatencyMS := NowTick - Frame.ArrivalTick
  else
    Frame.DecodeLatencyMS := 0;
  Frame.QueuePacketsAtEmit := FCurrentPacketQueueDepth;
  Frame.QueueBytesAtEmit := FCurrentPacketQueueBytes;
  if Assigned(HardwareFrameData) then
  begin
    Frame.Width := ASourceFrame^.width;
    Frame.Height := ASourceFrame^.height;
    Frame.Stride := 0;
    Frame.PixelFormat := ppfDrmPrime;
    Frame.PlaneCount := 0;
    Frame.HardwareFrame := HardwareFrameData;
  end
  else
  begin
    Frame.Width := FConverter.Width;
    Frame.Height := FConverter.Height;
    Frame.Stride := FConverter.Stride;
    Frame.PixelFormat := PreviewPixelFormatFromAvPixelFormat(
      FConverter.DestinationFormat);
    Frame.PlaneCount := FConverter.PlaneCount;
    for I := 0 to Frame.PlaneCount - 1 do
    begin
      Frame.Planes[I].Offset := FConverter.PlaneOffset(I);
      Frame.Planes[I].Stride := FConverter.PlaneStride(I);
      Frame.Planes[I].Width := FConverter.PlaneWidth(I);
      Frame.Planes[I].Height := FConverter.PlaneHeight(I);
    end;
    SetLength(Frame.Pixels, FConverter.BufferSize);
    Move(FConverter.Buffer^, Frame.Pixels[0], FConverter.BufferSize);
  end;
  Frame.Codec := AInfo.Codec;
  Frame.IsKeyframe := AInfo.IsKeyframe;

  FLock.Acquire;
  try
    Inc(FStats.FramesDecoded);
    Inc(FCumulativeFrameAgeMS, Frame.DecodeLatencyMS);
    FStats.LastFrameTimestampMS := Frame.TimestampMS;
    FStats.LastFrameSequenceNo := Frame.SequenceNo;
    FStats.LastFrameArrivalTick := Frame.ArrivalTick;
    FStats.LastFrameDecodeTick := Frame.DecodeTick;
    FStats.LastFrameAgeMS := Frame.DecodeLatencyMS;
    if Frame.DecodeLatencyMS > FStats.MaxFrameAgeMS then
      FStats.MaxFrameAgeMS := Frame.DecodeLatencyMS;
    if FStats.FramesDecoded > 0 then
      FStats.AverageFrameAgeMS := FCumulativeFrameAgeMS / FStats.FramesDecoded
    else
      FStats.AverageFrameAgeMS := 0.0;
    FStats.LastDecoderSubmitMS := FLastSubmitDurationMS;
    FStats.LastDecoderReceiveMS := FLastReceiveDurationMS;
    FStats.LastConvertMS := ConvertDurationMS;
    FStats.Width := Frame.Width;
    FStats.Height := Frame.Height;
    UpdateFrameRateLocked(NowTick);
  finally
    FLock.Release;
  end;

  FLastDecodedFrameTimestampMS := Frame.TimestampMS;

  if Assigned(FOnFrame) then
    FOnFrame(Self, Frame);
end;

procedure TRtmpPreview.EmitLog(ALevel: TRtmpLogLevel; const ACategory,
  AMessage: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Self, ALevel, ACategory, AMessage);
end;

procedure TRtmpPreview.EnqueuePacket(APacket: TRtmpPacket);
var
  Clone: TRtmpPacket;
  PacketSize: Integer;
begin
  if APacket = nil then
    Exit;

  Clone := APacket.CloneShallow;
  PacketSize := Clone.PayloadSize;

  FLock.Acquire;
  try
    if Clone.HasFlag(pfIsCodecConfig) then
    begin
      FreeAndNil(FLatestVideoConfig);
      FLatestVideoConfig := Clone.CloneShallow;
    end;

    FPackets.Add(Clone);
    Inc(FQueuedBytes, UInt64(PacketSize));
    Inc(FStats.EnqueuedPackets);
    Inc(FStats.EnqueuedBytes, UInt64(PacketSize));
    TrimPacketQueueLocked;
    FStats.QueuePackets := FPackets.Count;
    FStats.QueueBytes := FQueuedBytes;
    FStats.QueueDurationMS := QueuedDurationMSLocked;
    if FPackets.Count > FStats.QueuePacketsHighWater then
      FStats.QueuePacketsHighWater := FPackets.Count;
    if FQueuedBytes > FStats.QueueBytesHighWater then
      FStats.QueueBytesHighWater := FQueuedBytes;
    if FStats.QueueDurationMS > FStats.QueueDurationHighWaterMS then
      FStats.QueueDurationHighWaterMS := FStats.QueueDurationMS;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpPreview.FollowFirstActive;
begin
  FLock.Acquire;
  try
    FConfig.SelectionMode := psmFirstActive;
    FConfig.TargetStreamName := '';
    if FActiveSessionKey = '' then
      ClearActiveSelectionLocked;
  finally
    FLock.Release;
  end;
  EmitLog(llInfo, 'preview', 'Selection mode set to first-active');
end;

procedure TRtmpPreview.FollowLatestActive;
begin
  FLock.Acquire;
  try
    FConfig.SelectionMode := psmLatestActive;
    FConfig.TargetStreamName := '';
    if FActiveSessionKey = '' then
      ClearActiveSelectionLocked;
  finally
    FLock.Release;
  end;
  EmitLog(llInfo, 'preview', 'Selection mode set to latest-active');
end;

function TRtmpPreview.GetStats: TRtmpPreviewStats;
var
  NowTick: UInt64;
begin
  NowTick := RtmpGetTickCount64;
  FLock.Acquire;
  try
    Result := FStats;
    Result.ActiveStreamName := FSelectedStreamName;
    Result.ActivePublisher := FSelectedPublisher;
    Result.QueuePackets := FPackets.Count;
    Result.QueueBytes := FQueuedBytes;
    Result.QueueDurationMS := QueuedDurationMSLocked;
    if (Result.LastFrameDecodeTick = 0) or ((NowTick - Result.LastFrameDecodeTick) > 1500) then
      Result.CurrentFPS := 0.0;
  finally
    FLock.Release;
  end;
end;

function TRtmpPreview.QueuedDurationMSLocked: Cardinal;
var
  FirstPacket: TRtmpPacket;
  LastPacket: TRtmpPacket;
  DurationMS: UInt64;
begin
  Result := 0;
  if FPackets.Count <= 1 then
    Exit;

  FirstPacket := TRtmpPacket(FPackets[0]);
  LastPacket := TRtmpPacket(FPackets[FPackets.Count - 1]);
  if (FirstPacket = nil) or (LastPacket = nil) then
    Exit;
  if LastPacket.Timestamp < FirstPacket.Timestamp then
    Exit;

  DurationMS := UInt64(LastPacket.Timestamp - FirstPacket.Timestamp);
  if DurationMS > High(Cardinal) then
    Result := High(Cardinal)
  else
    Result := Cardinal(DurationMS);
end;

procedure TRtmpPreview.HandleClientDisconnected(Sender: TObject;
  Session: TRtmpServerSession);
var
  NotifyStop: Boolean;
  StoppedAddress: string;
  StoppedPort: Word;
  StoppedStream: string;
begin
  NotifyStop := False;
  StoppedAddress := '';
  StoppedPort := 0;
  StoppedStream := '';

  FLock.Acquire;
  try
    if SessionKey(Session) = FActiveSessionKey then
    begin
      NotifyStop := True;
      StoppedAddress := FSelectedRemoteAddress;
      StoppedPort := FSelectedRemotePort;
      StoppedStream := FSelectedStreamName;
      ClearActiveSelectionLocked;
      FResetPending := True;
    end;
  finally
    FLock.Release;
  end;

  if NotifyStop and Assigned(FOnStreamStopped) then
    FOnStreamStopped(Self, StoppedStream, StoppedAddress, StoppedPort);
end;

procedure TRtmpPreview.HandleData(Sender: TObject; Session: TRtmpServerSession;
  Packet: TRtmpPacket);
begin
  if (Packet = nil) or (not Packet.HasFlag(pfIsVideo)) then
    Exit;
  if SessionKey(Session) <> FActiveSessionKey then
    Exit;
  EnqueuePacket(Packet);
end;

procedure TRtmpPreview.HandlePublishStarted(Sender: TObject;
  Session: TRtmpServerSession);
var
  NotifyStart: Boolean;
  NotifyStop: Boolean;
  PreviousAddress: string;
  PreviousPort: Word;
  PreviousStream: string;
  SessionId: string;
  ShouldSelect: Boolean;
  StreamName: string;
begin
  StreamName := SessionStreamName(Session);
  if not MatchesSelection(StreamName) then
  begin
    FLock.Acquire;
    try
      Inc(FStats.SelectionRejects);
    finally
      FLock.Release;
    end;
    Exit;
  end;

  SessionId := SessionKey(Session);
  NotifyStart := False;
  NotifyStop := False;
  PreviousAddress := '';
  PreviousPort := 0;
  PreviousStream := '';

  FLock.Acquire;
  try
    case FConfig.SelectionMode of
      psmFirstActive:
        ShouldSelect := FActiveSessionKey = '';
      psmLatestActive:
        ShouldSelect := SessionId <> FActiveSessionKey;
    else
      ShouldSelect := (FActiveSessionKey = '') or (SessionId <> FActiveSessionKey);
    end;

    if ShouldSelect then
    begin
      if (FActiveSessionKey <> '') and (FActiveSessionKey <> SessionId) then
      begin
        NotifyStop := True;
        PreviousAddress := FSelectedRemoteAddress;
        PreviousPort := FSelectedRemotePort;
        PreviousStream := FSelectedStreamName;
        Inc(FStats.SwitchCount);
      end;

      FActiveSessionKey := SessionId;
      FSelectedStreamName := StreamName;
      FSelectedRemoteAddress := Session.RemoteAddress;
      FSelectedRemotePort := Session.RemotePort;
      FSelectedPublisher := PublisherLabel(Session);
      ResetSessionStatsLocked;
      FResetPending := True;
      NotifyStart := True;
    end;
  finally
    FLock.Release;
  end;

  if NotifyStop and Assigned(FOnStreamStopped) then
    FOnStreamStopped(Self, PreviousStream, PreviousAddress, PreviousPort);
  if NotifyStart and Assigned(FOnStreamStarted) then
    FOnStreamStarted(Self, StreamName, Session.RemoteAddress, Session.RemotePort);
end;

procedure TRtmpPreview.HandlePublishStopped(Sender: TObject;
  Session: TRtmpServerSession);
var
  NotifyStop: Boolean;
  StoppedAddress: string;
  StoppedPort: Word;
  StoppedStream: string;
  StoppedKey: string;
begin
  StoppedKey := SessionKey(Session);
  NotifyStop := False;
  StoppedAddress := '';
  StoppedPort := 0;
  StoppedStream := '';

  FLock.Acquire;
  try
    if StoppedKey = FActiveSessionKey then
    begin
      NotifyStop := True;
      StoppedAddress := FSelectedRemoteAddress;
      StoppedPort := FSelectedRemotePort;
      StoppedStream := FSelectedStreamName;
      ClearActiveSelectionLocked;
      FResetPending := True;
    end;
  finally
    FLock.Release;
  end;

  if NotifyStop and Assigned(FOnStreamStopped) then
    FOnStreamStopped(Self, StoppedStream, StoppedAddress, StoppedPort);
end;

procedure TRtmpPreview.HandleServerLog(Sender: TObject; ALevel: TRtmpLogLevel;
  const ACategory, AMessage: string);
begin
  if ALevel >= FConfig.LogLevel then
    EmitLog(ALevel, ACategory, AMessage);
end;

function TRtmpPreview.MatchesSelection(const AStreamName: string): Boolean;
begin
  case FConfig.SelectionMode of
    psmExact:
      Result := SameText(AStreamName, FConfig.TargetStreamName);
  else
    Result := True;
  end;
end;

procedure TRtmpPreview.Poll;
begin
  ApplyPendingReset;
  DrainPackets;
end;

function TRtmpPreview.PublisherLabel(const Session: TRtmpServerSession): string;
begin
  if Session = nil then
    Exit('');
  Result := Format('%s:%d', [Session.RemoteAddress, Session.RemotePort]);
end;

procedure TRtmpPreview.ResetDecoderState;
begin
  FLock.Acquire;
  try
    ClearPacketQueueLocked;
    FreeAndNil(FLatestVideoConfig);
    FCurrentPacketArrivalTick := 0;
    FCurrentPacketQueueBytes := 0;
    FCurrentPacketQueueDepth := 0;
    FCurrentPacketSequenceNo := 0;
    FWaitingForVideoKeyframe := False;
    if Assigned(FDrainFrame) then
      TRtmpFFmpegApi.UnrefFrame(FDrainFrame);
    FLastReceiveDurationMS := 0;
    FLastSubmitDurationMS := 0;
    FLastDecodedFrameTimestampMS := -1;
    FStats.LastFrameTimestampMS := -1;
    FStats.LastFrameSequenceNo := 0;
    FStats.LastFrameArrivalTick := 0;
    FStats.LastFrameDecodeTick := 0;
    FStats.LastFrameAgeMS := 0;
    FStats.LastDecoderSubmitMS := 0;
    FStats.LastDecoderReceiveMS := 0;
    FStats.LastConvertMS := 0;
    FStats.CurrentFPS := 0.0;
    FStats.Width := 0;
    FStats.Height := 0;
    FLastFpsTick := RtmpGetTickCount64;
    FLastFpsFrames := FStats.FramesDecoded;
  finally
    FLock.Release;
  end;
  FDecoder.Close;
  FConverter.Close;
end;

procedure TRtmpPreview.SelectStream(const AStreamName: string);
begin
  FLock.Acquire;
  try
    FConfig.SelectionMode := psmExact;
    FConfig.TargetStreamName := AStreamName;
    if not SameText(FSelectedStreamName, AStreamName) then
    begin
      ClearActiveSelectionLocked;
      FResetPending := True;
    end;
  finally
    FLock.Release;
  end;
  EmitLog(llInfo, 'preview', Format('Selection mode set to exact stream "%s"',
    [AStreamName]));
end;

function TRtmpPreview.SessionKey(const Session: TRtmpServerSession): string;
begin
  if Session = nil then
    Exit('');
  Result := Format('%s:%d/%s', [Session.RemoteAddress, Session.RemotePort,
    SessionStreamName(Session)]);
end;

function TRtmpPreview.SessionStreamName(const Session: TRtmpServerSession): string;
begin
  if Session = nil then
    Exit('');
  Result := Session.StreamName;
  if Result = '' then
    Result := Session.LastPublishedStreamName;
end;

procedure TRtmpPreview.Start;
{$IFDEF UNIX}
var
  HwAccelReport: TLinuxHwAccelProbeReport;
{$ENDIF}
begin
  if FConverter.DestinationFormat <> FConfig.OutputPixelFormat then
  begin
    FConverter.Free;
    FConverter := TRtmpFFmpegFrameConverter.Create(FConfig.OutputPixelFormat);
  end;
  FDecoder.ThreadCount := FConfig.DecoderThreadCount;
  FDecoder.ThreadMode := FConfig.DecoderThreadMode;
  FDecoder.PassthroughHardwareFrames := FConfig.PassthroughHardwareFrames;

  FLock.Acquire;
  try
    ResetSessionStatsLocked;
    FStartedAt := RtmpGetTickCount64;
    FQueuedBytes := 0;
    FCurrentPacketArrivalTick := 0;
    FCurrentPacketQueueBytes := 0;
    FCurrentPacketQueueDepth := 0;
    FCurrentPacketSequenceNo := 0;
    ClearActiveSelectionLocked;
    ClearPacketQueueLocked;
    FreeAndNil(FLatestVideoConfig);
  finally
    FLock.Release;
  end;

  FServer.Config := FConfig.Server;
  FServer.MinLogLevel := FConfig.LogLevel;
  {$IFDEF UNIX}
  HwAccelReport := ProbeLinuxHwAccelReport;
  EmitLog(llInfo, 'ffmpeg', LinuxHwAccelReportSummary(HwAccelReport));
  {$ENDIF}
  FServer.Start;
end;

procedure TRtmpPreview.Stop;
begin
  FServer.Stop;
  FLock.Acquire;
  try
    ClearActiveSelectionLocked;
    FResetPending := False;
  finally
    FLock.Release;
  end;
  ResetDecoderState;
end;

procedure TRtmpPreview.TrimPacketQueueLocked;
var
  DropCount: Integer;
  DropBytes: UInt64;
  I: Integer;
  KeyframeIndex: Integer;
  OldPacket: TRtmpPacket;
  QueueDurationMS: Cardinal;
  NeedDecoderResync: Boolean;
begin
  NeedDecoderResync := False;
  if ((FConfig.PacketQueueMax <= 0) or (FPackets.Count <= FConfig.PacketQueueMax)) and
    ((FConfig.PacketQueueMaxDurationMS = 0) or
     (QueuedDurationMSLocked <= FConfig.PacketQueueMaxDurationMS)) then
    Exit;

  case FConfig.DropPolicy of
    pdpDropToLatestKeyframe:
      begin
        KeyframeIndex := -1;
        for I := FPackets.Count - 1 downto 0 do
          if TRtmpPacket(FPackets[I]).HasFlag(pfIsKeyframe) then
          begin
            KeyframeIndex := I;
            Break;
          end;

        if KeyframeIndex > 0 then
        begin
          DropBytes := 0;
          for I := 0 to KeyframeIndex - 1 do
            Inc(DropBytes, UInt64(TRtmpPacket(FPackets[I]).PayloadSize));
          Inc(FStats.DroppedPackets, UInt64(KeyframeIndex));
          Inc(FStats.DroppedBytes, DropBytes);
          Inc(FStats.DropEvents);
          Inc(FStats.DropToLatestKeyframeEvents);
          Dec(FQueuedBytes, DropBytes);
          for I := 0 to KeyframeIndex - 1 do
            FPackets.Delete(0);
        end;
      end;
  end;

  QueueDurationMS := QueuedDurationMSLocked;
  while (FConfig.PacketQueueMaxDurationMS > 0) and
    (QueueDurationMS > FConfig.PacketQueueMaxDurationMS) and
    (FPackets.Count > 1) do
  begin
    OldPacket := TRtmpPacket(FPackets[0]);
    if OldPacket <> nil then
    begin
      DropBytes := UInt64(OldPacket.PayloadSize);
      Dec(FQueuedBytes, DropBytes);
      Inc(FStats.DroppedPackets);
      Inc(FStats.DroppedBytes, DropBytes);
      Inc(FStats.DropEvents);
      if OldPacket.HasFlag(pfIsVideo) and
        not OldPacket.HasFlag(pfIsCodecConfig) then
        NeedDecoderResync := True;
    end;
    FPackets.Delete(0);
    QueueDurationMS := QueuedDurationMSLocked;
  end;

  if FPackets.Count > FConfig.PacketQueueMax then
  begin
    DropCount := FPackets.Count - FConfig.PacketQueueMax;
    DropBytes := 0;
    for I := 0 to DropCount - 1 do
      Inc(DropBytes, UInt64(TRtmpPacket(FPackets[I]).PayloadSize));
    Inc(FStats.DroppedPackets, UInt64(DropCount));
    Inc(FStats.DroppedBytes, DropBytes);
    Inc(FStats.DropEvents);
    if DropCount > 0 then
      NeedDecoderResync := True;
    Dec(FQueuedBytes, DropBytes);
    for I := 1 to DropCount do
      FPackets.Delete(0);
  end;

  if NeedDecoderResync then
  begin
    FPackets.Clear;
    FQueuedBytes := 0;
    FStats.QueuePackets := 0;
    FStats.QueueBytes := 0;
    FStats.QueueDurationMS := 0;
    FWaitingForVideoKeyframe := True;
  end;
end;

procedure TRtmpPreview.UpdateFrameRateLocked(ANowTick: UInt64);
var
  DeltaFrames: UInt64;
  DeltaMS: UInt64;
  UptimeMS: UInt64;
begin
  if FLastFpsTick = 0 then
  begin
    FLastFpsTick := ANowTick;
    FLastFpsFrames := FStats.FramesDecoded;
    Exit;
  end;

  DeltaMS := ANowTick - FLastFpsTick;
  if DeltaMS >= 1000 then
  begin
    DeltaFrames := FStats.FramesDecoded - FLastFpsFrames;
    FStats.CurrentFPS := (DeltaFrames * 1000.0) / DeltaMS;
    FLastFpsTick := ANowTick;
    FLastFpsFrames := FStats.FramesDecoded;
  end;

  UptimeMS := ANowTick - FStartedAt;
  if UptimeMS > 0 then
    FStats.AverageFPS := (FStats.FramesDecoded * 1000.0) / UptimeMS
  else
    FStats.AverageFPS := 0.0;
end;

end.

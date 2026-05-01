unit RtmpMediaPipeline;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  Classes,
  SyncObjs,
  SysUtils,
  libavutil_error,
  libavutil_pixfmt,
  RtmpCompat,
  RtmpDecoder,
  RtmpDecoderFFmpeg,
  RtmpFrameConvertFFmpeg,
  RtmpPacket,
  RtmpPipeline,
  RtmpTypes
  {$IFDEF USE_SFML}
  ,
  SfmlGraphics,
  SfmlSystem,
  SfmlWindow
  {$ENDIF};

type
  TRtmpDecodedVideoFrame = record
    SourceID: string;
    StreamName: string;
    TimestampMS: Int64;
    ArrivalTick: UInt64;
    DecodeTick: UInt64;
    DecodeLatencyMS: UInt64;
    SequenceNo: UInt64;
    Width: Integer;
    Height: Integer;
    Stride: Integer;
    Codec: TRtmpDecoderCodec;
    IsKeyframe: Boolean;
    Pixels: TBytes;
  end;

  TRtmpDecodedVideoFrameEvent = procedure(Sender: TObject;
    const AFrame: TRtmpDecodedVideoFrame) of object;

  TRtmpVideoDecodeStats = record
    StreamStarts: UInt64;
    StreamStops: UInt64;
    Packets: UInt64;
    ConfigPacketsSeen: UInt64;
    FramesDecoded: UInt64;
    DecoderOpenCount: UInt64;
    DecoderSubmitErrors: UInt64;
    DecoderReceiveErrors: UInt64;
    ConvertErrors: UInt64;
    ActiveSourceID: string;
    ActiveStreamName: string;
    LastFrameTimestampMS: Int64;
    LastFrameSequenceNo: UInt64;
    Width: Integer;
    Height: Integer;
  end;

  TRtmpVideoFrameSink = class
  public
    procedure HandleStreamStarted(const ASourceID, AStreamName: string); virtual;
    procedure HandleVideoFrame(const ASourceID: string;
      const AFrame: TRtmpDecodedVideoFrame); virtual; abstract;
    procedure HandleStreamStopped(const ASourceID, AStreamName: string); virtual;
  end;

  TRtmpVideoFrameNode = class(TRtmpVideoFrameSink)
  private
    FLock: TCriticalSection;
    FSinks: TList;
  protected
    procedure NotifyStreamStarted(const ASourceID, AStreamName: string);
    procedure NotifyVideoFrame(const ASourceID: string;
      const AFrame: TRtmpDecodedVideoFrame);
    procedure NotifyStreamStopped(const ASourceID, AStreamName: string);
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddSink(ASink: TRtmpVideoFrameSink);
    procedure RemoveSink(ASink: TRtmpVideoFrameSink);

    procedure HandleStreamStarted(const ASourceID, AStreamName: string); override;
    procedure HandleVideoFrame(const ASourceID: string;
      const AFrame: TRtmpDecodedVideoFrame); override;
    procedure HandleStreamStopped(const ASourceID, AStreamName: string); override;
  end;

  TRtmpVideoDecoderNode = class(TRtmpPacketSink)
  private
    FConverter: TRtmpFFmpegFrameConverter;
    FCurrentPacketArrivalTick: UInt64;
    FCurrentPacketSequenceNo: UInt64;
    FCurrentSourceID: string;
    FCurrentStreamName: string;
    FDecoder: TRtmpFFmpegPacketDecoder;
    FLatestVideoConfig: TRtmpPacket;
    FLock: TCriticalSection;
    FStats: TRtmpVideoDecodeStats;
    FVideoSinks: TList;
    procedure DrainFrames;
    procedure EmitFrame(const AInfo: TRtmpDecodedFrameInfo);
    function GetStats: TRtmpVideoDecodeStats;
    procedure NotifyStreamStarted(const ASourceID, AStreamName: string);
    procedure NotifyStreamStopped(const ASourceID, AStreamName: string);
    procedure NotifyVideoFrame(const ASourceID: string;
      const AFrame: TRtmpDecodedVideoFrame);
    procedure ResetDecoderState;
    procedure UpdateCurrentSource(const ASourceID, AStreamName: string);
  public
    constructor Create(ADestinationFormat: TAVPixelFormat = AV_PIX_FMT_RGBA);
    destructor Destroy; override;

    procedure AddSink(ASink: TRtmpVideoFrameSink);
    procedure RemoveSink(ASink: TRtmpVideoFrameSink);

    procedure HandleStreamStarted(const ASourceID, AStreamName: string); override;
    procedure HandlePacket(const ASourceID: string; APacket: TRtmpPacket); override;
    procedure HandleStreamStopped(const ASourceID, AStreamName: string); override;

    property Stats: TRtmpVideoDecodeStats read GetStats;
  end;

  TRtmpCallbackPlayerSink = class(TRtmpVideoFrameSink)
  private
    FOnFrame: TRtmpDecodedVideoFrameEvent;
  public
    procedure HandleVideoFrame(const ASourceID: string;
      const AFrame: TRtmpDecodedVideoFrame); override;
    property OnFrame: TRtmpDecodedVideoFrameEvent read FOnFrame write FOnFrame;
  end;

{$IFDEF USE_SFML}
  TRtmpSfmlScaleMode = (
    ssmFit,
    ssmFill,
    ssmStretch,
    ssmOneToOne
  );

  TRtmpSfmlPlayerSink = class(TRtmpVideoFrameSink)
  private
    FClearColor: TSfmlColor;
    FCurrentFrame: TRtmpDecodedVideoFrame;
    FFrameLock: TCriticalSection;
    FFramePending: Boolean;
    FInitialHeight: Cardinal;
    FInitialWidth: Cardinal;
    FPendingFrame: TRtmpDecodedVideoFrame;
    FScaleMode: TRtmpSfmlScaleMode;
    FSprite: TSfmlSprite;
    FTexture: TSfmlTexture;
    FWindow: TSfmlRenderWindow;
    FWindowTitleBase: AnsiString;
    procedure ApplyPendingFrame;
    procedure DestroyTextureObjects;
    procedure EnsureWindow;
    procedure LayoutSprite;
    procedure UpdateWindowTitle;
  public
    constructor Create(AWidth, AHeight: Cardinal; const ATitle: AnsiString);
    destructor Destroy; override;
    procedure HandleVideoFrame(const ASourceID: string;
      const AFrame: TRtmpDecodedVideoFrame); override;
    function IsOpen: Boolean;
    procedure ProcessEvents;
    procedure Render;

    property ClearColor: TSfmlColor read FClearColor write FClearColor;
    property ScaleMode: TRtmpSfmlScaleMode read FScaleMode write FScaleMode;
    property Window: TSfmlRenderWindow read FWindow;
  end;
{$ENDIF}

implementation

procedure TRtmpVideoFrameSink.HandleStreamStarted(const ASourceID,
  AStreamName: string);
begin
end;

procedure TRtmpVideoFrameSink.HandleStreamStopped(const ASourceID,
  AStreamName: string);
begin
end;

constructor TRtmpVideoFrameNode.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSinks := TList.Create;
end;

destructor TRtmpVideoFrameNode.Destroy;
begin
  FSinks.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRtmpVideoFrameNode.AddSink(ASink: TRtmpVideoFrameSink);
begin
  if ASink = nil then
    Exit;
  FLock.Acquire;
  try
    if FSinks.IndexOf(ASink) < 0 then
      FSinks.Add(ASink);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoFrameNode.RemoveSink(ASink: TRtmpVideoFrameSink);
begin
  FLock.Acquire;
  try
    FSinks.Remove(ASink);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoFrameNode.NotifyStreamStarted(const ASourceID,
  AStreamName: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FSinks.Count - 1 do
      TRtmpVideoFrameSink(FSinks[I]).HandleStreamStarted(ASourceID, AStreamName);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoFrameNode.NotifyVideoFrame(const ASourceID: string;
  const AFrame: TRtmpDecodedVideoFrame);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FSinks.Count - 1 do
      TRtmpVideoFrameSink(FSinks[I]).HandleVideoFrame(ASourceID, AFrame);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoFrameNode.NotifyStreamStopped(const ASourceID,
  AStreamName: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FSinks.Count - 1 do
      TRtmpVideoFrameSink(FSinks[I]).HandleStreamStopped(ASourceID, AStreamName);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoFrameNode.HandleStreamStarted(const ASourceID,
  AStreamName: string);
begin
  NotifyStreamStarted(ASourceID, AStreamName);
end;

procedure TRtmpVideoFrameNode.HandleVideoFrame(const ASourceID: string;
  const AFrame: TRtmpDecodedVideoFrame);
begin
  NotifyVideoFrame(ASourceID, AFrame);
end;

procedure TRtmpVideoFrameNode.HandleStreamStopped(const ASourceID,
  AStreamName: string);
begin
  NotifyStreamStopped(ASourceID, AStreamName);
end;

constructor TRtmpVideoDecoderNode.Create(ADestinationFormat: TAVPixelFormat);
begin
  inherited Create;
  FConverter := TRtmpFFmpegFrameConverter.Create(ADestinationFormat);
  FDecoder := TRtmpFFmpegPacketDecoder.Create;
  FLatestVideoConfig := nil;
  FLock := TCriticalSection.Create;
  FStats := Default(TRtmpVideoDecodeStats);
  FStats.LastFrameTimestampMS := -1;
  FCurrentPacketArrivalTick := 0;
  FCurrentPacketSequenceNo := 0;
  FCurrentSourceID := '';
  FCurrentStreamName := '';
  FVideoSinks := TList.Create;
end;

destructor TRtmpVideoDecoderNode.Destroy;
begin
  FreeAndNil(FLatestVideoConfig);
  FVideoSinks.Free;
  FLock.Free;
  FDecoder.Free;
  FConverter.Free;
  inherited Destroy;
end;

procedure TRtmpVideoDecoderNode.AddSink(ASink: TRtmpVideoFrameSink);
begin
  if ASink = nil then
    Exit;
  FLock.Acquire;
  try
    if FVideoSinks.IndexOf(ASink) < 0 then
      FVideoSinks.Add(ASink);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoDecoderNode.RemoveSink(ASink: TRtmpVideoFrameSink);
begin
  FLock.Acquire;
  try
    FVideoSinks.Remove(ASink);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoDecoderNode.NotifyStreamStarted(const ASourceID,
  AStreamName: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FVideoSinks.Count - 1 do
      TRtmpVideoFrameSink(FVideoSinks[I]).HandleStreamStarted(ASourceID, AStreamName);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoDecoderNode.NotifyStreamStopped(const ASourceID,
  AStreamName: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FVideoSinks.Count - 1 do
      TRtmpVideoFrameSink(FVideoSinks[I]).HandleStreamStopped(ASourceID, AStreamName);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoDecoderNode.NotifyVideoFrame(const ASourceID: string;
  const AFrame: TRtmpDecodedVideoFrame);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FVideoSinks.Count - 1 do
      TRtmpVideoFrameSink(FVideoSinks[I]).HandleVideoFrame(ASourceID, AFrame);
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoDecoderNode.ResetDecoderState;
begin
  FDecoder.Close;
  FCurrentPacketArrivalTick := 0;
  FCurrentPacketSequenceNo := 0;
end;

procedure TRtmpVideoDecoderNode.UpdateCurrentSource(const ASourceID,
  AStreamName: string);
begin
  if SameText(FCurrentSourceID, ASourceID) then
    Exit;
  ResetDecoderState;
  FCurrentSourceID := ASourceID;
  FCurrentStreamName := AStreamName;
  FLock.Acquire;
  try
    FStats.ActiveSourceID := ASourceID;
    FStats.ActiveStreamName := AStreamName;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoDecoderNode.DrainFrames;
var
  FrameInfo: TRtmpDecodedFrameInfo;
  ResultCode: Integer;
begin
  while FDecoder.IsOpen do
  begin
    ResultCode := FDecoder.ReceiveFrame(FrameInfo);
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
      Break;
    end;

    EmitFrame(FrameInfo);
    FDecoder.UnrefFrame;
  end;
end;

procedure TRtmpVideoDecoderNode.EmitFrame(const AInfo: TRtmpDecodedFrameInfo);
var
  Frame: TRtmpDecodedVideoFrame;
  NowTick: UInt64;
begin
  if not FConverter.ConvertVideoFrame(FDecoder.Frame) then
  begin
    FLock.Acquire;
    try
      Inc(FStats.ConvertErrors);
    finally
      FLock.Release;
    end;
    Exit;
  end;

  NowTick := RtmpGetTickCount64;
  Frame := Default(TRtmpDecodedVideoFrame);
  Frame.SourceID := FCurrentSourceID;
  Frame.StreamName := FCurrentStreamName;
  Frame.TimestampMS := AInfo.TimestampMS;
  Frame.ArrivalTick := FCurrentPacketArrivalTick;
  Frame.DecodeTick := NowTick;
  if (Frame.ArrivalTick > 0) and (NowTick >= Frame.ArrivalTick) then
    Frame.DecodeLatencyMS := NowTick - Frame.ArrivalTick
  else
    Frame.DecodeLatencyMS := 0;
  Frame.SequenceNo := FCurrentPacketSequenceNo;
  Frame.Width := FConverter.Width;
  Frame.Height := FConverter.Height;
  Frame.Stride := FConverter.Stride;
  Frame.Codec := AInfo.Codec;
  Frame.IsKeyframe := AInfo.IsKeyframe;
  SetLength(Frame.Pixels, FConverter.BufferSize);
  Move(FConverter.Buffer^, Frame.Pixels[0], FConverter.BufferSize);

  FLock.Acquire;
  try
    Inc(FStats.FramesDecoded);
    FStats.LastFrameTimestampMS := Frame.TimestampMS;
    FStats.LastFrameSequenceNo := Frame.SequenceNo;
    FStats.Width := Frame.Width;
    FStats.Height := Frame.Height;
  finally
    FLock.Release;
  end;

  NotifyVideoFrame(FCurrentSourceID, Frame);
end;

function TRtmpVideoDecoderNode.GetStats: TRtmpVideoDecodeStats;
begin
  FLock.Acquire;
  try
    Result := FStats;
  finally
    FLock.Release;
  end;
end;

procedure TRtmpVideoDecoderNode.HandleStreamStarted(const ASourceID,
  AStreamName: string);
begin
  UpdateCurrentSource(ASourceID, AStreamName);
  FLock.Acquire;
  try
    Inc(FStats.StreamStarts);
  finally
    FLock.Release;
  end;
  NotifyStreamStarted(ASourceID, AStreamName);
end;

procedure TRtmpVideoDecoderNode.HandlePacket(const ASourceID: string;
  APacket: TRtmpPacket);
begin
  if (APacket = nil) or (not APacket.HasFlag(pfIsVideo)) then
    Exit;

  UpdateCurrentSource(ASourceID, FCurrentStreamName);
  FLock.Acquire;
  try
    Inc(FStats.Packets);
    if APacket.HasFlag(pfIsCodecConfig) then
      Inc(FStats.ConfigPacketsSeen);
  finally
    FLock.Release;
  end;

  if APacket.HasFlag(pfIsCodecConfig) then
  begin
    FreeAndNil(FLatestVideoConfig);
    FLatestVideoConfig := APacket.CloneShallow;
    if FDecoder.OpenFromConfig(APacket) then
    begin
      FLock.Acquire;
      try
        Inc(FStats.DecoderOpenCount);
      finally
        FLock.Release;
      end;
    end;
    Exit;
  end;

  if not FDecoder.IsOpen then
  begin
    if (FLatestVideoConfig = nil) or (not FDecoder.OpenFromConfig(FLatestVideoConfig)) then
      Exit;
    FLock.Acquire;
    try
      Inc(FStats.DecoderOpenCount);
    finally
      FLock.Release;
    end;
  end;

  FCurrentPacketArrivalTick := APacket.ArrivalTick;
  FCurrentPacketSequenceNo := APacket.SequenceNo;
  if FDecoder.SubmitPacket(APacket) < 0 then
  begin
    FLock.Acquire;
    try
      Inc(FStats.DecoderSubmitErrors);
    finally
      FLock.Release;
    end;
    Exit;
  end;
  DrainFrames;
end;

procedure TRtmpVideoDecoderNode.HandleStreamStopped(const ASourceID,
  AStreamName: string);
begin
  if SameText(FCurrentSourceID, ASourceID) then
    ResetDecoderState;
  FLock.Acquire;
  try
    Inc(FStats.StreamStops);
  finally
    FLock.Release;
  end;
  NotifyStreamStopped(ASourceID, AStreamName);
end;

procedure TRtmpCallbackPlayerSink.HandleVideoFrame(const ASourceID: string;
  const AFrame: TRtmpDecodedVideoFrame);
begin
  if Assigned(FOnFrame) then
    FOnFrame(Self, AFrame);
end;

{$IFDEF USE_SFML}
constructor TRtmpSfmlPlayerSink.Create(AWidth, AHeight: Cardinal;
  const ATitle: AnsiString);
begin
  inherited Create;
  FClearColor := SfmlBlack;
  FCurrentFrame := Default(TRtmpDecodedVideoFrame);
  FPendingFrame := Default(TRtmpDecodedVideoFrame);
  FFrameLock := TCriticalSection.Create;
  FFramePending := False;
  FInitialHeight := AHeight;
  FInitialWidth := AWidth;
  FScaleMode := ssmFit;
  FSprite := nil;
  FTexture := nil;
  FWindow := nil;
  FWindowTitleBase := ATitle;
end;

destructor TRtmpSfmlPlayerSink.Destroy;
begin
  DestroyTextureObjects;
  FFrameLock.Free;
  FWindow.Free;
  inherited Destroy;
end;

procedure TRtmpSfmlPlayerSink.EnsureWindow;
var
  Mode: TSfmlVideoMode;
begin
  if FWindow <> nil then
    Exit;

  Mode := SfmlVideoMode(FInitialWidth, FInitialHeight, 32);
  FWindow := TSfmlRenderWindow.Create(Mode, FWindowTitleBase,
    sfClose or sfResize, sfWindowed);
  FWindow.SetVerticalSyncEnabled(True);
  FWindow.SetFramerateLimit(60);
end;

procedure TRtmpSfmlPlayerSink.ApplyPendingFrame;
var
  HasPending: Boolean;
  NextFrame: TRtmpDecodedVideoFrame;
begin
  HasPending := False;
  NextFrame := Default(TRtmpDecodedVideoFrame);
  FFrameLock.Acquire;
  try
    HasPending := FFramePending;
    if HasPending then
    begin
      NextFrame := FPendingFrame;
      FFramePending := False;
    end;
  finally
    FFrameLock.Release;
  end;

  if not HasPending then
    Exit;

  FCurrentFrame := NextFrame;
  if Length(FCurrentFrame.Pixels) = 0 then
    Exit;

  if (FTexture = nil) or (FCurrentFrame.Width <> Integer(FTexture.Size.X)) or
    (FCurrentFrame.Height <> Integer(FTexture.Size.Y)) then
  begin
    DestroyTextureObjects;
    FTexture := TSfmlTexture.Create(SfmlVector2u(Cardinal(FCurrentFrame.Width),
      Cardinal(FCurrentFrame.Height)));
    FSprite := TSfmlSprite.Create(FTexture);
  end;

  FTexture.UpdateFromPixels(@FCurrentFrame.Pixels[0], Cardinal(FCurrentFrame.Width),
    Cardinal(FCurrentFrame.Height), 0, 0);
  LayoutSprite;
  UpdateWindowTitle;
end;

procedure TRtmpSfmlPlayerSink.DestroyTextureObjects;
begin
  FreeAndNil(FSprite);
  FreeAndNil(FTexture);
end;

procedure TRtmpSfmlPlayerSink.HandleVideoFrame(const ASourceID: string;
  const AFrame: TRtmpDecodedVideoFrame);
begin
  FFrameLock.Acquire;
  try
    FPendingFrame := AFrame;
    FFramePending := True;
  finally
    FFrameLock.Release;
  end;
end;

function TRtmpSfmlPlayerSink.IsOpen: Boolean;
begin
  EnsureWindow;
  Result := (FWindow <> nil) and FWindow.IsOpen;
end;

procedure TRtmpSfmlPlayerSink.LayoutSprite;
var
  DestHeight: Single;
  DestWidth: Single;
  ScaleX: Single;
  ScaleY: Single;
  WindowSize: TSfmlVector2u;
begin
  if (FSprite = nil) or (FCurrentFrame.Width <= 0) or (FCurrentFrame.Height <= 0) then
    Exit;

  WindowSize := FWindow.Size;
  if (WindowSize.X = 0) or (WindowSize.Y = 0) then
    Exit;

  ScaleX := WindowSize.X / FCurrentFrame.Width;
  ScaleY := WindowSize.Y / FCurrentFrame.Height;
  case FScaleMode of
    ssmFill:
      begin
        if ScaleY > ScaleX then
          ScaleX := ScaleY
        else
          ScaleY := ScaleX;
      end;
    ssmStretch:
      ;
    ssmOneToOne:
      begin
        ScaleX := 1.0;
        ScaleY := 1.0;
      end;
  else
    begin
      if ScaleY < ScaleX then
        ScaleX := ScaleY
      else
        ScaleY := ScaleX;
    end;
  end;

  DestWidth := FCurrentFrame.Width * ScaleX;
  DestHeight := FCurrentFrame.Height * ScaleY;
  FSprite.ScaleFactor := SfmlVector2f(ScaleX, ScaleY);
  FSprite.Position := SfmlVector2f((WindowSize.X - DestWidth) * 0.5,
    (WindowSize.Y - DestHeight) * 0.5);
end;

procedure TRtmpSfmlPlayerSink.ProcessEvents;
var
  Event: TSfmlEvent;
begin
  EnsureWindow;
  while FWindow.PollEvent(Event) do
    if Event.EventType = sfEvtClosed then
      FWindow.Close;
end;

procedure TRtmpSfmlPlayerSink.Render;
begin
  EnsureWindow;
  ApplyPendingFrame;
  FWindow.Clear(FClearColor);
  if FSprite <> nil then
    FWindow.Draw(FSprite, nil);
  FWindow.Display;
end;

procedure TRtmpSfmlPlayerSink.UpdateWindowTitle;
var
  TitleText: string;
begin
  if FCurrentFrame.StreamName <> '' then
    TitleText := Format('%s - %s - %dx%d %s ts=%dms age=%dms seq=%d',
      [string(FWindowTitleBase), FCurrentFrame.StreamName, FCurrentFrame.Width,
       FCurrentFrame.Height, RtmpDecoderCodecName(FCurrentFrame.Codec),
       FCurrentFrame.TimestampMS, FCurrentFrame.DecodeLatencyMS,
       FCurrentFrame.SequenceNo])
  else
    TitleText := string(FWindowTitleBase);
  FWindow.SetTitle(AnsiString(TitleText));
end;
{$ENDIF}

end.

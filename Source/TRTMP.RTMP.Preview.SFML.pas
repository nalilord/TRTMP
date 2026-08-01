unit TRTMP.RTMP.Preview.SFML;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SyncObjs,
  SysUtils,
  TRTMP.RTMP.Decode,
  TRTMP.RTMP.Preview,
  SfmlGraphics,
  SfmlSystem,
  SfmlWindow;

type
  TRtmpSfmlScaleMode = (
    ssmFit,
    ssmFill,
    ssmStretch,
    ssmOneToOne
  );

  TRtmpSfmlPreviewRenderer = class
  private
    FClearColor: TSfmlColor;
    FCurrentFrame: TRtmpPreviewFrame;
    FFrameLock: TCriticalSection;
    FFramePending: Boolean;
    FPendingFrame: TRtmpPreviewFrame;
    FScaleMode: TRtmpSfmlScaleMode;
    FSprite: TSfmlSprite;
    FTexture: TSfmlTexture;
    FWindow: TSfmlRenderWindow;
    FWindowTitleBase: AnsiString;
    procedure ApplyPendingFrame;
    procedure DestroyTextureObjects;
    procedure LayoutSprite;
    procedure UpdateWindowTitle;
  public
    constructor Create(AWidth, AHeight: Cardinal; const ATitle: AnsiString);
    destructor Destroy; override;

    procedure HandleFrame(Sender: TObject; const AFrame: TRtmpPreviewFrame);
    function IsOpen: Boolean;
    procedure ProcessEvents;
    procedure Render;

    property ClearColor: TSfmlColor read FClearColor write FClearColor;
    property ScaleMode: TRtmpSfmlScaleMode read FScaleMode write FScaleMode;
    property Window: TSfmlRenderWindow read FWindow;
  end;

implementation

constructor TRtmpSfmlPreviewRenderer.Create(AWidth, AHeight: Cardinal;
  const ATitle: AnsiString);
var
  Mode: TSfmlVideoMode;
begin
  inherited Create;
  FClearColor:=SfmlBlack;
  FCurrentFrame:=Default(TRtmpPreviewFrame);
  FPendingFrame:=Default(TRtmpPreviewFrame);
  FFrameLock:=TCriticalSection.Create;
  FFramePending:=False;
  FScaleMode:=ssmFit;
  FSprite:=nil;
  FTexture:=nil;
  FWindowTitleBase:=ATitle;

  Mode:=SfmlVideoMode(AWidth, AHeight, 32);
  FWindow:=TSfmlRenderWindow.Create(Mode, ATitle, sfClose OR sfResize, sfWindowed);
  FWindow.SetVerticalSyncEnabled(True);
  FWindow.SetFramerateLimit(60);
end;

destructor TRtmpSfmlPreviewRenderer.Destroy;
begin
  DestroyTextureObjects;
  FFrameLock.Free;
  FWindow.Free;
  inherited Destroy;
end;

procedure TRtmpSfmlPreviewRenderer.ApplyPendingFrame;
var
  NextFrame: TRtmpPreviewFrame;
  HasPending: Boolean;
begin
  HasPending:=False;
  NextFrame:=Default(TRtmpPreviewFrame);

  FFrameLock.Acquire;
  try
    HasPending:=FFramePending;
    if HasPending then
    begin
      NextFrame:=FPendingFrame;
      FFramePending:=False;
    end;
  finally
    FFrameLock.Release;
  end;

  if NOT HasPending then
    Exit;

  FCurrentFrame:=NextFrame;
  if Length(FCurrentFrame.Pixels) = 0 then
    Exit;

  if (FTexture = nil) OR (FCurrentFrame.Width <> Integer(FTexture.Size.X)) OR
    (FCurrentFrame.Height <> Integer(FTexture.Size.Y)) then
  begin
    DestroyTextureObjects;
    FTexture:=TSfmlTexture.Create(SfmlVector2u(Cardinal(FCurrentFrame.Width),
      Cardinal(FCurrentFrame.Height)));
    FSprite:=TSfmlSprite.Create(FTexture);
  end;

  FTexture.UpdateFromPixels(@FCurrentFrame.Pixels[0], Cardinal(FCurrentFrame.Width),
    Cardinal(FCurrentFrame.Height), 0, 0);
  LayoutSprite;
  UpdateWindowTitle;
end;

procedure TRtmpSfmlPreviewRenderer.DestroyTextureObjects;
begin
  FreeAndNil(FSprite);
  FreeAndNil(FTexture);
end;

procedure TRtmpSfmlPreviewRenderer.HandleFrame(Sender: TObject;
  const AFrame: TRtmpPreviewFrame);
begin
  FFrameLock.Acquire;
  try
    FPendingFrame:=AFrame;
    FFramePending:=True;
  finally
    FFrameLock.Release;
  end;
end;

function TRtmpSfmlPreviewRenderer.IsOpen: Boolean;
begin
  Result:=(FWindow <> nil) AND FWindow.IsOpen;
end;

procedure TRtmpSfmlPreviewRenderer.LayoutSprite;
var
  DestHeight: Single;
  DestWidth: Single;
  ScaleX: Single;
  ScaleY: Single;
  WindowSize: TSfmlVector2u;
begin
  if (FSprite = nil) OR (FCurrentFrame.Width <= 0) OR (FCurrentFrame.Height <= 0) then
    Exit;

  WindowSize:=FWindow.Size;
  if (WindowSize.X = 0) OR (WindowSize.Y = 0) then
    Exit;

  ScaleX:=WindowSize.X / FCurrentFrame.Width;
  ScaleY:=WindowSize.Y / FCurrentFrame.Height;

  case FScaleMode of
    ssmFill:
      begin
        if ScaleY > ScaleX then
          ScaleX:=ScaleY
        else
          ScaleY:=ScaleX;
      end;
    ssmStretch:
      ;
    ssmOneToOne:
      begin
        ScaleX:=1.0;
        ScaleY:=1.0;
      end;
  else
    begin
      if ScaleY < ScaleX then
        ScaleX:=ScaleY
      else
        ScaleY:=ScaleX;
    end;
  end;

  DestWidth:=FCurrentFrame.Width * ScaleX;
  DestHeight:=FCurrentFrame.Height * ScaleY;
  FSprite.ScaleFactor:=SfmlVector2f(ScaleX, ScaleY);
  FSprite.Position:=SfmlVector2f((WindowSize.X - DestWidth) * 0.5,
    (WindowSize.Y - DestHeight) * 0.5);
end;

procedure TRtmpSfmlPreviewRenderer.ProcessEvents;
var
  Event: TSfmlEvent;
begin
  while FWindow.PollEvent(Event) do
    if Event.EventType = sfEvtClosed then
      FWindow.Close;
end;

procedure TRtmpSfmlPreviewRenderer.Render;
begin
  ApplyPendingFrame;
  FWindow.Clear(FClearColor);
  if FSprite <> nil then
    FWindow.Draw(FSprite, nil);
  FWindow.Display;
end;

procedure TRtmpSfmlPreviewRenderer.UpdateWindowTitle;
var
  TitleText: string;
begin
  if FCurrentFrame.StreamName <> '' then
    TitleText:=Format('%s - %s - %dx%d %s ts=%dms age=%dms seq=%d',
      [string(FWindowTitleBase), FCurrentFrame.StreamName, FCurrentFrame.Width,
       FCurrentFrame.Height, RtmpDecoderCodecName(FCurrentFrame.Codec),
       FCurrentFrame.TimestampMS, FCurrentFrame.DecodeLatencyMS,
       FCurrentFrame.SequenceNo])
  else
    TitleText:=string(FWindowTitleBase);

  FWindow.SetTitle(AnsiString(TitleText));
end;

end.

unit RtmpPreviewHardwareFrame;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  libavutil_frame;

const
  RTMP_PREVIEW_DRM_MAX_OBJECTS = 4;
  RTMP_PREVIEW_DRM_MAX_LAYERS = 4;
  RTMP_PREVIEW_DRM_MAX_PLANES = 4;

type
  TRtmpPreviewHardwareFrameKind = (
    phfkUnknown,
    phfkDrmPrime
  );

  TRtmpPreviewDrmObjectInfo = record
    Fd: Integer;
    Size: UInt64;
    FormatModifier: UInt64;
  end;

  TRtmpPreviewDrmPlaneInfo = record
    ObjectIndex: Integer;
    Offset: Int64;
    Pitch: Int64;
  end;

  TRtmpPreviewDrmLayerInfo = record
    Format: UInt32;
    PlaneCount: Integer;
    Planes: array[0..RTMP_PREVIEW_DRM_MAX_PLANES - 1] of TRtmpPreviewDrmPlaneInfo;
  end;

  IRtmpPreviewHardwareFrame = interface
    ['{6563B08D-6E71-4E45-AAB5-7A0548B4A8C4}']
    function Describe: string;
    function GetDrmFormat: UInt32;
    function GetHeight: Integer;
    function GetKind: TRtmpPreviewHardwareFrameKind;
    function GetLayerCount: Integer;
    function GetObjectCount: Integer;
    function GetObjectFd(AIndex: Integer): Integer;
    function GetObjectModifier(AIndex: Integer): UInt64;
    function GetObjectSize(AIndex: Integer): UInt64;
    function GetPlaneCount(ALayerIndex: Integer): Integer;
    function GetPlaneObjectIndex(ALayerIndex, APlaneIndex: Integer): Integer;
    function GetPlaneOffset(ALayerIndex, APlaneIndex: Integer): Int64;
    function GetPlanePitch(ALayerIndex, APlaneIndex: Integer): Int64;
    function GetWidth: Integer;
  end;

function CreateDrmPrimeHardwareFrame(
  const AFrame: PAVFrame): IRtmpPreviewHardwareFrame;

implementation

uses
  SysUtils,
  libavutil_pixfmt
  {$IFDEF UNIX}
  , BaseUnix,
  FfmpegLinuxDrmTypes
  {$ENDIF}
  ;

type
  TRtmpPreviewDrmPrimeHardwareFrame = class(TInterfacedObject,
    IRtmpPreviewHardwareFrame)
  private
    FDrmFormat: UInt32;
    FHeight: Integer;
    FLayerCount: Integer;
    FLayers: array[0..RTMP_PREVIEW_DRM_MAX_LAYERS - 1] of TRtmpPreviewDrmLayerInfo;
    FObjectCount: Integer;
    FObjects: array[0..RTMP_PREVIEW_DRM_MAX_OBJECTS - 1] of TRtmpPreviewDrmObjectInfo;
    FWidth: Integer;
  public
    destructor Destroy; override;
    function Describe: string;
    function GetDrmFormat: UInt32;
    function GetHeight: Integer;
    function GetKind: TRtmpPreviewHardwareFrameKind;
    function GetLayerCount: Integer;
    function GetObjectCount: Integer;
    function GetObjectFd(AIndex: Integer): Integer;
    function GetObjectModifier(AIndex: Integer): UInt64;
    function GetObjectSize(AIndex: Integer): UInt64;
    function GetPlaneCount(ALayerIndex: Integer): Integer;
    function GetPlaneObjectIndex(ALayerIndex, APlaneIndex: Integer): Integer;
    function GetPlaneOffset(ALayerIndex, APlaneIndex: Integer): Int64;
    function GetPlanePitch(ALayerIndex, APlaneIndex: Integer): Int64;
    function GetWidth: Integer;
    class function CreateFromFrame(
      const AFrame: PAVFrame): IRtmpPreviewHardwareFrame; static;
  end;

function DupFd(AFd: Integer): Integer;
begin
  {$IFDEF UNIX}
  Result := fpDup(AFd);
  {$ELSE}
  Result := -1;
  {$ENDIF}
end;

procedure CloseFd(var AFd: Integer);
begin
  {$IFDEF UNIX}
  if AFd >= 0 then
    fpClose(AFd);
  {$ENDIF}
  AFd := -1;
end;

function CreateDrmPrimeHardwareFrame(
  const AFrame: PAVFrame): IRtmpPreviewHardwareFrame;
begin
  Result := TRtmpPreviewDrmPrimeHardwareFrame.CreateFromFrame(AFrame);
end;

destructor TRtmpPreviewDrmPrimeHardwareFrame.Destroy;
var
  I: Integer;
begin
  for I := 0 to FObjectCount - 1 do
    CloseFd(FObjects[I].Fd);
  inherited Destroy;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.Describe: string;
begin
  Result := Format('DRM_PRIME %dx%d fmt=0x%x objects=%d layers=%d',
    [FWidth, FHeight, FDrmFormat, FObjectCount, FLayerCount]);
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetDrmFormat: UInt32;
begin
  Result := FDrmFormat;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetHeight: Integer;
begin
  Result := FHeight;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetKind: TRtmpPreviewHardwareFrameKind;
begin
  Result := phfkDrmPrime;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetLayerCount: Integer;
begin
  Result := FLayerCount;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetObjectCount: Integer;
begin
  Result := FObjectCount;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetObjectFd(AIndex: Integer): Integer;
begin
  if (AIndex < 0) or (AIndex >= FObjectCount) then
    Exit(-1);
  Result := FObjects[AIndex].Fd;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetObjectModifier(
  AIndex: Integer): UInt64;
begin
  if (AIndex < 0) or (AIndex >= FObjectCount) then
    Exit(0);
  Result := FObjects[AIndex].FormatModifier;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetObjectSize(
  AIndex: Integer): UInt64;
begin
  if (AIndex < 0) or (AIndex >= FObjectCount) then
    Exit(0);
  Result := FObjects[AIndex].Size;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetPlaneCount(
  ALayerIndex: Integer): Integer;
begin
  if (ALayerIndex < 0) or (ALayerIndex >= FLayerCount) then
    Exit(0);
  Result := FLayers[ALayerIndex].PlaneCount;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetPlaneObjectIndex(ALayerIndex,
  APlaneIndex: Integer): Integer;
begin
  if (ALayerIndex < 0) or (ALayerIndex >= FLayerCount) then
    Exit(-1);
  if (APlaneIndex < 0) or (APlaneIndex >= FLayers[ALayerIndex].PlaneCount) then
    Exit(-1);
  Result := FLayers[ALayerIndex].Planes[APlaneIndex].ObjectIndex;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetPlaneOffset(ALayerIndex,
  APlaneIndex: Integer): Int64;
begin
  if (ALayerIndex < 0) or (ALayerIndex >= FLayerCount) then
    Exit(0);
  if (APlaneIndex < 0) or (APlaneIndex >= FLayers[ALayerIndex].PlaneCount) then
    Exit(0);
  Result := FLayers[ALayerIndex].Planes[APlaneIndex].Offset;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetPlanePitch(ALayerIndex,
  APlaneIndex: Integer): Int64;
begin
  if (ALayerIndex < 0) or (ALayerIndex >= FLayerCount) then
    Exit(0);
  if (APlaneIndex < 0) or (APlaneIndex >= FLayers[ALayerIndex].PlaneCount) then
    Exit(0);
  Result := FLayers[ALayerIndex].Planes[APlaneIndex].Pitch;
end;

function TRtmpPreviewDrmPrimeHardwareFrame.GetWidth: Integer;
begin
  Result := FWidth;
end;

{$IFDEF UNIX}
class function TRtmpPreviewDrmPrimeHardwareFrame.CreateFromFrame(
  const AFrame: PAVFrame): IRtmpPreviewHardwareFrame;
var
  Descriptor: PAVDRMFrameDescriptor;
  FrameData: TRtmpPreviewDrmPrimeHardwareFrame;
  I: Integer;
  J: Integer;
begin
  Result := nil;
  if not Assigned(AFrame) then
    Exit;
  if AFrame^.format <> Ord(AV_PIX_FMT_DRM_PRIME) then
    Exit;

  Descriptor := PAVDRMFrameDescriptor(AFrame^.data[0]);
  if not Assigned(Descriptor) then
    Exit;
  if (Descriptor^.nb_objects <= 0) or (Descriptor^.nb_layers <= 0) then
    Exit;

  FrameData := TRtmpPreviewDrmPrimeHardwareFrame.Create;
  FrameData.FWidth := AFrame^.width;
  FrameData.FHeight := AFrame^.height;
  FrameData.FObjectCount := Descriptor^.nb_objects;
  if FrameData.FObjectCount > RTMP_PREVIEW_DRM_MAX_OBJECTS then
    FrameData.FObjectCount := RTMP_PREVIEW_DRM_MAX_OBJECTS;
  FrameData.FLayerCount := Descriptor^.nb_layers;
  if FrameData.FLayerCount > RTMP_PREVIEW_DRM_MAX_LAYERS then
    FrameData.FLayerCount := RTMP_PREVIEW_DRM_MAX_LAYERS;

  for I := 0 to FrameData.FObjectCount - 1 do
  begin
    FrameData.FObjects[I].Fd := DupFd(Descriptor^.objects[I].fd);
    FrameData.FObjects[I].Size := Descriptor^.objects[I].size;
    FrameData.FObjects[I].FormatModifier :=
      Descriptor^.objects[I].format_modifier;
  end;

  for I := 0 to FrameData.FLayerCount - 1 do
  begin
    FrameData.FLayers[I].Format := Descriptor^.layers[I].format;
    if I = 0 then
      FrameData.FDrmFormat := FrameData.FLayers[I].Format;
    FrameData.FLayers[I].PlaneCount := Descriptor^.layers[I].nb_planes;
    if FrameData.FLayers[I].PlaneCount > RTMP_PREVIEW_DRM_MAX_PLANES then
      FrameData.FLayers[I].PlaneCount := RTMP_PREVIEW_DRM_MAX_PLANES;
    for J := 0 to FrameData.FLayers[I].PlaneCount - 1 do
    begin
      FrameData.FLayers[I].Planes[J].ObjectIndex :=
        Descriptor^.layers[I].planes[J].object_index;
      FrameData.FLayers[I].Planes[J].Offset :=
        Descriptor^.layers[I].planes[J].offset;
      FrameData.FLayers[I].Planes[J].Pitch :=
        Descriptor^.layers[I].planes[J].pitch;
    end;
  end;

  Result := FrameData;
end;
{$ELSE}
class function TRtmpPreviewDrmPrimeHardwareFrame.CreateFromFrame(
  const AFrame: PAVFrame): IRtmpPreviewHardwareFrame;
begin
  Result := nil;
end;
{$ENDIF}

end.

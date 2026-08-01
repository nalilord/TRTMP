program RtmpRelayPolicySmoke;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
  {$IFDEF UNIX}
  {$IFDEF FPC}
  cthreads,
  {$ENDIF}
  {$ENDIF}
  SysUtils,
  TRTMP.RTMP.Media.Buffer,
  TRTMP.RTMP.Media.Packet,
  TRTMP.RTMP.Pipeline,
  TRTMP.RTMP.Types;

type
  TRelayPolicySmoke = class
  private
    FAudioBuffer: TRtmpCircularBuffer;
    FAudioPolicy: TRtmpRelayPolicyNode;
    FAudioSink: TRtmpBufferSink;
    FRoot: TRtmpPacketTeeNode;
    FVideoBuffer: TRtmpCircularBuffer;
    FVideoPolicy: TRtmpRelayPolicyNode;
    FVideoSink: TRtmpBufferSink;
    procedure AssertTrue(const AMessage: string; AValue: Boolean);
    procedure FeedPacket(ARoot: TRtmpPacketTeeNode; const ASourceID: string;
      AMessageType: TRtmpMessageType; ATimestamp: UInt32; ASequenceNo: UInt64;
      const APayload: TBytes; AFlags: TRtmpPacketFlags; AChunkStreamID: UInt32 = 6);
    procedure RunScenario;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

function Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  Result:=nil;
  SetLength(Result, Length(AValues));
  for I:=0 to High(AValues) do
    Result[I]:=AValues[I];
end;

constructor TRelayPolicySmoke.Create;
var
  Policy: TRtmpRelayPolicy;
begin
  inherited Create;
  FAudioBuffer:=TRtmpCircularBuffer.Create(64, 1024 * 1024, 5000);
  FAudioPolicy:=TRtmpRelayPolicyNode.Create;
  FAudioSink:=TRtmpBufferSink.Create(FAudioBuffer);
  FRoot:=TRtmpPacketTeeNode.Create;
  FVideoBuffer:=TRtmpCircularBuffer.Create(64, 1024 * 1024, 5000);
  FVideoPolicy:=TRtmpRelayPolicyNode.Create;
  FVideoSink:=TRtmpBufferSink.Create(FVideoBuffer);

  Policy:=TRtmpRelayPolicy.CreateDefault;
  Policy.AllowMetadata:=False;
  Policy.AllowAudio:=True;
  Policy.AllowVideo:=False;
  FAudioPolicy.Policy:=Policy;

  Policy:=TRtmpRelayPolicy.CreateDefault;
  Policy.AllowMetadata:=True;
  Policy.AllowAudio:=False;
  Policy.AllowVideo:=True;
  Policy.WaitForKeyframe:=True;
  FVideoPolicy.Policy:=Policy;

  FRoot.AddSink(FAudioPolicy);
  FRoot.AddSink(FVideoPolicy);
  FAudioPolicy.AddSink(FAudioSink);
  FVideoPolicy.AddSink(FVideoSink);
end;

destructor TRelayPolicySmoke.Destroy;
begin
  FVideoSink.Free;
  FVideoPolicy.Free;
  FVideoBuffer.Free;
  FRoot.Free;
  FAudioSink.Free;
  FAudioPolicy.Free;
  FAudioBuffer.Free;
  inherited Destroy;
end;

procedure TRelayPolicySmoke.AssertTrue(const AMessage: string; AValue: Boolean);
begin
  if NOT AValue then
    raise Exception.Create(AMessage);
end;

procedure TRelayPolicySmoke.FeedPacket(ARoot: TRtmpPacketTeeNode;
  const ASourceID: string; AMessageType: TRtmpMessageType; ATimestamp: UInt32;
  ASequenceNo: UInt64; const APayload: TBytes; AFlags: TRtmpPacketFlags;
  AChunkStreamID: UInt32);
var
  Packet: TRtmpPacket;
begin
  Packet:=TRtmpPacket.Create(AMessageType, ATimestamp, 0, 1, AChunkStreamID,
    TRtmpSharedPayload.Create(APayload), AFlags, ASequenceNo);
  try
    ARoot.HandlePacket(ASourceID, Packet);
  finally
    Packet.Free;
  end;
end;

procedure TRelayPolicySmoke.RunScenario;
var
  AudioPackets: TRtmpPacketArray;
  VideoPackets: TRtmpPacketArray;
begin
  FRoot.HandleStreamStarted('program', 'live/test');
  FeedPacket(FRoot, 'program', mtDataAMF0, 0, 1, Bytes([$02]), [pfIsMetadata], 5);
  FeedPacket(FRoot, 'program', mtAudio, 0, 2, Bytes([$AF, $00]),
    [pfIsAudio, pfIsCodecConfig], 4);
  FeedPacket(FRoot, 'program', mtVideo, 0, 3, Bytes([$17, $00]),
    [pfIsVideo, pfIsCodecConfig], 6);
  FeedPacket(FRoot, 'program', mtVideo, 20, 4, Bytes([$27, $01]),
    [pfIsVideo], 6);
  FeedPacket(FRoot, 'program', mtAudio, 40, 5, Bytes([$AF, $01]),
    [pfIsAudio], 4);
  FeedPacket(FRoot, 'program', mtVideo, 60, 6, Bytes([$17, $01]),
    [pfIsVideo, pfIsKeyframe], 6);
  FRoot.HandleStreamStopped('program', 'live/test');

  AudioPackets:=FAudioBuffer.GetSnapshot;
  VideoPackets:=FVideoBuffer.GetSnapshot;

  AssertTrue('audio branch should only contain audio packets', Length(AudioPackets) = 2);
  AssertTrue('audio config packet should be first', AudioPackets[0].HasFlag(pfIsCodecConfig));
  AssertTrue('audio media packet should be second', NOT AudioPackets[1].HasFlag(pfIsCodecConfig));

  AssertTrue('video branch should keep metadata and wait for keyframe', Length(VideoPackets) = 3);
  AssertTrue('metadata should be forwarded', VideoPackets[0].HasFlag(pfIsMetadata));
  AssertTrue('video config should be forwarded', VideoPackets[1].HasFlag(pfIsCodecConfig));
  AssertTrue('first forwarded video frame should be keyframe',
    VideoPackets[2].HasFlag(pfIsKeyframe));
end;

procedure TRelayPolicySmoke.Run;
begin
  RunScenario;
  WriteLn('Relay policy smoke passed.');
end;

var
  Smoke: TRelayPolicySmoke;

begin
  Smoke:=TRelayPolicySmoke.Create;
  try
    Smoke.Run;
  finally
    Smoke.Free;
  end;
end.

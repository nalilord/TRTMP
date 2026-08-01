unit TRTMP.RTMP.Media.Packet;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils,
  TRTMP.Core.Compat,
  TRTMP.RTMP.Types;

type
  IRtmpPayload = interface(IInterface)
    ['{4A992C56-BF8E-46C3-8A58-E3D62C4C7FA9}']
    function GetBytes: TBytes;
    function GetSize: Integer;
    property Bytes: TBytes read GetBytes;
    property Size: Integer read GetSize;
  end;

  TRtmpSharedPayload = class(TInterfacedObject, IRtmpPayload)
  private
    FBytes: TBytes;
  protected
    function GetBytes: TBytes;
    function GetSize: Integer;
  public
    constructor Create(const ABytes: TBytes); overload;
    constructor Create(ASize: Integer); overload;
  end;

  TRtmpPacket = class
  private
    FMessageType: TRtmpMessageType;
    FTimestamp: UInt32;
    FTimestampDelta: UInt32;
    FMessageStreamID: UInt32;
    FChunkStreamID: UInt32;
    FPayload: IRtmpPayload;
    FFlags: TRtmpPacketFlags;
    FArrivalTick: TRtmpTick;
    FSequenceNo: UInt64;
  public
    constructor Create(AMessageType: TRtmpMessageType; ATimestamp,
      ATimestampDelta, AMessageStreamID, AChunkStreamID: UInt32;
      const APayload: IRtmpPayload; AFlags: TRtmpPacketFlags;
      ASequenceNo: UInt64; AArrivalTick: TRtmpTick = 0);

    function CloneShallow: TRtmpPacket;
    function HasFlag(AFlag: TRtmpPacketFlag): Boolean;
    function PayloadSize: Integer;

    property MessageType: TRtmpMessageType read FMessageType;
    property Timestamp: UInt32 read FTimestamp;
    property TimestampDelta: UInt32 read FTimestampDelta;
    property MessageStreamID: UInt32 read FMessageStreamID;
    property ChunkStreamID: UInt32 read FChunkStreamID;
    property Payload: IRtmpPayload read FPayload;
    property Flags: TRtmpPacketFlags read FFlags;
    property ArrivalTick: TRtmpTick read FArrivalTick;
    property SequenceNo: UInt64 read FSequenceNo;
  end;

  TRtmpPacketArray = array of TRtmpPacket;

implementation

constructor TRtmpSharedPayload.Create(const ABytes: TBytes);
begin
  inherited Create;
  FBytes:=ABytes;
end;

constructor TRtmpSharedPayload.Create(ASize: Integer);
begin
  inherited Create;
  SetLength(FBytes, ASize);
end;

function TRtmpSharedPayload.GetBytes: TBytes;
begin
  Result:=FBytes;
end;

function TRtmpSharedPayload.GetSize: Integer;
begin
  Result:=Length(FBytes);
end;

constructor TRtmpPacket.Create(AMessageType: TRtmpMessageType; ATimestamp,
  ATimestampDelta, AMessageStreamID, AChunkStreamID: UInt32;
  const APayload: IRtmpPayload; AFlags: TRtmpPacketFlags;
  ASequenceNo: UInt64; AArrivalTick: TRtmpTick);
begin
  inherited Create;
  FMessageType:=AMessageType;
  FTimestamp:=ATimestamp;
  FTimestampDelta:=ATimestampDelta;
  FMessageStreamID:=AMessageStreamID;
  FChunkStreamID:=AChunkStreamID;
  FPayload:=APayload;
  FFlags:=AFlags;
  FSequenceNo:=ASequenceNo;
  if AArrivalTick = 0 then
    FArrivalTick:=RtmpGetTickCount64
  else
    FArrivalTick:=AArrivalTick;
end;

function TRtmpPacket.CloneShallow: TRtmpPacket;
begin
  Result:=TRtmpPacket.Create(FMessageType, FTimestamp, FTimestampDelta,
    FMessageStreamID, FChunkStreamID, FPayload, FFlags, FSequenceNo,
    FArrivalTick);
end;

function TRtmpPacket.HasFlag(AFlag: TRtmpPacketFlag): Boolean;
begin
  Result:=AFlag IN FFlags;
end;

function TRtmpPacket.PayloadSize: Integer;
begin
  if Assigned(FPayload) then
    Result:=FPayload.Size
  else
    Result:=0;
end;

end.

unit RtmpTransport;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils;

type
  ERtmpTransportError = class(Exception);

  TRtmpSocketEndpoint = record
    Address: string;
    Port: Word;
    class function Create(const AAddress: string; APort: Word): TRtmpSocketEndpoint; static;
  end;

  IRtmpConnection = interface(IInterface)
    ['{27D0697A-59B4-4611-95DE-51D71033D2FC}']
    procedure Close;
    function GetConnected: Boolean;
    function GetLocalEndpoint: TRtmpSocketEndpoint;
    function GetRemoteEndpoint: TRtmpSocketEndpoint;
    function Receive(var ABuffer; ACount: Integer; ATimeoutMS: Integer): Integer;
    function Send(const ABuffer; ACount: Integer; ATimeoutMS: Integer): Integer;

    property Connected: Boolean read GetConnected;
    property LocalEndpoint: TRtmpSocketEndpoint read GetLocalEndpoint;
    property RemoteEndpoint: TRtmpSocketEndpoint read GetRemoteEndpoint;
  end;

  IRtmpListener = interface(IInterface)
    ['{C8454E64-3D2E-439B-B1A7-AB893DD8F6E7}']
    function Accept(ATimeoutMS: Integer): IRtmpConnection;
    procedure Close;
    function GetBoundEndpoint: TRtmpSocketEndpoint;
    function GetListening: Boolean;

    property BoundEndpoint: TRtmpSocketEndpoint read GetBoundEndpoint;
    property Listening: Boolean read GetListening;
  end;

  IRtmpTransportFactory = interface(IInterface)
    ['{FFCA3299-136E-455E-B25F-E75D6E91495E}']
    function CreateClientConnection(const ARemoteEndpoint: TRtmpSocketEndpoint;
      AConnectTimeoutMS: Integer): IRtmpConnection;
    function CreateListener(const ABindEndpoint: TRtmpSocketEndpoint;
      ABacklog: Integer): IRtmpListener;
    function Description: string;
  end;

  TRtmpNullTransportFactory = class(TInterfacedObject, IRtmpTransportFactory)
  public
    function CreateClientConnection(const ARemoteEndpoint: TRtmpSocketEndpoint;
      AConnectTimeoutMS: Integer): IRtmpConnection;
    function CreateListener(const ABindEndpoint: TRtmpSocketEndpoint;
      ABacklog: Integer): IRtmpListener;
    function Description: string;
  end;

implementation

class function TRtmpSocketEndpoint.Create(const AAddress: string;
  APort: Word): TRtmpSocketEndpoint;
begin
  Result.Address := AAddress;
  Result.Port := APort;
end;

function TRtmpNullTransportFactory.CreateClientConnection(
  const ARemoteEndpoint: TRtmpSocketEndpoint; AConnectTimeoutMS: Integer): IRtmpConnection;
begin
  Result := nil;
  raise ERtmpTransportError.CreateFmt(
    'No transport factory implementation is installed for outbound connection to %s:%d',
    [ARemoteEndpoint.Address, ARemoteEndpoint.Port]);
end;

function TRtmpNullTransportFactory.CreateListener(
  const ABindEndpoint: TRtmpSocketEndpoint; ABacklog: Integer): IRtmpListener;
begin
  Result := nil;
  raise ERtmpTransportError.CreateFmt(
    'No transport factory implementation is installed for listener bind %s:%d',
    [ABindEndpoint.Address, ABindEndpoint.Port]);
end;

function TRtmpNullTransportFactory.Description: string;
begin
  Result := 'unassigned transport factory';
end;

end.

unit TRTMP.Transport.TLS;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  TRTMP.Transport;

type
  TRtmpTlsVersion = (
    tlsVersion12,
    tlsVersion13
  );

  TRtmpTlsClientOptions = record
    VerifyPeer: Boolean;
    ServerName: string;
    CAFile: string;
    CAPath: string;
    CertificateFile: string;
    CertificatePassword: string;
    PrivateKeyFile: string;
    MinimumVersion: TRtmpTlsVersion;
    class function CreateDefault: TRtmpTlsClientOptions; static;
  end;

  TRtmpTlsServerOptions = record
    Enabled: Boolean;
    CertificateFile: string;
    CertificatePassword: string;
    PrivateKeyFile: string;
    CAFile: string;
    CAPath: string;
    RequireClientCertificate: Boolean;
    MinimumVersion: TRtmpTlsVersion;
    class function CreateDefault: TRtmpTlsServerOptions; static;
  end;

  IRtmpTlsTransportFactory = interface(IInterface)
    ['{99B00FE2-E646-4C25-879B-3669434155B7}']
    function CreateTlsClientConnection(
      const ARemoteEndpoint: TRtmpSocketEndpoint;
      const AOptions: TRtmpTlsClientOptions;
      AConnectTimeoutMS: Integer): IRtmpConnection;
    function CreateTlsListener(const ABindEndpoint: TRtmpSocketEndpoint;
      ABacklog: Integer; const AOptions: TRtmpTlsServerOptions): IRtmpListener;
    function TlsDescription: string;
  end;

function RtmpTlsVersionName(AVersion: TRtmpTlsVersion): string;

implementation

class function TRtmpTlsClientOptions.CreateDefault: TRtmpTlsClientOptions;
begin
  Result:=Default(TRtmpTlsClientOptions);
  Result.VerifyPeer:=True;
  Result.MinimumVersion:=tlsVersion12;
end;

class function TRtmpTlsServerOptions.CreateDefault: TRtmpTlsServerOptions;
begin
  Result:=Default(TRtmpTlsServerOptions);
  Result.Enabled:=False;
  Result.RequireClientCertificate:=False;
  Result.MinimumVersion:=tlsVersion12;
end;

function RtmpTlsVersionName(AVersion: TRtmpTlsVersion): string;
begin
  case AVersion of
    tlsVersion12: Result:='TLS 1.2';
    tlsVersion13: Result:='TLS 1.3';
    else Result:='unknown';
  end;
end;

end.

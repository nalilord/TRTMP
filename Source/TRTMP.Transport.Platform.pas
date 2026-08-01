unit TRTMP.Transport.Platform;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF MSWINDOWS}
  TRTMP.Transport.TLS.SChannel;
  {$ELSE}
  TRTMP.Transport.TLS.OpenSSL;
  {$ENDIF}

type
  {$IFDEF MSWINDOWS}
  TRtmpPlatformTransportFactory = class(TRtmpSChannelTransportFactory);
  {$ELSE}
  TRtmpPlatformTransportFactory = class(TRtmpOpenSSLTransportFactory);
  {$ENDIF}

implementation

end.

unit TRTMP.RTMP.Types;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  TRTMP.Transport.TLS;

type
  TRtmpMessageType = (
    mtSetChunkSize,
    mtAbort,
    mtAck,
    mtUserControl,
    mtWindowAckSize,
    mtSetPeerBandwidth,
    mtAudio,
    mtVideo,
    mtDataAMF3,
    mtSharedObjectAMF3,
    mtCommandAMF3,
    mtDataAMF0,
    mtSharedObjectAMF0,
    mtCommandAMF0,
    mtAggregate,
    mtUnknown
  );

  TRtmpPacketFlag = (
    pfIsAudio,
    pfIsVideo,
    pfIsMetadata,
    pfIsCodecConfig,
    pfIsKeyframe,
    pfIsSequenceHeader,
    pfHasExtendedTimestamp,
    pfDropped,
    pfReconstructed
  );

  TRtmpPacketFlags = set of TRtmpPacketFlag;

  TRtmpClientState = (
    csStopped,
    csConnecting,
    csHandshaking,
    csPublishing,
    csStreaming,
    csReconnecting,
    csError
  );

  TRtmpSessionState = (
    ssDisconnected,
    ssConnected,
    ssHandshaking,
    ssConnectedCommand,
    ssPublishing,
    ssStreaming,
    ssError
  );

  TRtmpTimestampMode = (
    tmPassThrough,
    tmRebased,
    tmSmoothed
  );

  TRtmpLogLevel = (
    llDebug,
    llInfo,
    llWarning,
    llError
  );

  TRtmpUserControlEventType = (
    ucStreamBegin = 0,
    ucStreamEOF = 1,
    ucStreamDry = 2,
    ucSetBufferLength = 3,
    ucStreamIsRecorded = 4,
    ucPingRequest = 6,
    ucPingResponse = 7,
    ucBufferEmpty = 31,
    ucBufferReady = 32
  );

  TRtmpServerConfig = record
    BindAddress: string;
    Port: Word;
    MaxSessions: Integer;
    MaxChunkSize: Integer;
    MaxMessageSize: Integer;
    MaxChunkStreams: Integer;
    ReadTimeoutMS: Integer;
    WriteTimeoutMS: Integer;
    BufferMaxPackets: Integer;
    BufferMaxBytes: UInt64;
    BufferMaxDurationMS: UInt32;
    EnableAnalyzer: Boolean;
    AllowPublishWithoutFCPublish: Boolean;
    EnhancedCapabilities: UInt32;
    Tls: TRtmpTlsServerOptions;
    class function CreateDefault: TRtmpServerConfig; static;
    function WithBind(const AAddress: string; APort: Word): TRtmpServerConfig;
    function WithBufferLimits(AMaxPackets: Integer; AMaxBytes: UInt64;
      AMaxDurationMS: UInt32 = 0): TRtmpServerConfig;
    function WithProtocolLimits(AMaxChunkSize, AMaxMessageSize,
      AMaxChunkStreams: Integer): TRtmpServerConfig;
    function WithTimeouts(AReadTimeoutMS, AWriteTimeoutMS: Integer): TRtmpServerConfig;
    function WithEnhancedCapabilities(ACapabilities: UInt32): TRtmpServerConfig;
    function WithTls(const ACertificateFile, APrivateKeyFile: string;
      const ACertificatePassword: string = ''): TRtmpServerConfig;
  end;

  TRtmpClientConfig = record
    TargetURL: string;
    App: string;
    StreamKey: string;
    EnhancedCodecs: string;
    EnhancedCapabilities: UInt32;
    RequiredAudioTrackID: Integer;
    Tls: TRtmpTlsClientOptions;
    AllowInsecureRedirect: Boolean;
    ConnectTimeoutMS: Integer;
    ReconnectDelayMS: Integer;
    MaxReconnectDelayMS: Integer;
    ReconnectBoundaryTimeoutMS: Integer;
    OutChunkSize: Integer;
    TimestampMode: TRtmpTimestampMode;
    class function CreateDefault: TRtmpClientConfig; static;
    function WithTarget(const ATargetURL, AApp, AStreamKey: string): TRtmpClientConfig;
    function WithTargetUrl(const ATargetURL: string): TRtmpClientConfig;
    function WithConnectTimeout(AConnectTimeoutMS: Integer): TRtmpClientConfig;
    function WithEnhancedCodecs(const ACodecs: string): TRtmpClientConfig;
    function WithEnhancedCapabilities(ACapabilities: UInt32): TRtmpClientConfig;
    function WithRequiredAudioTrack(ATrackID: Integer): TRtmpClientConfig;
    function WithTlsVerification(AVerifyPeer: Boolean;
      const ACAFile: string = ''): TRtmpClientConfig;
    function WithReconnect(ADelayMS, AMaxDelayMS: Integer): TRtmpClientConfig;
    function WithReconnectBoundaryTimeout(
      ATimeoutMS: Integer): TRtmpClientConfig;
    function WithOutChunkSize(AOutChunkSize: Integer): TRtmpClientConfig;
    function WithTimestampMode(AMode: TRtmpTimestampMode): TRtmpClientConfig;
  end;

const
  RTMP_CAPS_EX_RECONNECT = $01;
  RTMP_CAPS_EX_MULTITRACK = $02;
  RTMP_CAPS_EX_MODEX = $04;
  RTMP_CAPS_EX_TIMESTAMP_NANO_OFFSET = $08;
  RTMP_DEFAULT_ENHANCED_CAPABILITIES =
    RTMP_CAPS_EX_RECONNECT OR RTMP_CAPS_EX_MULTITRACK OR RTMP_CAPS_EX_MODEX OR
    RTMP_CAPS_EX_TIMESTAMP_NANO_OFFSET;
  RTMP_DEFAULT_ENHANCED_CODECS =
    'avc1,hvc1,av01,vp09,vp08,mp4a,.mp3,Opus,fLaC,ac-3,ec-3';

type
  TRtmpAnalysisSnapshot = record
    StreamUptimeMS: UInt64;
    TotalBitrate: Double;
    AudioBitrate: Double;
    VideoBitrate: Double;
    PacketRate: Double;
    VideoFPS: Double;
    KeyframeIntervalMS: Integer;
    VideoWidth: Integer;
    VideoHeight: Integer;
    AudioSampleRate: Integer;
    AudioChannels: Integer;
    VideoCodec: string;
    AudioCodec: string;
    DriftMS: Integer;
    JitterMS: Integer;
    DropsEstimated: UInt64;
    AudioTrackCount: Integer;
    VideoTrackCount: Integer;
    AudioMultitrackPackets: UInt64;
    VideoMultitrackPackets: UInt64;
    AudioModExPackets: UInt64;
    VideoModExPackets: UInt64;
    AudioTimestampNanoOffset: Integer;
    VideoTimestampNanoOffset: Integer;
  end;

  TRtmpBufferStats = record
    PacketCount: Integer;
    ByteCount: UInt64;
    MaxPackets: Integer;
    MaxBytes: UInt64;
    MaxDurationMS: UInt32;
    WindowDurationMS: UInt32;
    TotalPacketsPushed: UInt64;
    TotalBytesPushed: UInt64;
    EvictedPackets: UInt64;
    EvictedBytes: UInt64;
    EvictedByPacketLimit: UInt64;
    EvictedByByteLimit: UInt64;
    EvictedByAgeLimit: UInt64;
    TrimEventsByPackets: UInt64;
    TrimEventsByBytes: UInt64;
    TrimEventsByAge: UInt64;
    RetainedPackets: Integer;
    RetainedBytes: UInt64;
    HasMetadata: Boolean;
    HasAudioConfig: Boolean;
    HasVideoConfig: Boolean;
    AudioConfigTrackCount: Integer;
    VideoConfigTrackCount: Integer;
    HasKeyframe: Boolean;
  end;

  TRtmpServerStats = record
    ActiveSessions: Integer;
    PeakActiveSessions: Integer;
    ActivePublishes: Integer;
    PeakActivePublishes: Integer;
    TotalSessions: UInt64;
    RejectedSessions: UInt64;
    BytesReceived: UInt64;
    PacketsReceived: UInt64;
    CurrentBitrate: Double;
    AverageBitrate: Double;
    Warnings: UInt64;
    DroppedPackets: UInt64;
    Errors: UInt64;
    ProtocolErrors: UInt64;
    TransportErrors: UInt64;
    SessionErrors: UInt64;
    LastPacketIdleMS: UInt64;
    TimelineLagMS: Integer;
    MaxTimelineLagMS: Integer;
    LastWarningCategory: string;
    LastWarningMessage: string;
    LastErrorCategory: string;
    LastErrorMessage: string;
    Buffer: TRtmpBufferStats;
    Analysis: TRtmpAnalysisSnapshot;
  end;

  TRtmpSessionStats = record
    BytesReceived: UInt64;
    PacketsReceived: UInt64;
    AudioPackets: UInt64;
    VideoPackets: UInt64;
    MetadataPackets: UInt64;
    LastPacketTimestamp: UInt32;
    LastArrivalTick: UInt64;
    MalformedMessages: UInt64;
  end;

  TRtmpClientStats = record
    BytesSent: UInt64;
    PacketsSent: UInt64;
    CurrentBitrate: Double;
    AverageBitrate: Double;
    Reconnects: UInt64;
    ReconnectRequests: UInt64;
    DroppedPackets: UInt64;
    LastSendTick: UInt64;
  end;

function DefaultRtmpServerConfig: TRtmpServerConfig;
function DefaultRtmpClientConfig: TRtmpClientConfig;

implementation

class function TRtmpServerConfig.CreateDefault: TRtmpServerConfig;
begin
  Result:=DefaultRtmpServerConfig;
end;

function TRtmpServerConfig.WithBind(const AAddress: string;
  APort: Word): TRtmpServerConfig;
begin
  Result:=Self;
  Result.BindAddress:=AAddress;
  Result.Port:=APort;
end;

function TRtmpServerConfig.WithBufferLimits(AMaxPackets: Integer;
  AMaxBytes: UInt64; AMaxDurationMS: UInt32): TRtmpServerConfig;
begin
  Result:=Self;
  Result.BufferMaxPackets:=AMaxPackets;
  Result.BufferMaxBytes:=AMaxBytes;
  Result.BufferMaxDurationMS:=AMaxDurationMS;
end;

function TRtmpServerConfig.WithProtocolLimits(AMaxChunkSize, AMaxMessageSize,
  AMaxChunkStreams: Integer): TRtmpServerConfig;
begin
  Result:=Self;
  Result.MaxChunkSize:=AMaxChunkSize;
  Result.MaxMessageSize:=AMaxMessageSize;
  Result.MaxChunkStreams:=AMaxChunkStreams;
end;

function TRtmpServerConfig.WithTimeouts(AReadTimeoutMS,
  AWriteTimeoutMS: Integer): TRtmpServerConfig;
begin
  Result:=Self;
  Result.ReadTimeoutMS:=AReadTimeoutMS;
  Result.WriteTimeoutMS:=AWriteTimeoutMS;
end;

function TRtmpServerConfig.WithEnhancedCapabilities(
  ACapabilities: UInt32): TRtmpServerConfig;
begin
  Result:=Self;
  Result.EnhancedCapabilities:=ACapabilities;
end;

function TRtmpServerConfig.WithTls(const ACertificateFile,
  APrivateKeyFile: string;
  const ACertificatePassword: string): TRtmpServerConfig;
begin
  Result:=Self;
  Result.Tls.Enabled:=True;
  Result.Tls.CertificateFile:=ACertificateFile;
  Result.Tls.CertificatePassword:=ACertificatePassword;
  Result.Tls.PrivateKeyFile:=APrivateKeyFile;
end;

class function TRtmpClientConfig.CreateDefault: TRtmpClientConfig;
begin
  Result:=DefaultRtmpClientConfig;
end;

function TRtmpClientConfig.WithTarget(const ATargetURL, AApp,
  AStreamKey: string): TRtmpClientConfig;
begin
  Result:=Self;
  Result.TargetURL:=ATargetURL;
  Result.App:=AApp;
  Result.StreamKey:=AStreamKey;
end;

function TRtmpClientConfig.WithTargetUrl(
  const ATargetURL: string): TRtmpClientConfig;
begin
  Result:=Self;
  Result.TargetURL:=ATargetURL;
end;

function TRtmpClientConfig.WithConnectTimeout(
  AConnectTimeoutMS: Integer): TRtmpClientConfig;
begin
  Result:=Self;
  Result.ConnectTimeoutMS:=AConnectTimeoutMS;
end;

function TRtmpClientConfig.WithEnhancedCodecs(
  const ACodecs: string): TRtmpClientConfig;
begin
  Result:=Self;
  Result.EnhancedCodecs:=ACodecs;
end;

function TRtmpClientConfig.WithEnhancedCapabilities(
  ACapabilities: UInt32): TRtmpClientConfig;
begin
  Result:=Self;
  Result.EnhancedCapabilities:=ACapabilities;
end;

function TRtmpClientConfig.WithRequiredAudioTrack(
  ATrackID: Integer): TRtmpClientConfig;
begin
  Result:=Self;
  Result.RequiredAudioTrackID:=ATrackID;
end;

function TRtmpClientConfig.WithTlsVerification(AVerifyPeer: Boolean;
  const ACAFile: string): TRtmpClientConfig;
begin
  Result:=Self;
  Result.Tls.VerifyPeer:=AVerifyPeer;
  Result.Tls.CAFile:=ACAFile;
end;

function TRtmpClientConfig.WithReconnect(ADelayMS,
  AMaxDelayMS: Integer): TRtmpClientConfig;
begin
  Result:=Self;
  Result.ReconnectDelayMS:=ADelayMS;
  Result.MaxReconnectDelayMS:=AMaxDelayMS;
end;

function TRtmpClientConfig.WithReconnectBoundaryTimeout(
  ATimeoutMS: Integer): TRtmpClientConfig;
begin
  Result:=Self;
  Result.ReconnectBoundaryTimeoutMS:=ATimeoutMS;
end;

function TRtmpClientConfig.WithOutChunkSize(
  AOutChunkSize: Integer): TRtmpClientConfig;
begin
  Result:=Self;
  Result.OutChunkSize:=AOutChunkSize;
end;

function TRtmpClientConfig.WithTimestampMode(
  AMode: TRtmpTimestampMode): TRtmpClientConfig;
begin
  Result:=Self;
  Result.TimestampMode:=AMode;
end;

function DefaultRtmpServerConfig: TRtmpServerConfig;
begin
  Result:=Default(TRtmpServerConfig);
  Result.BindAddress:='0.0.0.0';
  Result.Port:=1935;
  Result.MaxSessions:=8;
  Result.MaxChunkSize:=131072;
  Result.MaxMessageSize:=8 * 1024 * 1024;
  Result.MaxChunkStreams:=64;
  Result.ReadTimeoutMS:=10000;
  Result.WriteTimeoutMS:=10000;
  Result.BufferMaxPackets:=4096;
  Result.BufferMaxBytes:=64 * 1024 * 1024;
  Result.BufferMaxDurationMS:=0;
  Result.EnableAnalyzer:=True;
  Result.AllowPublishWithoutFCPublish:=True;
  Result.EnhancedCapabilities:=RTMP_DEFAULT_ENHANCED_CAPABILITIES;
  Result.Tls:=TRtmpTlsServerOptions.CreateDefault;
end;

function DefaultRtmpClientConfig: TRtmpClientConfig;
begin
  Result:=Default(TRtmpClientConfig);
  Result.EnhancedCodecs:=RTMP_DEFAULT_ENHANCED_CODECS;
  Result.EnhancedCapabilities:=RTMP_DEFAULT_ENHANCED_CAPABILITIES;
  Result.RequiredAudioTrackID:=-1;
  Result.Tls:=TRtmpTlsClientOptions.CreateDefault;
  Result.AllowInsecureRedirect:=False;
  Result.ConnectTimeoutMS:=10000;
  Result.ReconnectDelayMS:=1000;
  Result.MaxReconnectDelayMS:=15000;
  Result.ReconnectBoundaryTimeoutMS:=2000;
  Result.OutChunkSize:=4096;
  Result.TimestampMode:=tmPassThrough;
end;

end.

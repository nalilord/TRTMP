# RTMPS / TLS Transport

## Status

TRTMP has built-in platform TLS transports:

- Windows uses Schannel, SSPI, Crypt32, and CNG from Windows. It does not load
  OpenSSL or ship third-party DLLs.
- Unix uses the system OpenSSL shared library. OpenSSL is loaded only when TLS
  is requested, so plain RTMP has no link-time OpenSSL dependency.

`TRtmpClient` and `TRtmpServer` select the platform transport by default. Plain
`rtmp://` traffic still uses native sockets. Applications may replace
`TransportFactory` with their own implementation when needed.

TRTMP recognizes `rtmps://`, uses default port 443, preserves the secure scheme
in `tcUrl`, and never falls back to cleartext after a TLS error. Redirects from
`rtmps://` to `rtmp://` are rejected unless `AllowInsecureRedirect` is enabled.

## Provider behavior

Both implementations enforce `MinimumVersion`, which defaults to TLS 1.2.
`tlsVersion13` requires TLS 1.3 and fails if the platform cannot negotiate it.

### Windows Schannel

- Server and client identities use one PFX/P12 `CertificateFile` with an
  optional `CertificatePassword`. `PrivateKeyFile` must be empty.
- Peer verification uses the Windows certificate trust store and validates the
  supplied DNS name or IP address.
- Custom `CAFile` and `CAPath` values are currently rejected.
- Client PFX certificates are supported. Server-side client-certificate
  validation is not implemented yet, so `RequireClientCertificate` is rejected.
- The implementation uses the crypto-agile `SCH_CREDENTIALS` interface and
  handles the TLS 1.3 `SEC_I_RENEGOTIATE` status.

Schannel may move TLS work into LSASS, where a `PKCS12_NO_PERSIST_KEY` handle
cannot be marshalled. TRTMP therefore imports PFX keys through CNG, acquires the
Schannel credential, and immediately deletes the imported key container. The
credential retains the live key for its lifetime, while no reusable imported
key is left behind.

`SCH_CREDENTIALS` requires Windows 10 version 1809 or Windows Server 2019 and
later.

### Unix OpenSSL

- Server identities use a PEM `CertificateFile` and PEM `PrivateKeyFile`.
- System trust is used by default; `CAFile` and `CAPath` can select custom
  trust roots.
- DNS names and IP addresses are verified when `VerifyPeer=True`; DNS names
  are also sent using SNI.
- Client certificates and server-side mutual TLS are supported with PEM files.
- Password-protected PEM private keys use `CertificatePassword`; incorrect
  passwords fail before the listener or connection is exposed.
- The loader accepts the normal system `libssl.so.3`, `libssl.so.1.1`, or
  unversioned `libssl.so` names. RTMPS fails clearly if no compatible system
  OpenSSL is installed.

## Client configuration

```pascal
Config:=TRtmpClientConfig.CreateDefault;
Config.TargetURL:='rtmps://ingest.example.test/live/key';
Config.Tls.VerifyPeer:=True;
Config.Tls.ServerName:='ingest.example.test'; // Empty uses the URL host.
Config.Tls.MinimumVersion:=tlsVersion12;
```

For a Unix custom CA:

```pascal
Config.Tls.CAFile:='trusted-ca.pem';
```

For a Windows client certificate:

```pascal
Config.Tls.CertificateFile:='client-identity.pfx';
Config.Tls.CertificatePassword:='secret';
```

## Server configuration

Windows:

```pascal
Config:=TRtmpServerConfig.CreateDefault;
Config.Port:=443;
Config.Tls.Enabled:=True;
Config.Tls.CertificateFile:='server-identity.pfx';
Config.Tls.CertificatePassword:='secret';
Server.Config:=Config;
```

Unix:

```pascal
Config:=TRtmpServerConfig.CreateDefault;
Config.Port:=443;
Config.Tls.Enabled:=True;
Config.Tls.CertificateFile:='server-cert.pem';
Config.Tls.PrivateKeyFile:='server-key.pem';
Server.Config:=Config;
```

The gateway INI files expose the same fields. Avoid storing production PFX
passwords in broadly readable configuration files.

## Test fixtures

- `Tests/tls-transport-smoke.sh` generates a self-signed PEM identity and runs
  a verified OpenSSL client/server loopback, rejects a hostname mismatch, and
  negotiates a TLS 1.3-only connection. It also verifies encrypted PEM loading
  and rejection of an incorrect private-key password.
- `Tests/tls-schannel-smoke.sh` generates a password-protected PFX identity and
  runs a Schannel client/server loopback through Delphi Win64. Its local
  self-signed client deliberately disables peer verification; production
  defaults remain verified. A second connection asserts that Schannel rejects
  the same untrusted certificate when verification is enabled.
- `Tests/ffmpeg-rtmps-integration.sh` verifies a real FFmpeg H.264/AAC publish
  into `TRtmpServer` over RTMPS, rejects an untrusted FFmpeg connection, and
  verifies a packet-exact RTMPS relay through `TRtmpClient` into a second
  TLS-enabled `TRtmpServer`.
- Both fixtures are included in `smoke-test.sh` when their platform checks are
  enabled.

## Security rules

- Peer verification defaults to enabled.
- Hostname/IP verification uses the original target host.
- The minimum version defaults to TLS 1.2.
- TLS errors never downgrade to plain RTMP.
- Certificate passwords and private-key contents are never logged.

References:

- [Microsoft: obtaining Schannel credentials](https://learn.microsoft.com/en-us/windows/win32/secauthn/obtaining-schannel-credentials)
- [Microsoft: SCH_CREDENTIALS](https://learn.microsoft.com/en-us/windows/win32/api/schannel/ns-schannel-sch_credentials)
- [Microsoft: PFXImportCertStore](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-pfximportcertstore)
- [OpenSSL: hostname verification](https://docs.openssl.org/3.6/man3/SSL_set1_host/)
- [OpenSSL: minimum protocol version](https://docs.openssl.org/master/man3/SSL_CTX_set_min_proto_version/)
- [FFmpeg: RTMPS protocol](https://ffmpeg.org/ffmpeg-protocols.html#rtmps)

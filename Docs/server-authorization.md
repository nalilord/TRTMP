# Server Authorization

## Overview

`TRtmpServer.Authorizer` accepts an optional `IRtmpServerAuthorizer`. When no
authorizer is installed, behavior remains backward-compatible and all valid
connect/publish requests are accepted.

An installed authorizer receives two independent decisions:

- `AuthorizeConnect` runs after the `connect` command has been parsed but
  before the server sends connect success.
- `AuthorizePublish` runs after the app and stream name have been normalized
  but before the publish is activated or any media is accepted.

The same authorizer instance can be called concurrently by several session
threads, so implementations must protect mutable shared state.

## Example

```pascal
type
  TStreamAuthorizer = class(TInterfacedObject, IRtmpServerAuthorizer)
  public
    function AuthorizeConnect(
      const AContext: TRtmpConnectAuthorizationContext): TRtmpAuthorizationDecision;
    function AuthorizePublish(
      const AContext: TRtmpPublishAuthorizationContext): TRtmpAuthorizationDecision;
  end;

function TStreamAuthorizer.AuthorizeConnect(
  const AContext: TRtmpConnectAuthorizationContext): TRtmpAuthorizationDecision;
begin
  if AContext.Parameter('token') = 'expected-token' then
    Result:=TRtmpAuthorizationDecision.Allow
  else
    Result:=TRtmpAuthorizationDecision.Deny('', 'Invalid connection token');
end;

function TStreamAuthorizer.AuthorizePublish(
  const AContext: TRtmpPublishAuthorizationContext): TRtmpAuthorizationDecision;
begin
  if AContext.StreamName = 'allowed-stream' then
    Result:=TRtmpAuthorizationDecision.Allow
  else
    Result:=TRtmpAuthorizationDecision.Deny('', 'Stream key is not authorized');
end;

Server.Authorizer:=TStreamAuthorizer.Create;
```

`Parameter` searches percent-decoded query parameters. Connect context searches
`tcUrl` and then `app`; publish context searches the stream name first, followed
by `tcUrl` and `app`. A plus sign decodes to a space.

## Denial Behavior

An empty denial code uses the protocol-appropriate default:

- connect: `NetConnection.Connect.Rejected`
- publish: `NetStream.Publish.Rejected`

Returning a default/uninitialized decision denies access. Exceptions raised by
an authorizer also fail closed: the detailed exception is logged locally and a
generic failure description is returned to the peer.

Authorization rejection is an expected policy outcome and is not counted as a
malformed protocol message.

## Security Boundary

The library deliberately does not provide a credential database or prescribe a
token format. Applications can validate static keys, signed tokens, database
records, IP allowlists, or an external policy service through the same interface.

Classic `rtmp://` transports credentials and media without TLS protection. Do
not send reusable secrets over untrusted networks until an RTMPS transport is
configured. Authorization controls who may publish; it does not encrypt the
connection.

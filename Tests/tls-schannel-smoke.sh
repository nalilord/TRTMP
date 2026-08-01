#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-1994}"
PASSWORD="${PASSWORD:-trtmp-smoke-password}"
mkdir -p "$ROOT/Bin"
TMP_DIR="$(mktemp -d "$ROOT/Bin/tls-schannel-smoke.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

command -v openssl >/dev/null 2>&1 || {
  printf 'openssl command is required for the Schannel transport smoke.\n' >&2
  exit 2
}
command -v wslpath >/dev/null 2>&1 || {
  printf 'The Schannel transport smoke requires Windows/WSL interop.\n' >&2
  exit 2
}

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=localhost' \
  -addext 'subjectAltName=IP:127.0.0.1' \
  -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
  -addext 'extendedKeyUsage=serverAuth' \
  -keyout "$TMP_DIR/server-key.pem" \
  -out "$TMP_DIR/server-cert.pem" >/dev/null 2>&1
openssl pkcs12 -export \
  -name 'TRTMP TLS smoke' \
  -inkey "$TMP_DIR/server-key.pem" \
  -in "$TMP_DIR/server-cert.pem" \
  -out "$TMP_DIR/server.pfx" \
  -passout "pass:$PASSWORD" >/dev/null 2>&1

"$ROOT/build-delphi.sh" Examples/RtmpTlsTransportSmoke.pas Win64
"$ROOT/Bin/win64/RtmpTlsTransportSmoke.exe" \
  "$(wslpath -w "$TMP_DIR/server.pfx")" - - "$PORT" "$PASSWORD"

if "$ROOT/Bin/win64/RtmpTlsTransportSmoke.exe" \
  "$(wslpath -w "$TMP_DIR/server.pfx")" - - "$((PORT + 1))" \
  "$PASSWORD" true >"$TMP_DIR/verify-rejection.log" 2>&1; then
  printf 'Schannel accepted an untrusted self-signed peer.\n' >&2
  exit 1
fi
printf 'TLS_VERIFY_REJECTION_OK provider=Windows Schannel TLS transport\n'

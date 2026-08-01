#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-1993}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

command -v openssl >/dev/null 2>&1 || {
  printf 'openssl command is required for the TLS transport smoke.\n' >&2
  exit 2
}

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=127.0.0.1' \
  -addext 'subjectAltName=IP:127.0.0.1' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -keyout "$TMP_DIR/server-key.pem" \
  -out "$TMP_DIR/server-cert.pem" >/dev/null 2>&1
openssl pkey -in "$TMP_DIR/server-key.pem" -aes-256-cbc \
  -passout pass:trtmp-test-password \
  -out "$TMP_DIR/server-key-encrypted.pem" >/dev/null 2>&1

"$ROOT/build-fpc.sh" Examples/RtmpTlsTransportSmoke.pas
"$ROOT/Bin/linux/RtmpTlsTransportSmoke" \
  "$TMP_DIR/server-cert.pem" \
  "$TMP_DIR/server-key.pem" \
  "$TMP_DIR/server-cert.pem" \
  "$PORT"

if "$ROOT/Bin/linux/RtmpTlsTransportSmoke" \
  "$TMP_DIR/server-cert.pem" \
  "$TMP_DIR/server-key.pem" \
  "$TMP_DIR/server-cert.pem" \
  "$((PORT + 1))" '' true wrong.invalid \
  >"$TMP_DIR/hostname-rejection.log" 2>&1; then
  printf 'OpenSSL accepted a certificate for the wrong server name.\n' >&2
  exit 1
fi
printf 'TLS_HOSTNAME_REJECTION_OK provider=system OpenSSL TLS transport\n'

"$ROOT/Bin/linux/RtmpTlsTransportSmoke" \
  "$TMP_DIR/server-cert.pem" \
  "$TMP_DIR/server-key.pem" \
  "$TMP_DIR/server-cert.pem" \
  "$((PORT + 2))" '' true 127.0.0.1 1.3

"$ROOT/Bin/linux/RtmpTlsTransportSmoke" \
  "$TMP_DIR/server-cert.pem" \
  "$TMP_DIR/server-key-encrypted.pem" \
  "$TMP_DIR/server-cert.pem" \
  "$((PORT + 3))" trtmp-test-password

if "$ROOT/Bin/linux/RtmpTlsTransportSmoke" \
  "$TMP_DIR/server-cert.pem" \
  "$TMP_DIR/server-key-encrypted.pem" \
  "$TMP_DIR/server-cert.pem" \
  "$((PORT + 4))" wrong-password \
  >"$TMP_DIR/password-rejection.log" 2>&1; then
  printf 'OpenSSL accepted an incorrect encrypted-key password.\n' >&2
  exit 1
fi
printf 'TLS_KEY_PASSWORD_REJECTION_OK provider=system OpenSSL TLS transport\n'

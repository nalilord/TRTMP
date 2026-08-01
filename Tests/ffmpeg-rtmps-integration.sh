#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INGEST_PORT="${INGEST_PORT:-1970}"
RELAY_INGEST_PORT="${RELAY_INGEST_PORT:-1971}"
RELAY_DOWNSTREAM_PORT="${RELAY_DOWNSTREAM_PORT:-1972}"
DURATION="${DURATION:-1.0}"
KEEP_LOGS="${KEEP_LOGS:-0}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trtmp-rtmps.XXXXXX")"
PROBE_FD=""
PROBE_PID=""

cleanup_probe() {
  if [[ -n "$PROBE_FD" ]]; then
    eval "exec ${PROBE_FD}>&-" 2>/dev/null || true
    PROBE_FD=""
  fi
  if [[ -n "$PROBE_PID" ]] && kill -0 "$PROBE_PID" 2>/dev/null; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
  fi
  PROBE_PID=""
}

cleanup() {
  cleanup_probe
  if [[ "$KEEP_LOGS" -eq 0 ]]; then
    rm -rf "$TMP_DIR"
  else
    printf 'RTMPS integration logs: %s\n' "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

command -v ffmpeg >/dev/null 2>&1 || {
  printf 'ffmpeg is required for the RTMPS integration smoke.\n' >&2
  exit 2
}
command -v openssl >/dev/null 2>&1 || {
  printf 'openssl is required for the RTMPS integration smoke.\n' >&2
  exit 2
}
ffmpeg -hide_banner -encoders 2>/dev/null |
  awk '$2 == "libx264" { found=1 } END { exit !found }' || {
    printf 'The libx264 FFmpeg encoder is required for this smoke.\n' >&2
    exit 2
  }

wait_for_line() {
  local pattern="$1" log="$2" description="$3" attempt
  for attempt in {1..120}; do
    if grep -q "$pattern" "$log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
      printf '%s exited before becoming ready:\n' "$description" >&2
      sed -n '1,120p' "$log" >&2
      return 1
    fi
    sleep 0.05
  done
  printf 'Timed out waiting for %s.\n' "$description" >&2
  return 1
}

publish_av() {
  local url="$1" ca_file="$2" log="$3" duration="$4"
  ffmpeg -hide_banner -loglevel warning -nostdin \
    -f lavfi -i 'testsrc2=size=320x180:rate=15' \
    -f lavfi -i 'sine=frequency=1000:sample_rate=48000' \
    -t "$duration" -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g 15 \
    -c:a aac -b:a 96k -ar 48000 -ac 2 \
    -flvflags no_duration_filesize -f flv \
    -tls_verify 1 -ca_file "$ca_file" -verifyhost 127.0.0.1 \
    "$url" >"$log" 2>&1
}

summary_value() {
  local key="$1" log="$2"
  sed -n "s/^RELAY_SUMMARY .*${key}=\([^ ]*\).*/\1/p" "$log" |
    tail -n 1
}

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=127.0.0.1' \
  -addext 'subjectAltName=IP:127.0.0.1' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign' \
  -addext 'extendedKeyUsage=serverAuth' \
  -keyout "$TMP_DIR/server-key.pem" \
  -out "$TMP_DIR/server-cert.pem" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=untrusted.invalid' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -keyout "$TMP_DIR/wrong-key.pem" \
  -out "$TMP_DIR/wrong-ca.pem" >/dev/null 2>&1

cd "$ROOT"
./build-fpc.sh Examples/RtmpCodecInteropProbe.pas
./build-fpc.sh Examples/RtmpCodecRelayProbe.pas

mkfifo "$TMP_DIR/ingest.stdin"
exec {PROBE_FD}<>"$TMP_DIR/ingest.stdin"
"$ROOT/Bin/linux/RtmpCodecInteropProbe" "$INGEST_PORT" \
  "$TMP_DIR/server-cert.pem" "$TMP_DIR/server-key.pem" \
  <"$TMP_DIR/ingest.stdin" >"$TMP_DIR/ingest.log" 2>&1 &
PROBE_PID=$!
wait_for_line '^PROBE_READY .*tls=True' "$TMP_DIR/ingest.log" \
  'RTMPS ingest probe'

if publish_av "rtmps://127.0.0.1:${INGEST_PORT}/live/untrusted" \
  "$TMP_DIR/wrong-ca.pem" "$TMP_DIR/untrusted-ffmpeg.log" 0.25; then
  printf 'FFmpeg accepted an RTMPS certificate signed by an untrusted CA.\n' >&2
  exit 1
fi

publish_av "rtmps://127.0.0.1:${INGEST_PORT}/live/verified" \
  "$TMP_DIR/server-cert.pem" "$TMP_DIR/ingest-ffmpeg.log" "$DURATION"
printf '\n' >&"$PROBE_FD"
wait "$PROBE_PID"
PROBE_PID=""
eval "exec ${PROBE_FD}>&-" 2>/dev/null || true
PROBE_FD=""

grep -q '^MEDIA stream=verified media=video signaling=legacy codec=avc1 ' \
  "$TMP_DIR/ingest.log"
grep -q '^MEDIA stream=verified media=audio signaling=legacy codec=aac ' \
  "$TMP_DIR/ingest.log"
grep -Eq '^PROBE_SUMMARY audioPackets=[1-9][0-9]* videoPackets=[1-9][0-9]*$' \
  "$TMP_DIR/ingest.log"
printf 'RTMPS_INGEST_OK publisher=FFmpeg verify_peer=True media=H264+AAC\n'
printf 'RTMPS_UNTRUSTED_REJECTION_OK publisher=FFmpeg\n'

mkfifo "$TMP_DIR/relay.stdin"
exec {PROBE_FD}<>"$TMP_DIR/relay.stdin"
"$ROOT/Bin/linux/RtmpCodecRelayProbe" "$RELAY_INGEST_PORT" \
  "$RELAY_DOWNSTREAM_PORT" verified-relay "$TMP_DIR/server-cert.pem" \
  "$TMP_DIR/server-key.pem" "$TMP_DIR/server-cert.pem" \
  <"$TMP_DIR/relay.stdin" >"$TMP_DIR/relay.log" 2>&1 &
PROBE_PID=$!
wait_for_line '^RELAY_READY .*tls=True' "$TMP_DIR/relay.log" \
  'RTMPS relay probe'

publish_av "rtmps://127.0.0.1:${RELAY_INGEST_PORT}/live/verified-relay" \
  "$TMP_DIR/server-cert.pem" "$TMP_DIR/relay-ffmpeg.log" "$DURATION"
sleep 0.35
printf '\n' >&"$PROBE_FD"
wait "$PROBE_PID"
PROBE_PID=""
eval "exec ${PROBE_FD}>&-" 2>/dev/null || true
PROBE_FD=""

grep -q '^SOURCE_MEDIA .* media=video signaling=legacy codec=avc1 ' \
  "$TMP_DIR/relay.log"
grep -q '^SOURCE_MEDIA .* media=audio signaling=legacy codec=aac ' \
  "$TMP_DIR/relay.log"
grep -q '^RELAY_MEDIA .* media=video signaling=legacy codec=avc1 ' \
  "$TMP_DIR/relay.log"
grep -q '^RELAY_MEDIA .* media=audio signaling=legacy codec=aac ' \
  "$TMP_DIR/relay.log"

source_packets="$(summary_value sourcePackets "$TMP_DIR/relay.log")"
relay_packets="$(summary_value relayPackets "$TMP_DIR/relay.log")"
source_bytes="$(summary_value sourceBytes "$TMP_DIR/relay.log")"
relay_bytes="$(summary_value relayBytes "$TMP_DIR/relay.log")"
source_digest="$(summary_value sourceDigest "$TMP_DIR/relay.log")"
relay_digest="$(summary_value relayDigest "$TMP_DIR/relay.log")"
if [[ -z "$source_packets" || "$source_packets" == "0" ||
      "$source_packets" != "$relay_packets" ||
      "$source_bytes" != "$relay_bytes" ||
      "$source_digest" != "$relay_digest" ]]; then
  printf 'RTMPS relay fidelity mismatch: packets=%s/%s bytes=%s/%s digest=%s/%s\n' \
    "$source_packets" "$relay_packets" "$source_bytes" "$relay_bytes" \
    "$source_digest" "$relay_digest" >&2
  exit 1
fi

printf 'RTMPS_RELAY_OK publisher=FFmpeg client=TRtmpClient packets=%s bytes=%s digest=%s\n' \
  "$source_packets" "$source_bytes" "$source_digest"

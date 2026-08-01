#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-1975}"
DURATION="${DURATION:-60}"
MAX_RSS_GROWTH_KB="${MAX_RSS_GROWTH_KB:-131072}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trtmp-soak.XXXXXX")"
PROBE_FD=""
PROBE_PID=""
FFMPEG_PID=""

cleanup() {
  if [[ -n "$PROBE_FD" ]]; then
    eval "exec ${PROBE_FD}>&-" 2>/dev/null || true
  fi
  for pid in "$FFMPEG_PID" "$PROBE_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 10 ]]; then
  printf 'DURATION must be an integer of at least 10 seconds.\n' >&2
  exit 2
fi
command -v ffmpeg >/dev/null 2>&1 || {
  printf 'ffmpeg is required for the ingest soak.\n' >&2
  exit 2
}
ffmpeg -hide_banner -encoders 2>/dev/null |
  awk '$2 == "libx264" { found=1 } END { exit !found }' || {
    printf 'The libx264 FFmpeg encoder is required for the ingest soak.\n' >&2
    exit 2
  }

cd "$ROOT"
./build-fpc.sh Examples/RtmpCodecInteropProbe.pas
mkfifo "$TMP_DIR/probe.stdin"
exec {PROBE_FD}<>"$TMP_DIR/probe.stdin"
"$ROOT/Bin/linux/RtmpCodecInteropProbe" "$PORT" \
  <"$TMP_DIR/probe.stdin" >"$TMP_DIR/probe.log" 2>&1 &
PROBE_PID=$!

for _ in {1..120}; do
  if grep -q '^PROBE_READY ' "$TMP_DIR/probe.log" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    printf 'Ingest probe exited before becoming ready.\n' >&2
    exit 1
  fi
  sleep 0.05
done
grep -q '^PROBE_READY ' "$TMP_DIR/probe.log"

baseline_rss="$(awk '/^VmRSS:/ { print $2 }' "/proc/$PROBE_PID/status")"
: >"$TMP_DIR/rss-kb.log"
ffmpeg -hide_banner -loglevel warning -nostdin \
  -re -f lavfi -i 'testsrc2=size=320x180:rate=30' \
  -re -f lavfi -i 'sine=frequency=1000:sample_rate=48000' \
  -t "$DURATION" -map 0:v:0 -map 1:a:0 \
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g 60 \
  -c:a aac -b:a 128k -ar 48000 -ac 2 \
  -flvflags no_duration_filesize -f flv \
  "rtmp://127.0.0.1:${PORT}/live/soak" \
  >"$TMP_DIR/ffmpeg.log" 2>&1 &
FFMPEG_PID=$!

while kill -0 "$FFMPEG_PID" 2>/dev/null; do
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    printf 'Ingest probe exited during the soak.\n' >&2
    exit 1
  fi
  awk '/^VmRSS:/ { print $2 }' "/proc/$PROBE_PID/status" >>"$TMP_DIR/rss-kb.log"
  sleep 1
done
wait "$FFMPEG_PID"
FFMPEG_PID=""

printf '\n' >&"$PROBE_FD"
wait "$PROBE_PID"
PROBE_PID=""
eval "exec ${PROBE_FD}>&-" 2>/dev/null || true
PROBE_FD=""

grep -q '^MEDIA stream=soak media=video signaling=legacy codec=avc1 ' \
  "$TMP_DIR/probe.log"
grep -q '^MEDIA stream=soak media=audio signaling=legacy codec=aac ' \
  "$TMP_DIR/probe.log"
grep -Eq '^PROBE_SUMMARY audioPackets=[1-9][0-9]* videoPackets=[1-9][0-9]*$' \
  "$TMP_DIR/probe.log"

peak_rss="$(sort -nr "$TMP_DIR/rss-kb.log" | head -n 1)"
rss_growth=$((peak_rss - baseline_rss))
if [[ "$rss_growth" -gt "$MAX_RSS_GROWTH_KB" ]]; then
  printf 'Ingest RSS growth exceeded limit: baseline=%sKiB peak=%sKiB limit=%sKiB\n' \
    "$baseline_rss" "$peak_rss" "$MAX_RSS_GROWTH_KB" >&2
  exit 1
fi

printf 'INGEST_SOAK_OK duration=%ss baseline_rss=%sKiB peak_rss=%sKiB growth=%sKiB\n' \
  "$DURATION" "$baseline_rss" "$peak_rss" "$rss_growth"

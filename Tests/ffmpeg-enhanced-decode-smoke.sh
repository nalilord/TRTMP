#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-1960}"
DURATION="${DURATION:-1.0}"
BUILD=1
KEEP_LOGS=0
TMP_DIR=""
PROBE_PID=""
PROBE_FD=""

usage() {
  cat <<'EOF'
Usage: bash Tests/ffmpeg-enhanced-decode-smoke.sh [options]

Options:
  --no-build      Reuse Bin/linux/RtmpEnhancedDecoderProbe.
  --keep-logs     Keep logs and print their directory.
  --port PORT     RTMP ingest port (default: 1960).
  --duration SEC  Duration per HEVC/Opus stream (default: 1.0).
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --keep-logs) KEEP_LOGS=1 ;;
    --port) shift; PORT="${1:-}" ;;
    --duration) shift; DURATION="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

cleanup() {
  if [[ -n "$PROBE_FD" ]]; then
    eval "exec ${PROBE_FD}>&-" 2>/dev/null || true
  fi
  if [[ -n "$PROBE_PID" ]] && kill -0 "$PROBE_PID" 2>/dev/null; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" && "$KEEP_LOGS" -eq 0 ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

for encoder in libx265 libsvtav1 libvpx-vp9 libopus flac ac3 eac3; do
  if ! ffmpeg -hide_banner -encoders 2>/dev/null |
    awk -v wanted="$encoder" '$2 == wanted { found=1 } END { exit !found }'; then
    printf 'Required encoder unavailable: %s\n' "$encoder" >&2
    exit 2
  fi
done

cd "$ROOT"
if [[ "$BUILD" -eq 1 ]]; then
  ./build-fpc.sh Examples/RtmpEnhancedDecoderProbe.pas --with-ffmpeg
fi
if [[ ! -x "$ROOT/Bin/linux/RtmpEnhancedDecoderProbe" ]]; then
  printf 'Enhanced decoder probe executable not found.\n' >&2
  exit 2
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trtmp-enhanced-decode.XXXXXX")"
mkfifo "$TMP_DIR/probe.stdin"
exec {PROBE_FD}<>"$TMP_DIR/probe.stdin"
"$ROOT/Bin/linux/RtmpEnhancedDecoderProbe" "$PORT" \
  <"$TMP_DIR/probe.stdin" >"$TMP_DIR/probe.log" 2>&1 &
PROBE_PID=$!

ready=0
for attempt in {1..120}; do
  if grep -q '^DECODE_READY ' "$TMP_DIR/probe.log" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ "$ready" -ne 1 ]]; then
  printf 'Decoder probe did not become ready.\n' >&2
  sed -n '1,40p' "$TMP_DIR/probe.log" >&2
  exit 1
fi

ffmpeg -hide_banner -loglevel warning -nostdin \
  -f lavfi -i 'testsrc2=size=320x180:rate=15' -t "$DURATION" -an \
  -c:v libx265 -pix_fmt yuv420p -g 15 \
  -flvflags no_duration_filesize -f flv -rtmp_enhanced_codecs hvc1 \
  "rtmp://127.0.0.1:${PORT}/live/hevc" >"$TMP_DIR/hevc.log" 2>&1

ffmpeg -hide_banner -loglevel warning -nostdin \
  -f lavfi -i 'testsrc2=size=320x180:rate=15' -t "$DURATION" -an \
  -c:v libsvtav1 -pix_fmt yuv420p -g 15 \
  -flvflags no_duration_filesize -f flv -rtmp_enhanced_codecs av01 \
  "rtmp://127.0.0.1:${PORT}/live/av1" >"$TMP_DIR/av1.log" 2>&1

ffmpeg -hide_banner -loglevel warning -nostdin \
  -f lavfi -i 'testsrc2=size=320x180:rate=15' -t "$DURATION" -an \
  -c:v libvpx-vp9 -pix_fmt yuv420p -g 15 \
  -flvflags no_duration_filesize -f flv -rtmp_enhanced_codecs vp09 \
  "rtmp://127.0.0.1:${PORT}/live/vp9" >"$TMP_DIR/vp9.log" 2>&1

ffmpeg -hide_banner -loglevel warning -nostdin \
  -f lavfi -i 'sine=frequency=1000:sample_rate=48000' -t "$DURATION" -vn \
  -c:a libopus -b:a 96k -ar 48000 -ac 2 \
  -flvflags no_duration_filesize -f flv -rtmp_enhanced_codecs Opus \
  "rtmp://127.0.0.1:${PORT}/live/opus" >"$TMP_DIR/opus.log" 2>&1

ffmpeg -hide_banner -loglevel warning -nostdin \
  -f lavfi -i 'sine=frequency=1000:sample_rate=48000' -t "$DURATION" -vn \
  -c:a flac -ar 48000 -ac 2 \
  -flvflags no_duration_filesize -f flv -rtmp_enhanced_codecs fLaC \
  "rtmp://127.0.0.1:${PORT}/live/flac" >"$TMP_DIR/flac.log" 2>&1

ffmpeg -hide_banner -loglevel warning -nostdin \
  -f lavfi -i 'sine=frequency=1000:sample_rate=48000' -t "$DURATION" -vn \
  -c:a ac3 -b:a 192k -ar 48000 -ac 2 \
  -flvflags no_duration_filesize -f flv -rtmp_enhanced_codecs ac-3 \
  "rtmp://127.0.0.1:${PORT}/live/ac3" >"$TMP_DIR/ac3.log" 2>&1

ffmpeg -hide_banner -loglevel warning -nostdin \
  -f lavfi -i 'sine=frequency=1000:sample_rate=48000' -t "$DURATION" -vn \
  -c:a eac3 -b:a 192k -ar 48000 -ac 2 \
  -flvflags no_duration_filesize -f flv -rtmp_enhanced_codecs ec-3 \
  "rtmp://127.0.0.1:${PORT}/live/eac3" >"$TMP_DIR/eac3.log" 2>&1

sleep 0.25
printf '\n' >&"$PROBE_FD"
wait "$PROBE_PID"
PROBE_PID=""
eval "exec ${PROBE_FD}>&-" 2>/dev/null || true
PROBE_FD=""

summary=$(grep '^DECODE_SUMMARY ' "$TMP_DIR/probe.log" | tail -n 1)
video_frames=$(sed -n 's/.*videoFrames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
audio_frames=$(sed -n 's/.*audioFrames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
hevc_frames=$(sed -n 's/.*hevcFrames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
av1_frames=$(sed -n 's/.*av1Frames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
vp9_frames=$(sed -n 's/.*vp9Frames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
opus_frames=$(sed -n 's/.*opusFrames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
flac_frames=$(sed -n 's/.*flacFrames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
ac3_frames=$(sed -n 's/.*ac3Frames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
eac3_frames=$(sed -n 's/.*eac3Frames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
if [[ -z "$video_frames" || "$video_frames" -lt 1 ||
      -z "$audio_frames" || "$audio_frames" -lt 1 ||
      -z "$hevc_frames" || "$hevc_frames" -lt 1 ||
      -z "$av1_frames" || "$av1_frames" -lt 1 ||
      -z "$vp9_frames" || "$vp9_frames" -lt 1 ||
      -z "$opus_frames" || "$opus_frames" -lt 1 ||
      -z "$flac_frames" || "$flac_frames" -lt 1 ||
      -z "$ac3_frames" || "$ac3_frames" -lt 1 ||
      -z "$eac3_frames" || "$eac3_frames" -lt 1 ||
      "$summary" != *'videoCodec=VP9'* ||
      "$summary" != *'audioCodec=E-AC-3'* ||
      "$summary" != *'lastError=' ]]; then
  printf 'Enhanced decode smoke failed: %s\n' "$summary" >&2
  sed -n '1,160p' "$TMP_DIR/probe.log" >&2
  exit 1
fi
if grep -q '^DECODE_ERROR ' "$TMP_DIR/probe.log"; then
  printf 'Enhanced decode smoke reported decoder errors.\n' >&2
  grep '^DECODE_ERROR ' "$TMP_DIR/probe.log" >&2
  exit 1
fi
if ! grep -q '^DECODE_FRAME media=video codec=HEVC .*width=320 height=180 ' \
    "$TMP_DIR/probe.log" ||
   ! grep -q '^DECODE_FRAME media=video codec=AV1 .*width=320 height=180 ' \
    "$TMP_DIR/probe.log" ||
   ! grep -q '^DECODE_FRAME media=video codec=VP9 .*width=320 height=180 ' \
    "$TMP_DIR/probe.log" ||
   ! grep -q '^DECODE_FRAME media=audio codec=Opus .*rate=48000 channels=2 ' \
    "$TMP_DIR/probe.log" ||
   ! grep -q '^DECODE_FRAME media=audio codec=FLAC .*rate=48000 channels=2 ' \
    "$TMP_DIR/probe.log" ||
   ! grep -q '^DECODE_FRAME media=audio codec=AC-3 .*rate=48000 channels=2 ' \
    "$TMP_DIR/probe.log" ||
   ! grep -q '^DECODE_FRAME media=audio codec=E-AC-3 .*rate=48000 channels=2 ' \
    "$TMP_DIR/probe.log"; then
  printf 'Enhanced decode smoke returned incomplete frame metadata.\n' >&2
  grep '^DECODE_FRAME ' "$TMP_DIR/probe.log" | head -n 4 >&2
  exit 1
fi

printf 'Enhanced decode smoke passed: HEVC=%s AV1=%s VP9=%s Opus=%s FLAC=%s AC3=%s EAC3=%s frames\n' \
  "$hevc_frames" "$av1_frames" "$vp9_frames" "$opus_frames" \
  "$flac_frames" "$ac3_frames" "$eac3_frames"
if [[ "$KEEP_LOGS" -eq 1 ]]; then
  printf 'Logs: %s\n' "$TMP_DIR"
fi

#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-1961}"
DURATION="${DURATION:-1.0}"
PROBE_DURATION_MS="${PROBE_DURATION_MS:-30000}"
BUILD=1
KEEP_LOGS=0
TMP_DIR=""
PROBE_PID=""

usage() {
  cat <<'EOF'
Usage: bash Tests/ffmpeg-enhanced-preview-smoke.sh [options]

Options:
  --no-build      Reuse Bin/linux/RtmpEnhancedPreviewProbe.
  --keep-logs     Keep logs and print their directory.
  --port PORT     First RTMP preview port (default: 1961).
  --duration SEC  Duration per video stream (default: 1.0).
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
  if [[ -n "$PROBE_PID" ]] && kill -0 "$PROBE_PID" 2>/dev/null; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" && "$KEEP_LOGS" -eq 0 ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

for encoder in libx265 libsvtav1 libvpx-vp9; do
  if ! ffmpeg -hide_banner -encoders 2>/dev/null |
    awk -v wanted="$encoder" '$2 == wanted { found=1 } END { exit !found }'; then
    printf 'Required encoder unavailable: %s\n' "$encoder" >&2
    exit 2
  fi
done

cd "$ROOT"
if [[ "$BUILD" -eq 1 ]]; then
  ./build-fpc.sh Examples/RtmpEnhancedPreviewProbe.pas --with-ffmpeg
fi
if [[ ! -x "$ROOT/Bin/linux/RtmpEnhancedPreviewProbe" ]]; then
  printf 'Enhanced preview probe executable not found.\n' >&2
  exit 2
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trtmp-enhanced-preview.XXXXXX")"

run_preview_case() {
  local name="$1"
  local codec="$2"
  local encoder="$3"
  local fourcc="$4"
  local case_port="$5"
  local stream="${name}-preview"
  local probe_log="$TMP_DIR/probe-${name}.log"
  local ffmpeg_log="$TMP_DIR/${name}.log"
  local stop_file="$TMP_DIR/stop-${name}"
  local ready=0
  local summary
  local frames
  local -a encoder_options=()

  if [[ "$encoder" == "libvpx-vp9" ]]; then
    encoder_options=(-deadline realtime -lag-in-frames 0)
  fi

  "$ROOT/Bin/linux/RtmpEnhancedPreviewProbe" "$case_port" \
    "$PROBE_DURATION_MS" "$stop_file" >"$probe_log" 2>&1 &
  PROBE_PID=$!
  for attempt in {1..120}; do
    if grep -q '^PREVIEW_READY ' "$probe_log" 2>/dev/null; then
      ready=1
      break
    fi
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  if [[ "$ready" -ne 1 ]]; then
    printf '%s preview probe did not become ready.\n' "$codec" >&2
    sed -n '1,80p' "$probe_log" >&2
    exit 1
  fi

  if ! ffmpeg -hide_banner -loglevel warning -nostdin \
    -re -f lavfi -i 'testsrc2=size=320x180:rate=15' -t "$DURATION" -an \
    -c:v "$encoder" -pix_fmt yuv420p -g 15 \
    "${encoder_options[@]}" \
    -flvflags no_duration_filesize -f flv -rtmp_enhanced_codecs "$fourcc" \
    "rtmp://127.0.0.1:${case_port}/live/${stream}" >"$ffmpeg_log" 2>&1; then
    printf '%s preview publisher failed.\n' "$codec" >&2
    sed -n '1,40p' "$ffmpeg_log" >&2
    exit 1
  fi

  for attempt in {1..200}; do
    if grep -q "^PREVIEW_FRAME codec=${codec} " "$probe_log" 2>/dev/null; then
      break
    fi
    sleep 0.025
  done
  touch "$stop_file"
  wait "$PROBE_PID"
  PROBE_PID=""

  summary=$(grep '^PREVIEW_SUMMARY ' "$probe_log" | tail -n 1)
  frames=$(sed -n 's/.*frames=\([0-9][0-9]*\).*/\1/p' <<<"$summary")
  if [[ -z "$frames" || "$frames" -lt 1 ||
        "$summary" != *"codec=${codec}"* ||
        "$summary" != *'width=320 height=180'* ||
        "$summary" != *'errors=0'* ]] ||
     grep -q '^PREVIEW_ERROR ' "$probe_log" ||
     ! grep -q "^PREVIEW_FRAME codec=${codec} width=320 height=180 pixelFormat=rgba32 pixels=230400 " \
       "$probe_log"; then
    printf '%s enhanced preview smoke failed: %s\n' "$codec" "$summary" >&2
    sed -n '1,160p' "$probe_log" >&2
    exit 1
  fi
  CASE_FRAMES="$frames"
}

run_preview_case hevc HEVC libx265 hvc1 "$PORT"
hevc_frames="$CASE_FRAMES"
run_preview_case av1 AV1 libsvtav1 av01 "$((PORT + 1))"
av1_frames="$CASE_FRAMES"
run_preview_case vp9 VP9 libvpx-vp9 vp09 "$((PORT + 2))"
vp9_frames="$CASE_FRAMES"

printf 'Enhanced preview smoke passed: HEVC=%s AV1=%s VP9=%s RGBA frames\n' \
  "$hevc_frames" "$av1_frames" "$vp9_frames"
if [[ "$KEEP_LOGS" -eq 1 ]]; then
  printf 'Logs: %s\n' "$TMP_DIR"
fi

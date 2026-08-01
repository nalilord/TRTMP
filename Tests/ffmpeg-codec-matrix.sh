#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-1940}"
DURATION="${DURATION:-1.0}"
TIER="all"
STRICT=0
BUILD=1
KEEP_LOGS=0
TMP_DIR=""
PROBE_PID=""
PROBE_FD=""
RUN_COUNT=0
PASS_COUNT=0
PARTIAL_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Usage: ./Tests/ffmpeg-codec-matrix.sh [options]

Options:
  --tier 1|2|all    Select the codec tier (default: all).
  --strict          Fail if an available codec is not fully understood by TRTMP.
  --no-build        Reuse Bin/linux/RtmpCodecInteropProbe.
  --keep-logs       Keep the temporary directory and print its path.
  --port PORT       Probe listen port (default: 1940 or $PORT).
  --duration SEC    Synthetic stream duration (default: 1.0 or $DURATION).
  -h, --help        Show this help.

Encoder overrides:
  H264_ENCODER, MP3_ENCODER, HEVC_ENCODER, AV1_ENCODER, VP9_ENCODER,
  VP8_ENCODER, OPUS_ENCODER

The default report mode exits nonzero only for harness/transport failures.
Strict mode also treats incomplete TRTMP codec classification as a failure.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      shift
      TIER="${1:-}"
      ;;
    --strict)
      STRICT=1
      ;;
    --no-build)
      BUILD=0
      ;;
    --keep-logs)
      KEEP_LOGS=1
      ;;
    --port)
      shift
      PORT="${1:-}"
      ;;
    --duration)
      shift
      DURATION="${1:-}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$TIER" != "1" && "$TIER" != "2" && "$TIER" != "all" ]]; then
  printf 'Invalid tier: %s\n' "$TIER" >&2
  exit 2
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  printf 'ffmpeg is required but was not found in PATH.\n' >&2
  exit 2
fi

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

has_encoder() {
  ffmpeg -hide_banner -encoders 2>/dev/null | awk -v wanted="$1" '$2 == wanted { found=1 } END { exit !found }'
}

pick_encoder() {
  local override="$1"
  shift
  local candidate
  if [[ -n "$override" ]]; then
    if has_encoder "$override"; then
      printf '%s' "$override"
      return 0
    fi
    return 1
  fi
  for candidate in "$@"; do
    if has_encoder "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

wait_for_probe() {
  local attempt
  for attempt in {1..100}; do
    if grep -q '^PROBE_READY ' "$TMP_DIR/probe.log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
      printf 'Probe exited before becoming ready:\n' >&2
      sed -n '1,160p' "$TMP_DIR/probe.log" >&2
      return 1
    fi
    sleep 0.05
  done
  printf 'Timed out waiting for codec probe.\n' >&2
  return 1
}

case_media_seen() {
  local stream="$1"
  local media="$2"
  grep -q "^MEDIA stream=${stream} media=${media} " "$TMP_DIR/probe.log"
}

case_wire_seen() {
  local stream="$1"
  local media="$2"
  local signaling="$3"
  local codec="$4"
  grep -q "^MEDIA stream=${stream} media=${media} signaling=${signaling} codec=${codec} " "$TMP_DIR/probe.log"
}

case_library_understands() {
  local stream="$1"
  local media="$2"
  local signaling="$3"
  local codec="$4"
  local enhanced_pattern=""
  if [[ "$signaling" == "enhanced" ]]; then
    enhanced_pattern="libEnhanced=True libFourCC=${codec}"
  fi
  if [[ "$media" == "video" ]]; then
    grep -q "^MEDIA stream=${stream} media=video .*packetType=0 .*${enhanced_pattern}.*libConfig=True.*libKeyframe=True" "$TMP_DIR/probe.log"
  elif [[ "$stream" == "aac" ]]; then
    grep -q "^MEDIA stream=${stream} media=audio .*libConfig=True" "$TMP_DIR/probe.log"
  elif [[ "$signaling" == "enhanced" ]]; then
    grep -q "^MEDIA stream=${stream} media=audio .*packetType=0 .*${enhanced_pattern}.*libConfig=True" "$TMP_DIR/probe.log"
  else
    case_media_seen "$stream" "$media"
  fi
}

record_skip() {
  local name="$1"
  local reason="$2"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf '%-8s SKIP     %s\n' "$name" "$reason"
}

run_case() {
  local name="$1"
  local tier="$2"
  local media="$3"
  local encoder="$4"
  local signaling="$5"
  local fourcc="$6"
  shift 6
  local log="$TMP_DIR/ffmpeg-${name}.log"
  local url="rtmp://127.0.0.1:${PORT}/live/${name}"
  local probe_lines_before
  local status=0
  local -a command=(ffmpeg -hide_banner -loglevel warning -nostdin)

  if [[ "$media" == "video" ]]; then
    command+=(
      -f lavfi -i "testsrc2=size=320x180:rate=15"
      -t "$DURATION" -an -c:v "$encoder" -pix_fmt yuv420p -g 15
    )
  else
    command+=(
      -f lavfi -i "sine=frequency=1000:sample_rate=48000"
      -t "$DURATION" -vn -c:a "$encoder" -ar 48000 -ac 2
    )
  fi
  command+=("$@" -flvflags no_duration_filesize -f flv)
  if [[ "$signaling" == "enhanced" ]]; then
    command+=(-rtmp_enhanced_codecs "$fourcc")
  fi
  command+=("$url")

  RUN_COUNT=$((RUN_COUNT + 1))
  probe_lines_before="$(wc -l <"$TMP_DIR/probe.log")"
  "${command[@]}" >"$log" 2>&1 || status=$?
  sleep 0.05

  if [[ "$status" -ne 0 ]]; then
    if grep -q 'Unsupported codec fourcc' "$log" &&
      grep -q 'Not yet implemented in FFmpeg' "$log"; then
      SKIP_COUNT=$((SKIP_COUNT + 1))
      printf '%-8s SKIP     FFmpeg RTMP publisher does not implement %s signaling\n' "$name" "$fourcc"
      return
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     ffmpeg exited %d (tier %s, encoder %s)\n' "$name" "$status" "$tier" "$encoder"
    sed -n '1,8p' "$log" | sed 's/^/           /'
    tail -n "+$((probe_lines_before + 1))" "$TMP_DIR/probe.log" | \
      sed -n '/^LOG /{s/^/           server: /;p;}' | sed -n '1,3p'
    return
  fi
  if ! case_media_seen "$name" "$media"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     publisher succeeded but probe saw no %s packets\n' "$name" "$media"
    return
  fi
  if ! case_wire_seen "$name" "$media" "$signaling" "$fourcc"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     received packets did not use expected %s/%s signaling\n' "$name" "$signaling" "$fourcc"
    return
  fi
  if case_library_understands "$name" "$media" "$signaling" "$fourcc"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '%-8s PASS     ingest + wire signaling + TRTMP classification\n' "$name"
  else
    PARTIAL_COUNT=$((PARTIAL_COUNT + 1))
    printf '%-8s PARTIAL  ingest and %s/%s wire signaling work; TRTMP classification incomplete\n' \
      "$name" "$signaling" "$fourcc"
  fi
}

run_video_if_available() {
  local name="$1" tier="$2" signaling="$3" fourcc="$4" override="$5"
  shift 5
  local candidates="$1"
  shift
  local encoder
  read -r -a candidate_array <<<"$candidates"
  if ! encoder="$(pick_encoder "$override" "${candidate_array[@]}")"; then
    record_skip "$name" "no supported software encoder (${candidates})"
    return
  fi
  run_case "$name" "$tier" video "$encoder" "$signaling" "$fourcc" "$@"
}

run_audio_if_available() {
  local name="$1" tier="$2" signaling="$3" fourcc="$4" override="$5"
  shift 5
  local candidates="$1"
  shift
  local encoder
  read -r -a candidate_array <<<"$candidates"
  if ! encoder="$(pick_encoder "$override" "${candidate_array[@]}")"; then
    record_skip "$name" "no supported encoder (${candidates})"
    return
  fi
  run_case "$name" "$tier" audio "$encoder" "$signaling" "$fourcc" "$@"
}

cd "$ROOT"
if [[ "$BUILD" -eq 1 ]]; then
  ./build-fpc.sh Examples/RtmpCodecInteropProbe.pas
fi
if [[ ! -x "$ROOT/Bin/linux/RtmpCodecInteropProbe" ]]; then
  printf 'Codec probe executable not found; build it first or omit --no-build.\n' >&2
  exit 2
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trtmp-codec-matrix.XXXXXX")"
mkfifo "$TMP_DIR/probe.stdin"
exec {PROBE_FD}<>"$TMP_DIR/probe.stdin"
"$ROOT/Bin/linux/RtmpCodecInteropProbe" "$PORT" \
  <"$TMP_DIR/probe.stdin" >"$TMP_DIR/probe.log" 2>&1 &
PROBE_PID=$!
wait_for_probe || exit 2

printf 'TRTMP FFmpeg codec matrix (FFmpeg %s)\n' "$(ffmpeg -hide_banner -version | sed -n '1s/^ffmpeg version \([^ ]*\).*/\1/p')"
printf 'Probe: rtmp://127.0.0.1:%s/live/<codec>, duration=%ss, tier=%s\n\n' "$PORT" "$DURATION" "$TIER"

if [[ "$TIER" == "1" || "$TIER" == "all" ]]; then
  run_video_if_available h264 1 legacy avc1 "${H264_ENCODER:-}" "libx264"
  run_audio_if_available aac 1 legacy aac "" "aac" -b:a 96k
  run_audio_if_available mp3 1 legacy mp3 "${MP3_ENCODER:-}" "libmp3lame mp3"
fi

if [[ "$TIER" == "2" || "$TIER" == "all" ]]; then
  run_video_if_available hevc 2 enhanced hvc1 "${HEVC_ENCODER:-}" "libx265"
  run_video_if_available av1 2 enhanced av01 "${AV1_ENCODER:-}" "libsvtav1 libaom-av1 librav1e"
  run_video_if_available vp9 2 enhanced vp09 "${VP9_ENCODER:-}" "libvpx-vp9"
  run_video_if_available vp8 2 enhanced vp08 "${VP8_ENCODER:-}" "libvpx"
  run_audio_if_available opus 2 enhanced Opus "${OPUS_ENCODER:-}" "libopus opus" -strict experimental -b:a 96k
  run_audio_if_available flac 2 enhanced fLaC "" "flac"
  run_audio_if_available ac3 2 enhanced ac-3 "" "ac3" -b:a 192k
  run_audio_if_available eac3 2 enhanced ec-3 "" "eac3" -b:a 192k
fi

printf '\n' >&"$PROBE_FD"
wait "$PROBE_PID" || true
PROBE_PID=""

printf '\nSummary: pass=%d partial=%d fail=%d skip=%d attempted=%d\n' \
  "$PASS_COUNT" "$PARTIAL_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$RUN_COUNT"
if [[ "$KEEP_LOGS" -eq 1 ]]; then
  printf 'Logs: %s\n' "$TMP_DIR"
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
if [[ "$STRICT" -eq 1 && "$PARTIAL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0

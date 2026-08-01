#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INGEST_PORT="${INGEST_PORT:-1941}"
RECEIVER_PORT="${RECEIVER_PORT:-1951}"
DURATION="${DURATION:-1.0}"
BUILD=1
KEEP_LOGS=0
TMP_DIR=""
RELAY_PID=""
RECEIVER_PID=""
RELAY_FD=""
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Usage: bash Tests/ffmpeg-external-relay-smoke.sh [options]

Runs representative external-boundary cases:
  H.264 legacy video, HEVC enhanced video, and Opus enhanced audio.

Options:
  --no-build          Reuse Bin/linux/RtmpRestreamConsole.
  --keep-logs         Keep logs and print their directory.
  --ingest-port PORT  TRTMP ingest port (default: 1941).
  --receiver-port P   FFmpeg RTMP listen port (default: 1951).
  --duration SEC      Stream duration (default: 1.0).
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --keep-logs) KEEP_LOGS=1 ;;
    --ingest-port) shift; INGEST_PORT="${1:-}" ;;
    --receiver-port) shift; RECEIVER_PORT="${1:-}" ;;
    --duration) shift; DURATION="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

cleanup_case() {
  if [[ -n "$RELAY_FD" ]]; then
    eval "exec ${RELAY_FD}>&-" 2>/dev/null || true
    RELAY_FD=""
  fi
  if [[ -n "$RELAY_PID" ]] && kill -0 "$RELAY_PID" 2>/dev/null; then
    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  if [[ -n "$RECEIVER_PID" ]] && kill -0 "$RECEIVER_PID" 2>/dev/null; then
    kill "$RECEIVER_PID" 2>/dev/null || true
    wait "$RECEIVER_PID" 2>/dev/null || true
  fi
  RELAY_PID=""
  RECEIVER_PID=""
}

cleanup() {
  cleanup_case
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" && "$KEEP_LOGS" -eq 0 ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

has_encoder() {
  ffmpeg -hide_banner -encoders 2>/dev/null |
    awk -v wanted="$1" '$2 == wanted { found=1 } END { exit !found }'
}

wait_for_relay() {
  local log="$1" attempt
  for attempt in {1..120}; do
    if grep -q 'Relay connected and publish established' "$log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$RELAY_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.05
  done
  return 1
}

run_case() {
  local name="$1" media="$2" encoder="$3" signaling="$4" codec="$5" expected="$6"
  shift 6
  local case_dir="$TMP_DIR/$name"
  local fifo="$case_dir/relay.stdin"
  local publisher_status=0 relay_status=0 receiver_status=0
  local -a receiver=(ffmpeg -hide_banner -loglevel info -nostdin -rtmp_listen 1)
  local -a publisher=(ffmpeg -hide_banner -loglevel warning -nostdin)

  if ! has_encoder "$encoder"; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf '%-8s SKIP     encoder %s unavailable\n' "$name" "$encoder"
    return
  fi

  mkdir -p "$case_dir"
  mkfifo "$fifo"
  exec {RELAY_FD}<>"$fifo"

  if [[ "$signaling" == "enhanced" ]]; then
    receiver+=(-rtmp_enhanced_codecs "$codec")
  fi
  receiver+=(
    -timeout 20 -i "rtmp://127.0.0.1:${RECEIVER_PORT}/live/${name}"
    -map "0:${media}:0" -c copy -f null -
  )
  "${receiver[@]}" >"$case_dir/receiver.log" 2>&1 &
  RECEIVER_PID=$!
  sleep 0.25

  "$ROOT/Bin/linux/RtmpRestreamConsole" \
    "rtmp://127.0.0.1:${RECEIVER_PORT}/live/${name}" "$INGEST_PORT" pass \
    <"$fifo" >"$case_dir/relay.log" 2>&1 &
  RELAY_PID=$!
  if ! wait_for_relay "$case_dir/relay.log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     TRTMP did not establish FFmpeg downstream publish\n' "$name"
    cleanup_case
    return
  fi

  if [[ "$media" == "v" ]]; then
    publisher+=(
      -f lavfi -i "testsrc2=size=320x180:rate=15"
      -t "$DURATION" -an -c:v "$encoder" -pix_fmt yuv420p -g 15
    )
  else
    publisher+=(
      -f lavfi -i "sine=frequency=1000:sample_rate=48000"
      -t "$DURATION" -vn -c:a "$encoder" -ar 48000 -ac 2
    )
  fi
  publisher+=("$@" -flvflags no_duration_filesize -f flv)
  if [[ "$signaling" == "enhanced" ]]; then
    publisher+=(-rtmp_enhanced_codecs "$codec")
  fi
  publisher+=("rtmp://127.0.0.1:${INGEST_PORT}/live/${name}")
  "${publisher[@]}" >"$case_dir/publisher.log" 2>&1 || publisher_status=$?
  sleep 0.4
  printf '\n' >&"$RELAY_FD"
  wait "$RELAY_PID" || relay_status=$?
  RELAY_PID=""
  eval "exec ${RELAY_FD}>&-" 2>/dev/null || true
  RELAY_FD=""
  wait "$RECEIVER_PID" || receiver_status=$?
  RECEIVER_PID=""

  if [[ "$publisher_status" -ne 0 || "$relay_status" -ne 0 ||
        "$receiver_status" -ne 0 ]]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     status publisher=%d relay=%d receiver=%d\n' \
      "$name" "$publisher_status" "$relay_status" "$receiver_status"
    sed -n '1,12p' "$case_dir/receiver.log" | sed 's/^/           /'
    return
  fi
  if ! grep -Eqi "$expected" "$case_dir/receiver.log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     FFmpeg receiver did not identify expected codec\n' "$name"
    sed -n '1,20p' "$case_dir/receiver.log" | sed 's/^/           /'
    return
  fi

  PASS_COUNT=$((PASS_COUNT + 1))
  printf '%-8s PASS     FFmpeg receiver identified %s after TRTMP relay\n' \
    "$name" "$codec"
}

cd "$ROOT"
if [[ "$BUILD" -eq 1 ]]; then
  ./build-fpc.sh Examples/RtmpRestreamConsole.pas
fi
if [[ ! -x "$ROOT/Bin/linux/RtmpRestreamConsole" ]]; then
  printf 'RtmpRestreamConsole executable not found.\n' >&2
  exit 2
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trtmp-external-relay.XXXXXX")"
printf 'TRTMP external FFmpeg receiver smoke\n\n'
run_case h264 v libx264 legacy avc1 'Video: h264'
run_case hevc v libx265 enhanced hvc1 'Video: hevc'
run_case opus a libopus enhanced Opus 'Audio: opus' -b:a 96k

printf '\nSummary: pass=%d fail=%d skip=%d\n' \
  "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
if [[ "$KEEP_LOGS" -eq 1 ]]; then
  printf 'Logs: %s\n' "$TMP_DIR"
fi
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0

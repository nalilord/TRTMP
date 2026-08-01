#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INGEST_PORT="${INGEST_PORT:-1940}"
DOWNSTREAM_PORT="${DOWNSTREAM_PORT:-1950}"
DURATION="${DURATION:-1.0}"
TIER="all"
BUILD=1
KEEP_LOGS=0
TMP_DIR=""
PROBE_PID=""
PROBE_FD=""
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RUN_COUNT=0

usage() {
  cat <<'EOF'
Usage: bash Tests/ffmpeg-relay-matrix.sh [options]

Options:
  --tier 1|2|all       Select codec tier (default: all).
  --no-build           Reuse Bin/linux/RtmpCodecRelayProbe.
  --keep-logs          Keep logs and print their directory.
  --ingest-port PORT   Upstream TRTMP port (default: 1940).
  --downstream-port P  Downstream verification port (default: 1950).
  --duration SEC       Stream duration per codec (default: 1.0).
  -h, --help           Show this help.

Encoder overrides:
  H264_ENCODER, MP3_ENCODER, HEVC_ENCODER, AV1_ENCODER, VP9_ENCODER,
  VP8_ENCODER, OPUS_ENCODER

Each case verifies:
  FFmpeg -> TRTMP ingest -> TRtmpClient -> TRTMP verification server
  connect FourCC advertisement, wire signaling, packet flags, packet/byte
  counts, and an ordered digest over message type + timestamp + payload.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      shift
      TIER="${1:-}"
      ;;
    --no-build)
      BUILD=0
      ;;
    --keep-logs)
      KEEP_LOGS=1
      ;;
    --ingest-port)
      shift
      INGEST_PORT="${1:-}"
      ;;
    --downstream-port)
      shift
      DOWNSTREAM_PORT="${1:-}"
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
if [[ "$INGEST_PORT" == "$DOWNSTREAM_PORT" ]]; then
  printf 'Ingest and downstream ports must differ.\n' >&2
  exit 2
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  printf 'ffmpeg is required but was not found in PATH.\n' >&2
  exit 2
fi

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
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" && "$KEEP_LOGS" -eq 0 ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

has_encoder() {
  ffmpeg -hide_banner -encoders 2>/dev/null |
    awk -v wanted="$1" '$2 == wanted { found=1 } END { exit !found }'
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

record_skip() {
  local name="$1" reason="$2"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf '%-8s SKIP     %s\n' "$name" "$reason"
}

wait_for_probe() {
  local log="$1" attempt
  for attempt in {1..120}; do
    if grep -q '^RELAY_READY ' "$log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.05
  done
  return 1
}

summary_value() {
  local key="$1" log="$2"
  sed -n "s/^RELAY_SUMMARY .*${key}=\([^ ]*\).*/\1/p" "$log" | tail -n 1
}

run_case() {
  local name="$1" tier="$2" media="$3" encoder="$4" signaling="$5" codec="$6"
  shift 6
  local case_dir="$TMP_DIR/$name"
  local ffmpeg_log="$case_dir/ffmpeg.log"
  local probe_log="$case_dir/probe.log"
  local fifo="$case_dir/probe.stdin"
  local status=0
  local source_packets relay_packets source_bytes relay_bytes source_digest relay_digest
  local -a command=(ffmpeg -hide_banner -loglevel warning -nostdin)

  mkdir -p "$case_dir"
  mkfifo "$fifo"
  exec {PROBE_FD}<>"$fifo"
  "$ROOT/Bin/linux/RtmpCodecRelayProbe" "$INGEST_PORT" "$DOWNSTREAM_PORT" "$name" \
    <"$fifo" >"$probe_log" 2>&1 &
  PROBE_PID=$!
  if ! wait_for_probe "$probe_log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     relay probe did not become ready\n' "$name"
    sed -n '1,20p' "$probe_log" | sed 's/^/           /'
    cleanup_probe
    return
  fi

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
    command+=(-rtmp_enhanced_codecs "$codec")
  fi
  command+=("rtmp://127.0.0.1:${INGEST_PORT}/live/${name}")

  RUN_COUNT=$((RUN_COUNT + 1))
  "${command[@]}" >"$ffmpeg_log" 2>&1 || status=$?
  sleep 0.35
  printf '\n' >&"$PROBE_FD"
  if ! wait "$PROBE_PID" && [[ "$status" -eq 0 ]]; then
    status=1
  fi
  PROBE_PID=""
  eval "exec ${PROBE_FD}>&-" 2>/dev/null || true
  PROBE_FD=""

  if [[ "$status" -ne 0 ]]; then
    if grep -q 'Unsupported codec fourcc' "$ffmpeg_log" &&
      grep -q 'Not yet implemented in FFmpeg' "$ffmpeg_log"; then
      record_skip "$name" "FFmpeg RTMP publisher does not implement ${codec} signaling"
      return
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     publisher or relay probe exited %d\n' "$name" "$status"
    sed -n '1,8p' "$ffmpeg_log" | sed 's/^/           /'
    sed -n '/_LOG /p' "$probe_log" | sed -n '1,5p' | sed 's/^/           /'
    return
  fi

  if ! grep -q "^SOURCE_MEDIA .* media=${media} signaling=${signaling} codec=${codec} " "$probe_log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     expected source signaling was not observed\n' "$name"
    return
  fi
  if ! grep -q "^RELAY_MEDIA .* media=${media} signaling=${signaling} codec=${codec} " "$probe_log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     expected downstream signaling was not observed\n' "$name"
    return
  fi
  if [[ "$signaling" == "enhanced" ]] &&
    ! grep -q "^RELAY_CONNECT .*enhancedCodecs=.*${codec}" "$probe_log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     downstream connect omitted %s capability\n' "$name" "$codec"
    return
  fi
  if [[ "$signaling" == "enhanced" ]] &&
    ! grep -q "^RELAY_MEDIA .* codec=${codec} .*libEnhanced=True" "$probe_log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     downstream did not classify enhanced FourCC\n' "$name"
    return
  fi
  if [[ "$media" == "video" ]] &&
    ! grep -q "^RELAY_MEDIA .* codec=${codec} .*libKeyframe=True" "$probe_log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     downstream did not retain video keyframe classification\n' "$name"
    return
  fi
  if [[ "$name" != "mp3" ]] &&
    ! grep -q "^RELAY_MEDIA .* codec=${codec} .*libConfig=True" "$probe_log"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     downstream did not retain codec configuration classification\n' "$name"
    return
  fi

  source_packets="$(summary_value sourcePackets "$probe_log")"
  relay_packets="$(summary_value relayPackets "$probe_log")"
  source_bytes="$(summary_value sourceBytes "$probe_log")"
  relay_bytes="$(summary_value relayBytes "$probe_log")"
  source_digest="$(summary_value sourceDigest "$probe_log")"
  relay_digest="$(summary_value relayDigest "$probe_log")"
  if [[ -z "$source_packets" || "$source_packets" == "0" ||
        "$source_packets" != "$relay_packets" ||
        "$source_bytes" != "$relay_bytes" ||
        "$source_digest" != "$relay_digest" ]]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '%-8s FAIL     relay fidelity mismatch packets=%s/%s bytes=%s/%s digest=%s/%s\n' \
      "$name" "$source_packets" "$relay_packets" "$source_bytes" "$relay_bytes" \
      "$source_digest" "$relay_digest"
    return
  fi

  PASS_COUNT=$((PASS_COUNT + 1))
  printf '%-8s PASS     %s packets, %s bytes, digest %s\n' \
    "$name" "$source_packets" "$source_bytes" "$source_digest"
}

run_video_if_available() {
  local name="$1" tier="$2" signaling="$3" codec="$4" override="$5"
  shift 5
  local candidates="$1" encoder
  shift
  local -a candidate_array
  read -r -a candidate_array <<<"$candidates"
  if ! encoder="$(pick_encoder "$override" "${candidate_array[@]}")"; then
    record_skip "$name" "no supported software encoder (${candidates})"
    return
  fi
  run_case "$name" "$tier" video "$encoder" "$signaling" "$codec" "$@"
}

run_audio_if_available() {
  local name="$1" tier="$2" signaling="$3" codec="$4" override="$5"
  shift 5
  local candidates="$1" encoder
  shift
  local -a candidate_array
  read -r -a candidate_array <<<"$candidates"
  if ! encoder="$(pick_encoder "$override" "${candidate_array[@]}")"; then
    record_skip "$name" "no supported encoder (${candidates})"
    return
  fi
  run_case "$name" "$tier" audio "$encoder" "$signaling" "$codec" "$@"
}

cd "$ROOT"
if [[ "$BUILD" -eq 1 ]]; then
  ./build-fpc.sh Examples/RtmpCodecRelayProbe.pas
fi
if [[ ! -x "$ROOT/Bin/linux/RtmpCodecRelayProbe" ]]; then
  printf 'Relay probe executable not found; build it first or omit --no-build.\n' >&2
  exit 2
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trtmp-relay-matrix.XXXXXX")"
printf 'TRTMP FFmpeg relay matrix (FFmpeg %s)\n' \
  "$(ffmpeg -hide_banner -version | sed -n '1s/^ffmpeg version \([^ ]*\).*/\1/p')"
printf 'Path: FFmpeg -> :%s TRTMP -> TRtmpClient -> :%s TRTMP, duration=%ss\n\n' \
  "$INGEST_PORT" "$DOWNSTREAM_PORT" "$DURATION"

if [[ "$TIER" == "1" || "$TIER" == "all" ]]; then
  run_video_if_available h264 1 legacy avc1 "${H264_ENCODER:-}" "libx264"
  run_audio_if_available aac 1 legacy aac "" "aac" -b:a 96k
  run_audio_if_available mp3 1 legacy mp3 "${MP3_ENCODER:-}" "libmp3lame mp3"
fi

if [[ "$TIER" == "2" || "$TIER" == "all" ]]; then
  run_video_if_available hevc 2 enhanced hvc1 "${HEVC_ENCODER:-}" "libx265"
  run_video_if_available av1 2 enhanced av01 "${AV1_ENCODER:-}" \
    "libsvtav1 libaom-av1 librav1e"
  run_video_if_available vp9 2 enhanced vp09 "${VP9_ENCODER:-}" "libvpx-vp9"
  run_video_if_available vp8 2 enhanced vp08 "${VP8_ENCODER:-}" "libvpx"
  run_audio_if_available opus 2 enhanced Opus "${OPUS_ENCODER:-}" \
    "libopus opus" -strict experimental -b:a 96k
  run_audio_if_available flac 2 enhanced fLaC "" "flac"
  run_audio_if_available ac3 2 enhanced ac-3 "" "ac3" -b:a 192k
  run_audio_if_available eac3 2 enhanced ec-3 "" "eac3" -b:a 192k
fi

printf '\nSummary: pass=%d fail=%d skip=%d attempted=%d\n' \
  "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$RUN_COUNT"
if [[ "$KEEP_LOGS" -eq 1 ]]; then
  printf 'Logs: %s\n' "$TMP_DIR"
fi
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0

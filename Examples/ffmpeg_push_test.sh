#!/usr/bin/env bash
set -euo pipefail

TARGET_URL="${1:-rtmp://127.0.0.1:1935/live/test}"

if [[ "${TARGET_URL}" == "--help" || "${TARGET_URL}" == "-h" ]]; then
  cat <<'USAGE'
Usage:
  ./Examples/ffmpeg_push_test.sh [rtmp-url]

Default target:
  rtmp://127.0.0.1:1935/live/test

Environment overrides:
  WIDTH=1280
  HEIGHT=720
  FPS=30
  GOP=30
  VIDEO_BITRATE=2500k
  VIDEO_MAXRATE=2500k
  VIDEO_BUFSIZE=5000k
  AUDIO_BITRATE=128k
  AUDIO_RATE=48000
  AUDIO_FREQ=1000

Example:
  ./Examples/ffmpeg_push_test.sh rtmp://127.0.0.1:1935/live/ffmpeg-test
USAGE
  exit 0
fi

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
GOP="${GOP:-30}"
VIDEO_BITRATE="${VIDEO_BITRATE:-2500k}"
VIDEO_MAXRATE="${VIDEO_MAXRATE:-2500k}"
VIDEO_BUFSIZE="${VIDEO_BUFSIZE:-5000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
AUDIO_RATE="${AUDIO_RATE:-48000}"
AUDIO_FREQ="${AUDIO_FREQ:-1000}"

echo "Pushing FFmpeg test stream to ${TARGET_URL}"
echo "Video: ${WIDTH}x${HEIGHT} @ ${FPS} fps, GOP=${GOP}, bitrate=${VIDEO_BITRATE}"
echo "Audio: ${AUDIO_RATE} Hz sine @ ${AUDIO_FREQ} Hz, bitrate=${AUDIO_BITRATE}"

exec ffmpeg \
  -re \
  -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}" \
  -f lavfi -i "sine=frequency=${AUDIO_FREQ}:sample_rate=${AUDIO_RATE}" \
  -map 0:v:0 -map 1:a:0 \
  -c:v libx264 \
  -preset ultrafast \
  -tune zerolatency \
  -pix_fmt yuv420p \
  -g "${GOP}" \
  -keyint_min "${GOP}" \
  -sc_threshold 0 \
  -b:v "${VIDEO_BITRATE}" \
  -maxrate "${VIDEO_MAXRATE}" \
  -bufsize "${VIDEO_BUFSIZE}" \
  -c:a aac \
  -b:a "${AUDIO_BITRATE}" \
  -ar "${AUDIO_RATE}" \
  -ac 2 \
  -af "aresample=async=1:first_pts=0" \
  -flvflags no_duration_filesize \
  -f flv \
  "${TARGET_URL}"

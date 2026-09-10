#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
headers="${FFMPEG_HEADERS_DIR:-$root/ThirdParty/TRadioPlayer/Headers}"
output="$(mktemp -d /tmp/trtmp-hardening-tests.XXXXXX)"
mkdir -p "$output/base" "$output/preview"
run_test() {
  local name="$1" variant="$2"
  shift 2
  if ! fpc -Mdelphi -gh -gl -Fu"$root/Source" -FE"$output" -FU"$output/$variant" \
      "$@" "$root/Tests/$name.pas" >"$output/$name.build.log" 2>&1; then
    tail -30 "$output/$name.build.log"; return 1
  fi
  if ! timeout 30s "$output/$name" >"$output/$name.log" 2>&1; then
    tail -40 "$output/$name.log"; return 1
  fi
  if grep -Eq '[1-9][0-9]* unfreed memory blocks' "$output/$name.log"; then
    tail -40 "$output/$name.log"; return 1
  fi
  head -1 "$output/$name.log"
}
run_test RtmpServerLifecycleTests base "$@"
run_test RtmpAmfCleanupTests base "$@"
if [[ ! -d "$headers" ]]; then
  echo 'Set FFMPEG_HEADERS_DIR to run the preview callback regression.' >&2
  exit 1
fi
run_test RtmpPreviewThreadTests preview -dUSE_FFMPEG -Fu"$headers" "$@"
printf 'TRTMP hardening tests: PASS (logs: %s)\n' "$output"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SOCKET_TESTS=1
RUN_DELPHI=1
RUN_FFMPEG=1
RUN_SFML=1

usage() {
  cat <<'EOF'
Usage: ./smoke-test.sh [options]

Options:
  --skip-socket   Build everything, but skip socket-based runtime tests.
  --skip-delphi   Skip Delphi Win64 compile checks.
  --skip-ffmpeg   Skip optional FFmpeg decoder/preview checks.
  --skip-sfml     Skip optional SFML preview builds.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-socket)
      RUN_SOCKET_TESTS=0
      ;;
    --skip-delphi)
      RUN_DELPHI=0
      ;;
    --skip-ffmpeg)
      RUN_FFMPEG=0
      RUN_SFML=0
      ;;
    --skip-sfml)
      RUN_SFML=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

cd "$ROOT"

build_fpc_examples=(
  Examples/RtmpGatewayConsole.pas
  Examples/RtmpGraphGatewayConsole.pas
  Examples/RtmpIngestConsole.pas
  Examples/RtmpRestreamConsole.pas
  Examples/RtmpPlayConsole.pas
  Examples/RtmpApiErgonomicsSmoke.pas
  Examples/RtmpBufferSmoke.pas
  Examples/RtmpChunkReassemblerSmoke.pas
  Examples/RtmpAnalyzerSmoke.pas
  Examples/RtmpClientSmoke.pas
  Examples/RtmpClientReconnectSmoke.pas
  Examples/RtmpClientRejectSmoke.pas
  Examples/RtmpClientTimestampSmoke.pas
  Examples/RtmpClientReconnectLiveEdgeSmoke.pas
  Examples/RtmpServerHardeningSmoke.pas
  Examples/RtmpServerCommandFlowSmoke.pas
  Examples/RtmpServerPublishEventSmoke.pas
  Examples/RtmpServerLatencyStatsSmoke.pas
  Examples/RtmpServerSmallBudgetSmoke.pas
  Examples/RtmpRelayPolicySmoke.pas
  Examples/RtmpPipelineSmoke.pas
  Examples/RtmpLiveSourceSwitcherSmoke.pas
  Examples/RtmpPlayReconnectSmoke.pas
)

runtime_local=(
  ./Bin/linux/RtmpApiErgonomicsSmoke
  ./Bin/linux/RtmpBufferSmoke
  ./Bin/linux/RtmpChunkReassemblerSmoke
  ./Bin/linux/RtmpAnalyzerSmoke
)

runtime_socket=(
  ./Bin/linux/RtmpClientSmoke
  ./Bin/linux/RtmpClientReconnectSmoke
  ./Bin/linux/RtmpClientRejectSmoke
  ./Bin/linux/RtmpClientTimestampSmoke
  ./Bin/linux/RtmpClientReconnectLiveEdgeSmoke
  ./Bin/linux/RtmpServerHardeningSmoke
  ./Bin/linux/RtmpServerCommandFlowSmoke
  ./Bin/linux/RtmpServerPublishEventSmoke
  ./Bin/linux/RtmpServerLatencyStatsSmoke
  ./Bin/linux/RtmpServerSmallBudgetSmoke
  ./Bin/linux/RtmpRelayPolicySmoke
  ./Bin/linux/RtmpPipelineSmoke
  ./Bin/linux/RtmpLiveSourceSwitcherSmoke
  ./Bin/linux/RtmpPlayReconnectSmoke
)

printf '== FPC build matrix ==\n'
for project in "${build_fpc_examples[@]}"; do
  printf 'BUILD %s\n' "$project"
  ./build-fpc.sh "$project"
done

if [[ "$RUN_FFMPEG" -eq 1 ]]; then
  printf '== Optional FFmpeg builds ==\n'
  ./build-fpc.sh Examples/RtmpDecoderSmoke.pas --with-ffmpeg
  ./build-fpc.sh Examples/RtmpPreviewCallbackConsole.pas --with-ffmpeg
  if [[ "$RUN_SFML" -eq 1 ]]; then
    ./build-fpc.sh Examples/RtmpSfmlRenderDemo.pas --with-ffmpeg --with-sfml-linux
    ./build-fpc.sh Examples/RtmpLivePreview.pas --with-ffmpeg --with-sfml-linux
  fi
fi

printf '== Local runtime smokes ==\n'
for exe in "${runtime_local[@]}"; do
  printf 'RUN %s\n' "$exe"
  "$exe"
done

if [[ "$RUN_FFMPEG" -eq 1 ]]; then
  printf 'RUN ./Bin/linux/RtmpDecoderSmoke\n'
  ./Bin/linux/RtmpDecoderSmoke
fi

if [[ "$RUN_SOCKET_TESTS" -eq 1 ]]; then
  printf '== Socket runtime smokes ==\n'
  for exe in "${runtime_socket[@]}"; do
    printf 'RUN %s\n' "$exe"
    "$exe"
  done
else
  printf '== Socket runtime smokes skipped ==\n'
fi

if [[ "$RUN_DELPHI" -eq 1 ]]; then
  printf '== Delphi Win64 compile checks ==\n'
  ./build-delphi.sh Examples/RtmpGatewayConsole.pas Win64
  ./build-delphi.sh Examples/RtmpGraphGatewayConsole.pas Win64
  ./build-delphi.sh Examples/RtmpPlayConsole.pas Win64
  if [[ "$RUN_FFMPEG" -eq 1 ]]; then
    ./build-delphi.sh Examples/RtmpPreviewCallbackConsole.pas Win64 --with-ffmpeg
    if [[ "$RUN_SFML" -eq 1 ]]; then
      ./build-delphi.sh Examples/RtmpLivePreview.pas Win64 --with-ffmpeg --with-sfml
    fi
  fi
else
  printf '== Delphi Win64 compile checks skipped ==\n'
fi

printf 'Smoke test matrix completed successfully.\n'

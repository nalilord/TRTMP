#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_REL="${1:-Examples/RtmpGatewayConsole.pas}"
PROJECT_REL="${PROJECT_REL#./}"
PROJECT_PATH="$ROOT/$PROJECT_REL"
OUT_DIR="${FPC_OUT_DIR:-$ROOT/Bin/linux}"
UNIT_DIR="${FPC_UNIT_DIR:-$ROOT/Temp/FPC/Units}"
USE_FFMPEG=0
USE_SFML=0
USE_SFML_LINUX=0
EXTRA_FLAGS=()

if [[ ! -f "$PROJECT_PATH" ]]; then
  printf 'Project not found: %s\n' "$PROJECT_REL" >&2
  exit 1
fi

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-link)
      EXTRA_FLAGS+=("-Cn")
      ;;
    --with-ffmpeg)
      USE_FFMPEG=1
      ;;
    --with-sfml)
      USE_SFML=1
      ;;
    --with-sfml-linux)
      USE_SFML=1
      USE_SFML_LINUX=1
      ;;
    *)
      EXTRA_FLAGS+=("$1")
      ;;
  esac
  shift
done

mkdir -p "$OUT_DIR" "$UNIT_DIR"

cd "$ROOT"
FPC_ARGS=(
  -Mdelphi
  -Fu./Source
  -FE"$OUT_DIR"
  -FU"$UNIT_DIR"
)

if [[ "$USE_FFMPEG" -eq 1 ]]; then
  if [[ ! -d "$ROOT/ThirdParty/TRadioPlayer/Headers" ]]; then
    printf 'FFmpeg Pascal headers not found: %s\n' \
      "$ROOT/ThirdParty/TRadioPlayer/Headers" >&2
    printf 'Install the optional headers there or omit --with-ffmpeg.\n' >&2
    exit 1
  fi
  FPC_ARGS+=(-Fu./ThirdParty/TRadioPlayer/Headers)
fi

if [[ "$USE_SFML" -eq 1 ]]; then
  if [[ ! -d "$ROOT/ThirdParty/PasSFML/Source" ]]; then
    printf 'PasSFML sources not found: %s\n' \
      "$ROOT/ThirdParty/PasSFML/Source" >&2
    printf 'Install the optional sources there or omit the SFML option.\n' >&2
    exit 1
  fi
  FPC_ARGS+=(-Fu./ThirdParty/PasSFML/Source)
fi

if [[ "$USE_SFML_LINUX" -eq 1 ]]; then
  SFML_PREFIX="${SFML_LINUX_PREFIX:-$ROOT/ThirdParty/Linux/Csfml}"
  if [[ ! -d "$SFML_PREFIX/lib" && ! -d "$SFML_PREFIX/lib64" ]]; then
    printf 'Expected local SFML/CSFML prefix at %s with at least a lib or lib64 directory\n' "$SFML_PREFIX" >&2
    exit 1
  fi
  if [[ -d "$SFML_PREFIX/lib" ]]; then
    FPC_ARGS+=(
      -k-L"$SFML_PREFIX/lib"
      -k-rpath="$SFML_PREFIX/lib"
    )
  fi
  if [[ -d "$SFML_PREFIX/lib64" ]]; then
    FPC_ARGS+=(
      -k-L"$SFML_PREFIX/lib64"
      -k-rpath="$SFML_PREFIX/lib64"
    )
  fi
fi

fpc "${FPC_ARGS[@]}" "${EXTRA_FLAGS[@]}" "$PROJECT_REL"

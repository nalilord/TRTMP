#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_REL="${1:-Examples/RtmpGatewayConsole.pas}"
PROJECT_REL="${PROJECT_REL#./}"
PROJECT_PATH="$ROOT/$PROJECT_REL"
PROJECT_DIR="$(dirname "$PROJECT_PATH")"
PROJECT_FILE="$(basename "$PROJECT_PATH")"
PROJECT_NAME="$(basename "${PROJECT_REL%.*}")"
PLATFORM="${DELPHI_PLATFORM:-Win64}"
USE_FFMPEG=0
USE_SFML=0
EXTRA_FLAGS=()

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    Win32|win32|Win64|win64)
      PLATFORM="$1"
      ;;
    --with-ffmpeg)
      USE_FFMPEG=1
      ;;
    --with-sfml)
      USE_SFML=1
      ;;
    *)
      EXTRA_FLAGS+=("$1")
      ;;
  esac
  shift
done

if [[ ! -f "$PROJECT_PATH" ]]; then
  printf 'Project not found: %s\n' "$PROJECT_REL" >&2
  exit 1
fi

if [[ -z "${BDS_VERSION:-}" ]]; then
  if [[ -d "/mnt/c/Program Files (x86)/Embarcadero/Studio/37.0/bin" ]]; then
    BDS_VERSION="37.0"
  elif [[ -d "/mnt/c/Program Files (x86)/Embarcadero/Studio/23.0/bin" ]]; then
    BDS_VERSION="23.0"
  else
    BDS_VERSION="23.0"
  fi
fi

case "$PLATFORM" in
  Win32|win32)
    PLATFORM="Win32"
    PLATFORM_DIR="win32"
    DCC="${DCC32:-/mnt/c/Program Files (x86)/Embarcadero/Studio/${BDS_VERSION}/bin/dcc32.exe}"
    DELPHI_LIB="${DELPHI_LIB_WIN32:-c:\\program files (x86)\\embarcadero\\studio\\${BDS_VERSION}\\lib\\win32\\release}"
    ;;
  Win64|win64)
    PLATFORM="Win64"
    PLATFORM_DIR="win64"
    DCC="${DCC64:-/mnt/c/Program Files (x86)/Embarcadero/Studio/${BDS_VERSION}/bin/dcc64.exe}"
    DELPHI_LIB="${DELPHI_LIB_WIN64:-c:\\program files (x86)\\embarcadero\\studio\\${BDS_VERSION}\\lib\\win64\\release}"
    ;;
  *)
    printf 'Unsupported Delphi platform: %s\n' "$PLATFORM" >&2
    printf 'Use Win32 or Win64.\n' >&2
    exit 1
    ;;
esac

if [[ ! -x "$DCC" ]]; then
  printf 'Compiler not found: %s\n' "$DCC" >&2
  printf 'Set BDS_VERSION or DCC32/DCC64 to match your Delphi installation.\n' >&2
  exit 1
fi

PROJECT_DIR_WIN="$(wslpath -w "$PROJECT_DIR")"
ROOT_WIN="$(wslpath -w "$ROOT")"
BUILD_DIR="$ROOT/Bin/$PLATFORM_DIR"
BUILD_DIR_WIN="$(wslpath -w "$BUILD_DIR")"
SEARCH_PATH_WIN="${PROJECT_DIR_WIN};$(wslpath -w "$ROOT/Source");${DELPHI_LIB}"
INCLUDE_PATH_WIN="${SEARCH_PATH_WIN}"
UNIT_SCOPES="${DELPHI_UNIT_SCOPES:-System;Winapi;Data;Datasnap;Web;Xml;Soap;Vcl;Vcl.Imaging;Vcl.Samples}"

if [[ "$USE_FFMPEG" -eq 1 ]]; then
  HEADER_DIR_WIN="$(wslpath -w "$ROOT/ThirdParty/TRadioPlayer/Headers")"
  SEARCH_PATH_WIN="${SEARCH_PATH_WIN};${HEADER_DIR_WIN}"
  INCLUDE_PATH_WIN="${INCLUDE_PATH_WIN};${HEADER_DIR_WIN}"
fi

if [[ "$USE_SFML" -eq 1 ]]; then
  SFML_DIR_WIN="$(wslpath -w "$ROOT/ThirdParty/PasSFML/Source")"
  SEARCH_PATH_WIN="${SEARCH_PATH_WIN};${SFML_DIR_WIN}"
  INCLUDE_PATH_WIN="${INCLUDE_PATH_WIN};${SFML_DIR_WIN}"
fi

mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"
"$DCC" \
  -B \
  -NS"$UNIT_SCOPES" \
  -U"$SEARCH_PATH_WIN" \
  -I"$INCLUDE_PATH_WIN" \
  -N0"$BUILD_DIR_WIN" \
  -NU"$BUILD_DIR_WIN" \
  -E"$BUILD_DIR_WIN" \
  "${EXTRA_FLAGS[@]}" \
  "$PROJECT_FILE"

printf 'Built %s for %s with Delphi %s in %s\n' \
  "$PROJECT_NAME" "$PLATFORM" "$BDS_VERSION" "$BUILD_DIR"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -d '' FILES < <(find "$ROOT/Source" "$ROOT/Examples" \
  -type f -name '*.pas' -print0 | sort -z)

"$ROOT/Tools/format-pascal-style.pl" --check "${FILES[@]}"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

while IFS= read -r -d '' FILE; do
  UNIT_NAME="$(basename "${FILE%.pas}")"
  DECLARATION="$(head -n 1 "$FILE" | tr -d '\r')"

  if [[ "$UNIT_NAME" != TRTMP.* ]]; then
    printf '%s does not use the TRTMP root namespace\n' "$FILE" >&2
    FAILED=1
  fi

  if [[ "$DECLARATION" != "unit $UNIT_NAME;" ]]; then
    printf '%s declares "%s"; expected "unit %s;"\n' \
      "$FILE" "$DECLARATION" "$UNIT_NAME" >&2
    FAILED=1
  fi
done < <(find "$ROOT/Source" -maxdepth 1 -type f -name '*.pas' -print0 | sort -z)

exit "$FAILED"

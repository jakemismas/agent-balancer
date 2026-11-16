#!/usr/bin/env bash
# Prints the CHANGELOG.md entry for a release version. A -rcN version prints the entry of its base
# version. Fails when the entry is missing or empty.
# Usage: release-notes.sh VERSION [CHANGELOG]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
version="${1:?release-notes: needs a version}"
file="${2:-$ROOT/CHANGELOG.md}"
base="${version%%-rc*}"

notes="$(awk -v want="## $base" '
  $0 == want { on = 1; next }
  on && /^## / { exit }
  on { print }
' "$file")"
# Drop blank lines at both ends.
notes="$(printf '%s\n' "$notes" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "release-notes: $file has no entry for $base." >&2
  exit 1
fi
printf '%s\n' "$notes"

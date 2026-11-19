#!/usr/bin/env bash
# The release version rules, shared by the release workflow and package-release.sh.
# Usage: release-version.sh current
#        release-version.sh check VERSION PRERELEASE
#   current  prints the Sources/Core/Version.swift value.
#   check    exits 0 when VERSION equals the current value and PRERELEASE is false, or when
#            VERSION is the current value plus -rcN (N is digits with no leading zero) and
#            PRERELEASE is true. Any other pair exits 1 and says why.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

current() {
  sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$ROOT/Sources/Core/Version.swift" | sed -n 1p
}

case "${1:-}" in
  current)
    cur="$(current)"
    [ -n "$cur" ] || { echo "release-version: no version in Sources/Core/Version.swift" >&2; exit 1; }
    printf '%s\n' "$cur"
    ;;
  check)
    version="${2:?release-version: check needs a version}"
    pre="${3:?release-version: check needs true or false}"
    cur="$(current)"
    [ -n "$cur" ] || { echo "release-version: no version in Sources/Core/Version.swift" >&2; exit 1; }
    case "$pre" in
      true)
        rest="${version#"$cur"-rc}"
        if [ "$rest" = "$version" ] || [ -z "$rest" ] || [ "${rest#0}" != "$rest" ]; then
          echo "release-version: a prerelease version must be $cur-rcN, not $version." >&2
          exit 1
        fi
        case "$rest" in *[!0-9]*)
          echo "release-version: a prerelease version must be $cur-rcN, not $version." >&2
          exit 1 ;;
        esac
        ;;
      false)
        if [ "$version" != "$cur" ]; then
          echo "release-version: the version must be $cur, not $version." >&2
          exit 1
        fi
        ;;
      *)
        echo "release-version: the prerelease value must be true or false, not $pre." >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "usage: release-version.sh current | check VERSION PRERELEASE" >&2
    exit 2
    ;;
esac

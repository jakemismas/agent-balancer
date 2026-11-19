#!/usr/bin/env bash
# Builds the release files into build/release/ (or --out): the app zip, the command line tool
# archive, SHA256SUMS and the tap formula filled from packaging/agent-balancer.rb, then checks
# them. The formula's url points at --base-url; with --dry-run that defaults to the output folder
# as a file:// URL, which a local tap installs from.
# --out must be absent, empty, build/release or a folder an earlier run made; anything else is refused.
# Usage: package-release.sh [--dry-run] [--version V] [--base-url URL] [--owner OWNER] [--out DIR]
#   --version  must equal the Version.swift value, or that value plus -rcN.
#   --base-url where the files will be served; required unless --dry-run.
#   --owner    the GitHub owner in the formula's homepage; defaults to the origin remote's owner.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

DRY=0
VERSION_ARG=""
BASE_URL=""
OWNER=""
OUT="$ROOT/build/release"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --version) VERSION_ARG="${2:?--version needs a value}"; shift ;;
    --base-url) BASE_URL="${2:?--base-url needs a value}"; shift ;;
    --owner) OWNER="${2:?--owner needs a value}"; shift ;;
    --out) OUT="${2:?--out needs a value}"; shift ;;
    *) echo "package-release: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "package-release: $1" >&2; exit 1; }

case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
if [ -d "$OUT" ] && [ ! -L "$OUT" ]; then OUT="$(cd "$OUT" && pwd -P)"; fi

CURRENT="$(scripts/release-version.sh current)"
VERSION="${VERSION_ARG:-$CURRENT}"
if [ "$VERSION" = "$CURRENT" ]; then PRE=false; else PRE=true; fi
scripts/release-version.sh check "$VERSION" "$PRE" || exit 1

if [ -z "$OWNER" ]; then
  OWNER="$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]([^/]+)/[^/]+$#\1#' || true)"
fi
case "$OWNER" in
  "" | *[!A-Za-z0-9-]*) die "no GitHub owner: pass --owner" ;;
esac

if [ -z "$BASE_URL" ]; then
  [ "$DRY" -eq 1 ] || die "--base-url is required without --dry-run"
  BASE_URL="file://$OUT"
fi
BASE_URL="${BASE_URL%/}"

CLI_NAME="agent-balancer-$VERSION-arm64"
CLI_ARCHIVE="$CLI_NAME.tar.gz"
APP_ZIP="AgentBalancerBar.zip"

# --out is only replaced when it is absent, empty, or holds only files an earlier run of this script
# made (it carries the marker file). Any other folder, including a home folder, is refused.
MARKER=".package-release-output"
case "$OUT" in
  "" | "/" | "$HOME" | "$HOME/" | "$ROOT" | "$ROOT/") die "refusing --out $OUT" ;;
esac
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  [ -d "$OUT" ] && [ ! -L "$OUT" ] || die "--out $OUT is not a folder"
  if [ -n "$(ls -A "$OUT")" ] && [ ! -f "$OUT/$MARKER" ] && [ "$OUT" != "$ROOT/build/release" ]; then
    die "--out $OUT is not empty and was not made by this script; pass an empty or new folder"
  fi
  if [ -f "$OUT/$MARKER" ] || [ "$OUT" = "$ROOT/build/release" ]; then
    rm -f "$OUT/$CLI_ARCHIVE" "$OUT/$APP_ZIP" "$OUT/SHA256SUMS" "$OUT/agent-balancer.rb"
    rm -f "$OUT"/agent-balancer-*-arm64.tar.gz
  fi
fi
mkdir -p "$OUT"
: > "$OUT/$MARKER"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ab-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

swift build -c release --product agent-balancer
CLI_BIN="$(swift build -c release --product agent-balancer --show-bin-path)/agent-balancer"
[ -x "$CLI_BIN" ] || die "no built binary at $CLI_BIN"

scripts/build-app.sh
APP="build/AgentBalancerBar.app"
[ -d "$APP" ] || die "no app at $APP"

# The command line archive holds one folder, which Homebrew unpacks into its build folder.
mkdir -p "$STAGE/$CLI_NAME/bin" "$STAGE/$CLI_NAME/skill"
cp -f "$CLI_BIN" "$STAGE/$CLI_NAME/bin/agent-balancer"
cp -R skill/agent-balancer "$STAGE/$CLI_NAME/skill/agent-balancer"
tar -czf "$OUT/$CLI_ARCHIVE" -C "$STAGE" "$CLI_NAME"

ditto -c -k --keepParent "$APP" "$OUT/$APP_ZIP"

(cd "$OUT" && shasum -a 256 "$CLI_ARCHIVE" "$APP_ZIP" > SHA256SUMS)
SHA="$(awk -v f="$CLI_ARCHIVE" '$2 == f { print $1 }' "$OUT/SHA256SUMS")"
case "$SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) die "no checksum for $CLI_ARCHIVE" ;;
esac

sed -e "s|@OWNER@|$OWNER|g" \
  -e "s|@URL@|$BASE_URL/$CLI_ARCHIVE|g" \
  -e "s|@VERSION@|$VERSION|g" \
  -e "s|@SHA256@|$SHA|g" \
  packaging/agent-balancer.rb > "$OUT/agent-balancer.rb"

# Checks on what was made.
if grep -q '@[A-Z0-9]*@' "$OUT/agent-balancer.rb"; then die "the formula still holds a placeholder"; fi
if command -v ruby >/dev/null 2>&1; then ruby -c "$OUT/agent-balancer.rb" >/dev/null; fi
# The formula installs the prebuilt tool: no build step and no dependency that needs developer tools.
if grep -nE 'swift|xcode|:build|system "' "$OUT/agent-balancer.rb" | grep -v '^[0-9]*: *#' | grep . >/dev/null; then
  die "the formula builds from source or needs developer tools"
fi

listing="$(tar -tzf "$OUT/$CLI_ARCHIVE")"
for want in "$CLI_NAME/bin/agent-balancer" "$CLI_NAME/skill/agent-balancer/SKILL.md"; do
  grep -qx "$want" <<<"$listing" || die "$CLI_ARCHIVE lacks $want"
done

CHECK="$STAGE/check"
mkdir -p "$CHECK/cli" "$CHECK/app"
tar -xzf "$OUT/$CLI_ARCHIVE" -C "$CHECK/cli"
# The tool runs from the archive and reports the release's base version (a -rc build reports the
# Version.swift value).
got="$("$CHECK/cli/$CLI_NAME/bin/agent-balancer" --version)"
case "$got" in *"$CURRENT"*) ;; *) die "the packaged tool reports '$got', not $CURRENT" ;; esac

ditto -x -k "$OUT/$APP_ZIP" "$CHECK/app"
[ -d "$CHECK/app/AgentBalancerBar.app" ] || die "$APP_ZIP does not hold AgentBalancerBar.app"
codesign --verify "$CHECK/app/AgentBalancerBar.app"
sig="$(codesign -dv "$CHECK/app/AgentBalancerBar.app" 2>&1 || true)"
case "$sig" in *"Signature=adhoc"*) ;; *) die "the app is not ad hoc signed" ;; esac
min="$(plutil -extract LSMinimumSystemVersion raw "$CHECK/app/AgentBalancerBar.app/Contents/Info.plist")"
[ "$min" = "14.0" ] || die "the app's minimum system version is $min, not 14.0"

# The tool links only system libraries, so a Mac with no developer tools runs it.
if otool -L "$CHECK/cli/$CLI_NAME/bin/agent-balancer" | tail -n +2 | awk '{ print $1 }' \
  | grep -vE '^(/usr/lib/|/System/Library/)' | grep . >/dev/null; then
  die "the packaged tool links a library outside /usr/lib and /System/Library"
fi

echo "package-release: $VERSION"
echo "  $OUT/$CLI_ARCHIVE"
echo "  $OUT/$APP_ZIP"
echo "  $OUT/SHA256SUMS"
echo "  $OUT/agent-balancer.rb (url $BASE_URL/$CLI_ARCHIVE)"
echo "package-release: checksums (SHA-256)"
sed 's/^/  /' "$OUT/SHA256SUMS"
echo "package-release: formula sha256 $SHA"
if [ "$DRY" -eq 1 ]; then echo "package-release: dry run, nothing published"; fi

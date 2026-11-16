#!/usr/bin/env bash
# Checks that the README's quick start, docs/RELEASING.md, the release workflow and the formula
# template agree with what scripts/package-release.sh makes: the formula name, the tap, the artifact
# names, the attestation line and the skill path.
# Usage: check-release.sh [root]
set -euo pipefail
# Under pipefail, a pipe into grep -q or head fails when its writer is cut off, so none is used.

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$ROOT"

fail=0
bad() { echo "FAIL release: $1" >&2; fail=1; }
has() { grep -qF -- "$2" "$1" || bad "$1 lacks: $2"; }

PKG=scripts/package-release.sh
FORMULA=packaging/agent-balancer.rb
WORKFLOW=.github/workflows/release.yml
README=README.md
DOC=docs/RELEASING.md
for f in "$PKG" "$FORMULA" "$WORKFLOW" "$README" "$DOC"; do
  [ -f "$f" ] || { echo "FAIL release: missing $f" >&2; exit 1; }
done

# Names the packaging script makes.
APP_ZIP="$(sed -n 's/^APP_ZIP="\(.*\)"$/\1/p' "$PKG" | sed -n 1p)"
CLI_TEMPLATE="$(sed -n 's/^CLI_NAME="\(.*\)"$/\1/p' "$PKG" | sed -n 1p)"
[ -n "$APP_ZIP" ] || bad "no APP_ZIP in $PKG"
[ -n "$CLI_TEMPLATE" ] || bad "no CLI_NAME in $PKG"
APP_BUNDLE="${APP_ZIP%.zip}.app"
CLI_GLOB="${CLI_TEMPLATE//\$VERSION/*}.tar.gz"

# The formula's name is its file name, and its class must be that name in camel case.
NAME="$(basename "$FORMULA" .rb)"
CLASS="$(printf '%s' "$NAME" | awk -F- '{ for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i,1,1)), substr($i,2) }')"
grep -qE "^class $CLASS < Formula$" "$FORMULA" || bad "$FORMULA does not define class $CLASS"
has "$PKG" 'agent-balancer.rb'
case "$NAME" in agent-balancer) ;; *) bad "the formula is $NAME, not agent-balancer" ;; esac

# README: the tap, formula name, artifact names and attestation line, in the quick start. The
# commands name the real owner, so they work when copied.
OWNER=jakemismas
install="$(awk '/^## Quick start$/ { on = 1; next } on && /^## / { exit } on { print }' "$README")"
[ -n "$install" ] || bad "README has no Quick start section"
grep -qE "^ +brew install $OWNER/tap/$NAME\$" <<<"$install" \
  || bad "the README quick start does not run: brew install $OWNER/tap/$NAME"
grep -qF "\`$APP_ZIP\`" <<<"$install" || bad "the README quick start does not name $APP_ZIP"
grep -qF "\`$APP_BUNDLE\`" <<<"$install" || bad "the README quick start does not name $APP_BUNDLE"
grep -qE "^ +gh attestation verify $APP_ZIP --repo $OWNER/agent-balancer\$" <<<"$install" \
  || bad "the README attestation line is not: gh attestation verify $APP_ZIP --repo $OWNER/agent-balancer"
grep -qF "brew upgrade $NAME" "$README" || bad "the README does not name brew upgrade $NAME"
grep -qF "brew uninstall $NAME" "$README" || bad "the README does not name brew uninstall $NAME"

# The repository the attestation names is the formula's homepage repository.
grep -qE '^  homepage "https://github.com/@OWNER@/agent-balancer"$' "$FORMULA" \
  || bad "the formula homepage is not https://github.com/@OWNER@/agent-balancer"

# The workflow attests the files the README verifies and publishes the files the formula needs.
has "$WORKFLOW" "build/release/$APP_ZIP"
has "$WORKFLOW" "build/release/$CLI_GLOB"
has "$WORKFLOW" 'build/release/SHA256SUMS'
has "$WORKFLOW" 'build/release/agent-balancer.rb'
has "$WORKFLOW" 'actions/attest-build-provenance@'
has "$WORKFLOW" 'attestations: write'
has "$WORKFLOW" 'id-token: write'
has "$WORKFLOW" 'scripts/release-version.sh check'
has "$WORKFLOW" 'scripts/release-notes.sh'

# Release trust: read-only by default, write only in the release job, no tokens or secrets,
# every action pinned by SHA, and only a commit on main can release.
has "$WORKFLOW" "if: github.ref == 'refs/heads/main'"
has "$WORKFLOW" 'git merge-base --is-ancestor "$SHA" origin/main'
grep -qE '^permissions:$' "$WORKFLOW" && [ "$(awk '/^permissions:$/ { getline; print; exit }' "$WORKFLOW")" = "  contents: read" ] \
  || bad "$WORKFLOW lacks top-level permissions: contents: read"
[ "$(grep -c '^permissions:' "$WORKFLOW")" -eq 1 ] || bad "$WORKFLOW must have exactly one top-level permissions block"
[ "$(grep -c 'contents: write' "$WORKFLOW")" -eq 1 ] || bad "$WORKFLOW must grant contents: write exactly once, in the release job"
for wf in .github/workflows/*.yml; do
  if grep -nE 'secrets\.|PERSONAL|(^|[^A-Za-z])PAT([^A-Za-z]|$)|TAP_TOKEN|HOMEBREW_TAP|\bpull_request_target\b' "$wf" >/dev/null; then
    bad "$wf references a secret, a personal token, a tap token or pull_request_target"
  fi
  uses="$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$wf" || true)"
  if [ -n "$uses" ] && grep -vqE 'uses: [^@ ]+@[0-9a-f]{40}( |$)' <<<"$uses"; then
    bad "$wf has an action not pinned by a 40-character SHA"
  fi
  if grep -E '^[[:space:]]*(write-all|.*: write)' "$wf" >/dev/null && [ "$wf" != "$WORKFLOW" ]; then
    bad "$wf grants write permissions"
  fi
done

# The skill path the README links is the path the formula installs.
has "$FORMULA" 'share/"agent-balancer/skill"'
has "$README" 'share/agent-balancer/skill/agent-balancer'

# The release page names the files and the commands it tells a person to run.
for want in "$APP_ZIP" "${CLI_TEMPLATE//\$VERSION/<version>}.tar.gz" 'SHA256SUMS' "$NAME.rb" 'scripts/package-release.sh --dry-run' \
  'scripts/release-version.sh' "brew install local/ab/$NAME" "brew trust --formula local/ab/$NAME"; do
  has "$DOC" "$want"
done

# CI installs the formula the script writes.
has .github/workflows/ci.yml 'build/release/agent-balancer.rb'
has .github/workflows/ci.yml "brew install local/ab/$NAME"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "check-release: ok"

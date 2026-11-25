#!/usr/bin/env bash
# Checks that the README's quick start, docs/RELEASING.md, the release workflow and the formula
# template agree with what scripts/package-release.sh makes: the formula name, the tap and the
# line that trusts the formula, the artifact names, the attestation line and the skill path.
# It also checks, as docs/RELEASING.md says, that the release workflow creates the tag: its Publish
# step has no if: and runs gh release create "v$VERSION" with --target "$SHA"; the Check the inputs
# step and the Publish step, before gh release create, hold the tag check that stops a run when the
# tag already exists on origin at another commit; no line passes --verify-tag or runs git push;
# and no other line names the tag (v$VERSION, v${VERSION} or v${{ inputs.version }}), refs/tags,
# ls-remote or the tag check's variables. It reads the workflow's text only, so a step that
# reaches the tag without naming it in one of these ways, such as a script the workflow runs, is
# not seen.
# It also checks that CI keeps its jobs' time limits and its concurrency group, with no job-level
# group and no other workflow named ci.
# Usage: check-release.sh [root]
set -euo pipefail
# Under pipefail, a pipe into grep -q or head fails when its writer is cut off, so none is used.

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$ROOT"

fail=0
bad() { echo "FAIL release: $1" >&2; fail=1; }
has() { grep -qF -- "$2" "$1" || bad "$1 lacks: $2"; }
# Prints the lines nested under the first input line equal to $1, skipping blanks and comments.
block() {
  awk -v want="$1" '
    !on { if ($0 == want) { on = 1; match($0, /[^ ]/); top = RSTART - 1 }; next }
    /^[[:space:]]*(#|$)/ { next }
    { match($0, /[^ ]/); if (RSTART - 1 <= top) exit; print }
  '
}
# Prints each job of the jobs block on stdin that sets the job-level key $1, at any indentation.
jobs_setting() {
  awk -v key="$1" '
    { match($0, /[^ ]/); d = RSTART - 1; text = substr($0, RSTART) }
    NR == 1 || d <= top { top = d; job = text; sub(/:.*/, "", job); child = -1; next }
    child < 0 { child = d }
    d == child && (text == key ":" || index(text, key ": ") == 1) { print job }
  '
}
# Prints the first line of $1 that the lines on stdin do not hold in that order, each line read
# with the spaces at its ends taken off; prints nothing when they hold them all.
first_missing() {
  WANT="$1" awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    BEGIN {
      n = split(ENVIRON["WANT"], want, "\n")
      while (n > 0 && trim(want[n]) == "") n--
      i = 1
    }
    i <= n && trim($0) == trim(want[i]) { i++ }
    END { if (i <= n) print trim(want[i]) }
  '
}
# Prints "<line number>: <words>" for each line of the file $1, other than a comment, a line of $2
# and a line that starts gh release create "v$VERSION", that holds a match of the extended regex
# $3; the words are the matches, never the whole line.
stray_lines() {
  ALLOWED="$2" WORDS="$3" awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    BEGIN { n = split(ENVIRON["ALLOWED"], a, "\n"); for (i = 1; i <= n; i++) ok[trim(a[i])] = 1 }
    {
      t = trim($0)
      if (t ~ /^#/ || (t in ok) || index(t, "gh release create \"v$VERSION\" ") == 1) next
      rest = t; found = ""
      while (match(rest, ENVIRON["WORDS"])) {
        found = found (found == "" ? "" : ", ") substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (found != "") print NR ": " found
    }
  ' "$1"
}

PKG=scripts/package-release.sh
FORMULA=packaging/agent-balancer.rb
WORKFLOW=.github/workflows/release.yml
CI_WORKFLOW=.github/workflows/ci.yml
README=README.md
DOC=docs/RELEASING.md
for f in "$PKG" "$FORMULA" "$WORKFLOW" "$CI_WORKFLOW" "$README" "$DOC"; do
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
grep -qE "^class $CLASS < Formula$" "$FORMULA" \
  || bad "$FORMULA lacks the line: class $CLASS < Formula"
has "$PKG" 'agent-balancer.rb'
case "$NAME" in agent-balancer) ;; *) bad "the formula is $NAME, not agent-balancer" ;; esac

# README: the tap, formula name, artifact names and attestation line, in the quick start. The
# commands name the real owner, so they work when copied.
OWNER=jakemismas
install="$(awk '/^## Quick start$/ { on = 1; next } on && /^## / { exit } on { print }' "$README")"
[ -n "$install" ] || bad "README has no Quick start section"
grep -qE "^ +brew install $OWNER/tap/$NAME\$" <<<"$install" \
  || bad "the README quick start does not run: brew install $OWNER/tap/$NAME"
# Homebrew 7 refuses an untrusted tap's formula, so the quick start taps and trusts the one formula.
grep -qE "^ +brew tap $OWNER/tap\$" <<<"$install" \
  || bad "the README quick start does not run: brew tap $OWNER/tap"
grep -qE "^ +brew trust --formula $OWNER/tap/$NAME\$" <<<"$install" \
  || bad "the README quick start does not run: brew trust --formula $OWNER/tap/$NAME"
grep -qF "\`$APP_ZIP\`" <<<"$install" \
  || bad "the README quick start does not name \`$APP_ZIP\`"
grep -qF "\`$APP_BUNDLE\`" <<<"$install" \
  || bad "the README quick start does not name \`$APP_BUNDLE\`"
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
# Each refusal names the text it refused.
SECRET_WORDS='secrets\.|PERSONAL|(^|[^A-Za-z])PAT([^A-Za-z]|$)|TAP_TOKEN|HOMEBREW_TAP|\bpull_request_target\b'
for wf in .github/workflows/*.yml; do
  while IFS= read -r hit; do
    [ -z "$hit" ] || bad "$wf references a secret, a personal token, a tap token or pull_request_target on line ${hit%%:*}: ${hit#*:}"
  done <<<"$(grep -noE "$SECRET_WORDS" "$wf" || true)"
  uses="$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$wf" || true)"
  while IFS= read -r line; do
    [ -z "$line" ] || bad "$wf has an action not pinned by a 40-character SHA: ${line#*uses: }"
  done <<<"$(grep -vE 'uses: [^@ ]+@[0-9a-f]{40}( |$)' <<<"$uses" || true)"
  if [ "$wf" != "$WORKFLOW" ]; then
    while IFS= read -r hit; do
      [ -z "$hit" ] || bad "$wf grants write permissions on line ${hit%%:*}: $(sed -E 's/^ +//' <<<"${hit#*:}")"
    done <<<"$(grep -noE '^[[:space:]]*(write-all|.*: write)' "$wf" || true)"
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

# The release page leaves tag creation open because the workflow creates the tag itself.
has "$WORKFLOW" 'gh release create "v$VERSION"'
has "$DOC" 'gh release create'

# gh release create keeps a tag that already exists, whatever commit it names, so the workflow
# runs this check before it packages anything and again just before it publishes. Each line is
# compared with the spaces at its ends taken off.
IFS= read -r -d '' TAG_CHECK <<'EOF' || true
if ! tag_refs="$(git ls-remote --tags origin "refs/tags/v$VERSION" "refs/tags/v$VERSION^{}")"; then
  echo "Could not list the tags on origin." >&2
  exit 1
fi
tag_commit="$(awk -v ref="refs/tags/v$VERSION" '$2 == ref { tag = $1 } $2 == ref "^{}" { peeled = $1 } END { print (peeled != "" ? peeled : tag) }' <<<"$tag_refs")"
if [ -n "$tag_commit" ] && [ "$tag_commit" != "$SHA" ]; then
  echo "Tag v$VERSION already exists on origin at $tag_commit, not at $SHA, the commit this run builds." >&2
  exit 1
fi
EOF
inputs_step="$(block '      - name: Check the inputs' <"$WORKFLOW")"
publish_step="$(block '      - name: Publish' <"$WORKFLOW")"
before_create="$(awk 'index($0, "gh release create \"v$VERSION\" ") { exit } { print }' \
  <<<"$publish_step")"
missing="$(first_missing "$TAG_CHECK" <<<"$inputs_step")"
[ -z "$missing" ] || bad "the Check the inputs step of $WORKFLOW lacks the tag check line: $missing"
missing="$(first_missing "$TAG_CHECK" <<<"$before_create")"
[ -z "$missing" ] \
  || bad "the Publish step of $WORKFLOW lacks, before gh release create, the tag check line: $missing"
grep -qF 'gh release create "v$VERSION" ' <<<"$publish_step" \
  || bad "the Publish step of $WORKFLOW does not run: gh release create \"v\$VERSION\""
grep -qF -- '--target "$SHA"' <<<"$publish_step" \
  || bad "the Publish step of $WORKFLOW does not pass: --target \"\$SHA\""
# An if: key, quoted or not, may keep the step from running.
Q="'"
while IFS= read -r cond; do
  [ -z "$cond" ] \
    || bad "the Publish step of $WORKFLOW runs only on a condition: $(sed -E 's/^ +//' <<<"$cond")"
done <<<"$(grep -E "^[[:space:]]*[\"$Q]?if[\"$Q]?[[:space:]]*:" <<<"$publish_step" || true)"
while IFS=: read -r n _; do
  [ -z "$n" ] \
    || bad "$WORKFLOW passes --verify-tag on line $n, so gh release create would not make the tag"
done <<<"$(grep -nF -- '--verify-tag' "$WORKFLOW" || true)"
while IFS=: read -r n _; do
  [ -z "$n" ] || bad "$WORKFLOW runs git push on line $n; only gh release create may make the tag"
done <<<"$(grep -nE '\bgit\b.*\bpush\b' "$WORKFLOW" || true)"
# Every other line that names the tag is one of these, so a check that stops unless the tag is
# already on origin fails here.
KNOWN_TAG_LINES='if gh release view "v$VERSION" >/dev/null 2>&1; then
echo "Release v$VERSION already exists." >&2
--base-url "https://github.com/$REPO/releases/download/v$VERSION"'
TAG_WORDS='v\$\{?VERSION|v\$\{\{ *(github\.event\.)?inputs\.version|refs?/tags|ls-remote'
TAG_WORDS="$TAG_WORDS|tag_(refs|commit)"
while IFS= read -r hit; do
  [ -z "$hit" ] || bad "$WORKFLOW names the tag outside the checks this script knows, on line $hit"
done <<<"$(stray_lines "$WORKFLOW" "$TAG_CHECK$KNOWN_TAG_LINES" "$TAG_WORDS")"

# CI installs the formula the script writes.
has "$CI_WORKFLOW" 'build/release/agent-balancer.rb'
has "$CI_WORKFLOW" "brew install local/ab/$NAME"

# Without a limit a stalled job runs to GitHub's 360-minute default; from 360 up is no limit.
ci_jobs="$(block 'jobs:' <"$CI_WORKFLOW")"
check_job="$(block '  check:' <<<"$ci_jobs")"
install_job="$(block '  install:' <<<"$ci_jobs")"
[ "$(sed -n 's/^    timeout-minutes: //p' <<<"$check_job")" = 20 ] \
  || bad "$CI_WORKFLOW must give its check job the line timeout-minutes: 20, unquoted with no comment"
case "$(sed -n 's/^    timeout-minutes: //p' <<<"$install_job")" in
  [1-9] | [1-9][0-9] | [12][0-9][0-9] | 3[0-5][0-9]) ;;
  *) bad "$CI_WORKFLOW must give its install job a line timeout-minutes: N, N from 1 to 359, unquoted with no comment" ;;
esac

# Pinned whole: without its run id fallback, runs started with Run workflow would share a group.
CI_GROUP='${{ github.workflow }}-${{ github.event_name }}-${{ github.event.pull_request.number || github.run_id }}'
# Only a first attempt may cancel, so a re-run never stops the run in progress.
CI_CANCEL="\${{ github.run_attempt == '1' }}"
ci_concurrency="$(block 'concurrency:' <"$CI_WORKFLOW")"
grep -qxF "  group: $CI_GROUP" <<<"$ci_concurrency" \
  || bad "$CI_WORKFLOW must have the top-level concurrency line group: $CI_GROUP"
grep -qxF "  cancel-in-progress: $CI_CANCEL" <<<"$ci_concurrency" \
  || bad "$CI_WORKFLOW must have the top-level concurrency line cancel-in-progress: $CI_CANCEL"

# A job-level group, or another workflow named ci in any case, lets other runs stall or cancel CI's.
while IFS= read -r job; do
  [ -z "$job" ] || bad "$CI_WORKFLOW must not set concurrency in its $job job"
done <<<"$(jobs_setting concurrency <<<"$ci_jobs")"
[ "$(sed -n 's/^name: //p' "$CI_WORKFLOW")" = ci ] \
  || bad "$CI_WORKFLOW must have the top-level line name: ci"
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] && [ "$wf" != "$CI_WORKFLOW" ] || continue
  if grep -E "^name:[[:space:]]*([Cc][Ii]|\"[Cc][Ii]\"|'[Cc][Ii]')([[:space:]]+#.*)?[[:space:]]*\$" "$wf" >/dev/null; then
    bad "$wf must not be named ci: its runs would share CI's concurrency groups"
  fi
done

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "check-release: ok"

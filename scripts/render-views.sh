#!/usr/bin/env bash
# Draws each menu view with ImageRenderer at 2x, light and dark, into build/renders/. The panel
# material is swapped for the flat token colors of design/render.html, so compare layout, tokens,
# text and meter widths with design/screenshots/. Vibrancy and the real popover are checked only
# in the manual smoke. Then it copies the README pictures this run drew into docs/media/ and runs
# the README check.
set -euo pipefail

# The real path: the app refuses an output path that names a link, and a checkout opened through
# one would give it one.
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

# The README check needs the CLI as well as the app, so a fresh clone builds both.
swift build --product AgentBalancerBar
swift build --product agent-balancer
BIN="$(swift build --product AgentBalancerBar --show-bin-path)/AgentBalancerBar"
CLI="$(swift build --product agent-balancer --show-bin-path)/agent-balancer"

# The README pictures, as the render names them. An older render of one is deleted first, so a
# scene that no longer renders fails the copy instead of publishing a picture from an earlier run.
PICTURES="menu-light menu-dark manage-tokens-light manage-tokens-dark manage-folders-light manage-folders-dark"
for name in $PICTURES; do rm -f "build/renders/readme-$name.png"; done

mkdir -p build
"$BIN" --render "$ROOT/build/renders"
ls build/renders

mkdir -p docs/media
for name in $PICTURES; do
  [ -f "build/renders/readme-$name.png" ] || { echo "render-views: missing build/renders/readme-$name.png" >&2; exit 1; }
done
for name in $PICTURES; do cp "build/renders/readme-$name.png" "docs/media/$name.png"; done
scripts/check-readme.sh "$CLI"

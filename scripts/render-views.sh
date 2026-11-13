#!/usr/bin/env bash
# Draws each menu view with ImageRenderer at 2x, light and dark, into build/renders/. The panel
# material is swapped for the flat token colors of design/render.html, so compare layout, tokens,
# text and meter widths with design/screenshots/. Vibrancy and the real popover are checked only
# in the manual smoke.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product AgentBalancerBar
BIN="$(swift build --product AgentBalancerBar --show-bin-path)/AgentBalancerBar"

mkdir -p build
"$BIN" --render "$ROOT/build/renders"
ls build/renders

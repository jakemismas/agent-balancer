#!/usr/bin/env bash
# The project gate: typecheck, lint, tests, safety scan, secret scan. Any failing step fails the run.
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n== %s ==\n' "$1"; }

# With only the Command Line Tools selected, building the tests fails now and then with
# "plugin for module 'TestingMacros' not found". Pointing the compiler at the plugin folder fixes
# it. An Xcode-selected Mac and CI never get the flag.
BUILD_FLAGS=()
CLT="/Library/Developer/CommandLineTools"
if [ "$(xcode-select -p 2>/dev/null || true)" = "$CLT" ]; then
  BUILD_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
fi

step "typecheck"
swift build --build-tests ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}

step "lint"
swift format lint --strict --recursive Package.swift Sources Tests

step "tests"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ab-check-home.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT
# --skip-build: the build above already carried the flag, and a rebuild here would drop it.
export HOME="$TEST_HOME"
swift test --skip-build

step "safety"
scripts/check-safety.sh

step "secrets"
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks is required and was not found on PATH" >&2
  exit 1
fi
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  gitleaks git --no-banner --redact
fi
gitleaks dir . --no-banner --redact

printf '\ncheck: all steps passed\n'

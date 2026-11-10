# Changelog

## Unreleased

- Add the Swift package with the `Core` library and the `agent-balancer` command, which prints its
  version.
- Add `scripts/check.sh` (typecheck, format lint, tests, safety scan, secret scan) and
  `scripts/check-safety.sh`.
- Add the leak-test harness and the safety script tests.
- Add CI on `macos-26`, Dependabot for GitHub Actions and Swift, and the gitleaks configuration.
- Add `docs/ARCHITECTURE.md`, README, LICENSE and SECURITY.
- Add `init`, `doctor`, `config` (`show`, `validate`, `set-main`, `clear-main`, `set`) and
  `link --accept-source-change`. They keep the account registry for the login account in
  `~/.agent-balancer/`, read login state with `claude auth status`, and record the default
  folder's hook fingerprint.
- Add the safe `claude` runner (fixed search list, ownership checks, allowlisted child
  environment, timeout, output cap) and the scrubber for captured output.
- Add the no-follow reader and writer, the fake `claude` and recorded auth fixtures for tests.

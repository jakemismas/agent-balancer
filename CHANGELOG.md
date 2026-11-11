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
- Add `refresh [--label <label>] [--force]`: a one-turn probe per `login` and `token` account that
  stores each reading (percent from 0 to 100, source `probe`) under `~/.agent-balancer/state/`,
  with a lock per account, a fresh probe folder per probe and a Fable probe at most once a day.
  Add the `fable` and `picker.maxReadingAgeMinutes` settings, stream fixtures for the probe and
  the token file path builder.
- Bound a probe's reset time to its window (5 hours, 7 days or 31 days from the probe, with
  5 minutes of slack) and fail the reading when it is outside that range. Bound dates read from
  `auth status`, let a stored far-future reset be replaced by the next valid reading, and keep one
  bad stored value from erasing an account's reading. Record the measured cost and time of the
  Fable probe check as the source of the `fable.probeBudgetUsd` and `fable.probeTimeoutSeconds`
  defaults.
- Add `pick [--model <name>] [--settings <json>] [--full-login] [--caller typed|launcher]
  [--exclude <label>] [--dry-run] [--json]`: refreshes stale readings within
  `picker.deadlineSeconds`, then under the pick lock picks the account, writes a launch file
  (mode 0600, holding the token for a token account) and a lease, and logs one line. It answers
  with the launch recipe for a typed line or a launcher, and exits 2 when no account is eligible.
  A recipe that cannot be typed safely is refused before any file or lease is written.
- Add `status [--json]`, `events [--json]` and `history [--json]`. A status rebuild under
  `locks/history.lock` writes `state/status.json`, the numbered events record
  (`state/events.jsonl`) and a per-account readings history, and keeps `state/current.json`
  unchanged when the events cannot be saved so the transitions are detected again. Add in-use
  session counts from live session records and launch file upkeep. `pick` never reads the events
  record or `current.json`.

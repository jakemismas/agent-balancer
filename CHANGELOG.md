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
- Add token accounts: `add <label>` (kind `token`, optional `--email`, `--ends` and
  `--ending-soon`), `login <label>` (runs `claude setup-token` and keeps the token without showing
  it, or reads a pasted token from input) and `remove <label>`. A token lives in
  `tokens/<label>.json`, written by one atomic rename. A replace rewrites the label's launch files
  under the pick lock, and `remove` overwrites a launch file that a session still names with no
  token. Both print that the old token may keep working until its year ends; whether a new token
  ends the old one is not yet known.
- Estimate a token's end as 365 days after it was saved, show it as `loginExpiresAt` with source
  `estimate`, and warn with `login_expiring` 14 days before, once per expiry date. Warn with
  `possible_duplicate` when two accounts share both reset times, checked after every probe of a
  token account.
- Refuse an `--ends` date that is not a real day, and refuse a past date in `add` and
  `config set ends`.
- `remove` keeps a launch file that a session names or that a recent pick returned as a tombstone
  whose token variable is `invalid`, reads every remaining launch file back before it deletes the
  token file, deletes the writer's leftover temporary files, and finishes on a rerun even when the
  account entry is gone. `doctor` lists a token file that has no account. A replace never revives
  a tombstone and never leaves the old token in a launch file that does not parse.
- `pick` skips a token account whose token file does not parse, also with `--dry-run`, and
  `refresh` never probes one. A token file that is missing, not private or does not parse shows
  `token_missing` with one text, "No token saved. Run `agent-balancer login <label>` in Terminal.",
  also after a `refresh`.
- `remove`, a token replace and launch file upkeep delete the temporary files a write killed
  before its rename leaves in `tokens/` and the launch folders, and `doctor` counts any that are
  left. `login` writes no token file once a `remove` has dropped the account, `add` refuses a label
  whose token file outlived its account, and `login --paste` refuses to read when the terminal
  cannot hide the input.
- `config set <label> label <new>` refuses on a token account and writes nothing.
- Add `run <label> [--print-command] [-- <claude arguments>]`: starts Claude Code on one account
  with a lease and one launch file, the checks of `pick` without the reading check, the terminal
  attached and the person's environment minus the protected group. `--settings <launch file>` comes
  before the person's arguments; a `--settings` of their own and a first argument that is a
  `claude` command name are refused before anything is written. `run` never opens the default
  folder's settings file: `init`, `doctor`, `pick`, `verify` and `link --accept-source-change` save a
  verdict with the file's stamp, and `run` refuses when it is missing or older than the file.
  `--print-command` prints the launch line and applies the ambient and inherited token or key rules
  as a typed `pick` does. A chat shell gets the line to type in your own terminal and exit 1, with
  or without `--print-command`, and nothing is written.
- Saving the hook record refuses when `links.json` cannot be decoded, so the link list is never
  dropped.
- Add `uninstall`: lists the tool's files as counts, then removes them after the typed word. A
  launch file that a session record names, an open lease holds or that is younger than the lease
  window is overwritten with a token-free tombstone and kept. Listed links go only while they are
  still the symlink the tool made.
- Extend `doctor` with the launch file count, the age of the oldest and a warning for a data
  folder in a synced location.
- Add `skill/agent-balancer/SKILL.md` and `docs/CONTRACT.md`, the public contract for callers.

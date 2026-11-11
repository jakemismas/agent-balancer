# Architecture

This document is the binding, living design of agent-balancer. A change to a contract below
updates this file in the same change. Section numbers and titles are stable because other
documents and issues cite them.

## Build settings

The toolchain settings every slice builds with:

- `swift-tools-version` 6.2 in `Package.swift`. Version 6.1 rejects the manifest.
- Warnings are errors for this package's own targets only, set per target with
  `swiftSettings: [.treatAllWarnings(as: .error)]`. Dependencies never get the setting. The
  package uses no `unsafeFlags`.
- Tests use Swift Testing (`import Testing`), never XCTest. A Mac with only the Command Line Tools
  ships `Testing.framework` and no `XCTest.framework`. `scripts/check-safety.sh` fails on
  `import XCTest`.
- arm64 only in v1.0. Release builds come from the CI runner.
- The one dependency is swift-argument-parser, pinned to an exact version.
- CI runs on `macos-26` and prints `swift --version` first, so the runner's Swift is on record.

On a Mac that has only the Command Line Tools, `swift build --build-tests` fails now and then with
`plugin for module 'TestingMacros' not found`. The compiler does not search the folder that holds
the plugin. `scripts/check.sh` therefore passes
`-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
to every command that builds the tests. It does this only when `xcode-select -p` prints
`/Library/Developer/CommandLineTools`, so CI and an Xcode-selected Mac never get the flag. It then
runs the tests with `swift test --skip-build`, so they are not rebuilt without the flag.

## Binding design rules

These rules hold in every slice. Breaking one is a critical defect.

1. The only credential the code touches is a token account's setup-token. It lives only in
   `tokens/<label>.json` and that label's launch files (mode 0600). Only the `Tokens` and `Launch`
   modules read it. Other modules reach `tokens/` and `launch/` through calls those two offer. The
   token is never printed, logged, passed as an argument or put in an environment the tool builds.
2. No Keychain or Security framework API. No read of `.credentials.json` or `.claude.json`.
3. The settings file of the default folder is read only by `init`, `doctor`, `pick`, `verify` and
   `link --accept-source-change`, through the hook record, and only for hook entries, the
   `disableAllHooks` flag, whether `apiKeyHelper` is present, and the names (never values) of `env`
   keys.
4. No network code: no `URLSession`, no Network framework, no socket API. No child process other
   than `claude` and the tool itself. The only `http` literal in `Sources/` is the usage-page URL
   constant.
5. Tool data lives outside `~/.claude`. The tool writes only under `~/.agent-balancer/` and to
   links the user approved. It never writes inside `~/.claude` and never sets `CLAUDE_CONFIG_DIR`
   to the default path.
6. Every CLI output, log line and written file passes the leak test: a token appears only in its
   token file and that label's launch files; an email only in `config.json`, status output and the
   app; a session name only in status output; no organization id anywhere; nothing personal in
   events, history, logs or `picks.log`.
7. No shell execution. Every child process runs through `Process` with an argument array, and
   `Process` appears only in the `Runner` module.
8. Child processes get one of the two environments of section 6.2. Keys, tokens and an ambient
   `CLAUDE_CONFIG_DIR` never pass through. A token reaches `claude` only as the path of a
   `--settings` file.
9. No executable path is read from config or any file in the data folder.
10. Every write and delete goes through the no-follow `Paths` writer. The tool never follows a
    symlink it did not make and deletes only files it made.
11. Every recipe carries exactly one `--settings <launch file>`. A caller's settings pass the
    allowlist of 4A.2 or the pick exits 1 and writes nothing.
12. `pick` fails closed per kind (4A.5) and applies the ambient rule (4A.3).
13. No personal email address appears in the repository. Tests, fixtures, docs and mocks use
    `example.com`.

`scripts/check-safety.sh` scans `Sources/` for rules 1, 2, 4, 7, 9 and 10 as text, and scans
`Sources/`, `Tests/`, `docs/` and `skill/` for emails and organization ids. Rules 3, 5, 6, 8, 11
and 12 are behavior, and tests cover them.

## 4. Architecture and module map

One Swift package with three products and no network code of its own:

```
agent-balancer/
  Package.swift
  Sources/
    Core/                    library, no UI
      Models/      Account, Window, Reading, AccountStatus, StatusFile, PickResult, Config
      Config/      load, validate, migrate (schemaVersion), defaults
      Paths/       data folder, account folders, 0700 and 0600 enforcement, no-follow writer (NoFollowWriter.swift, the only file the safety scan lets write or delete)
      Runner/      Process with an argument array (never a shell), timeout, output size cap,
                   scrubber on every captured byte. `ClaudeRunner.runSetupToken` runs
                   `claude setup-token` with the person's environment and hands the raw output
                   once to a callback of the `Tokens` module before it scrubs the remainder
      Readers/     auth status reader, probe reader (stream-json parser), sessions reader
                   (`SessionsReader`: the default folder's `sessions/` and `jobs/` records, section 8)
      Readings/    reading cache (state/readings/<label>.json), the merge rule of 6.3, and the
                   refresher that runs probes under a lock per account
      Env/         the one shared group of protected environment names (6.2)
      Picker/      pure function: (config, readings, now, model) -> PickResult
      Accounts/    AccountKind (login, token, folder): each kind's checks, probe context and
                   recipe parts; the only place that branches on kind
      Launch/      launch files: caller settings allowlist, merge, lease, upkeep (`Upkeep`, 4A.6)
      Status/      `StatusBuilder`: merges readings, sign-in checks and in-use sessions into the
                   status document and rebuilds `state/status.json` (sections 10.1 and 13)
      Tokens/      the token file: `TokenStore` (read, save, delete), `TokenCapture` (the capture and
                   the shape check), `TokenAccounts` (install, replace and remove under the pick
                   lock, with the launch files rewritten or deleted through `Launch`)
      History/     append-only readings history (`ReadingHistory`), state-change events
                   (`EventLog`), the rule that turns a change of state into one event
                   (`Transitions`), and the `events` and `history` answers (`Queries`)
      Scrub/       token-like string redaction used by Runner and the logger
    agent-balancer/          CLI (swift-argument-parser)
      Commands/    one file per command: Init, Doctor, Config, Link, Refresh, Pick, Status, Events,
                   History, Add, Login, Remove, and the `Shared` helper that ends a writing command with the status
                   rebuild
    AgentBalancerBar/        SwiftUI MenuBarExtra app (window style, LSUIElement)
  skill/agent-balancer/SKILL.md   the skill file for a user's Claude (4A.7)
  Tests/
    CoreTests/               picker tables, parsers, scrubber, config validation
    CLITests/                end to end with a fake `claude` under a temporary HOME; leak tests
    Fixtures/                recorded auth and probe outputs (no real tokens)
```

Access rules that follow from the module map: every read and write of a file goes through the
`Paths` module (`NoFollowReader.swift` and `NoFollowWriter.swift`), which `HookRecord`,
`ConfigStore` and the readers call; the environment is read only in `Env/` (`Env.swift` and
`ProtectedEnv.swift`); `Process` appears only in `Runner/`. The Claude Code token variable name in
`ProtectedEnv.swift` is joined from two halves so the text scan, which keeps that name inside the
`Tokens` module, still passes over this one shared list.

Build notes: run `scripts/check-safety.sh` after each module. CLI tests use
`Support.builtBinary()` and a fake `claude` at `.local/bin/claude` under a temporary `HOME`, fail
with a clear message when the binary is missing, and never run the real `claude`. The test command
stays `scripts/check.sh` and the install check stays unchanged.

Data flow: readers run `claude` (auth status, probe) and write one reading file per account. Every
command that writes under the data folder ends by rebuilding `state/status.json` atomically.
`status --cached` rebuilds it from saved readings without starting a child process. `pick` reads
the same readings (refreshing stale ones first) and writes a lease and a pick log line. The
picker itself (`Picker/`) is a pure function; `PickService` in the same folder does the I/O around
it: kind checks, the refresh, the pick lock, the launch file, the lease and the log line.

The rebuild step is the only writer of the history. Under one lock, taken before it reads any
reading, lease or config file and held until `status.json` is renamed into place (section 13), it
appends a line to an account's readings history when its numbers changed, and a numbered line to
the events record when an account's state changed. `pick` and `verify` never read the history.
`status` and `refresh` never read the default folder's settings file (rule 3). The commands that
may read it (`init`, `pick`, `link --accept-source-change`) pass what they saw, the hook record
status and whether keys are present, to the rebuild, which keeps it in `state/current.json` and
carries it over for every rebuild that did not read the file. In the same way a sign-in check
(`status` runs `auth status` for the `login` account) and a probe (`refresh`, `pick`) each pass
their result, and a rebuild that observed nothing carries the last error over unchanged, so
`status --cached` never invents a recovery. A successful probe clears a carried `login_rejected`.
The app reads `status.json`, checks whether `config.json` exists (to choose the "no config yet"
state), writes no file itself, and calls the CLI for actions.

## 4A. Account kinds and the launch recipe

This section wins where sections 5 to 10 differ from it.

### 4A.1 Three kinds

| Kind | What it is | Where its sessions run | What the tool keeps | Full login |
|---|---|---|---|---|
| `login` | The login Claude Code already stores for the default folder | The default folder | Nothing | Yes |
| `token` | A one-year token the user makes with `claude setup-token` | The default folder, with the token set for that one session | The token, in `tokens/<label>.json` | No |
| `folder` | One Claude Code config folder per account, signed in once by the user | That folder, with its own supervisor, sessions, trust list, MCP servers and plugins | The links the user approved (section 5) | Yes |

A setup-token can only make model requests. It cannot establish Remote Control sessions or fetch
claude.ai connectors, so a token session has fewer skills and no connectors.

`token` is the default kind for an added account. A token session runs in the user's one config
folder, so hooks, skills, agents, history, trust and the list of background sessions are the same
as for the stored login. A folder has all of that only while every link is made and kept. A
`folder` account exists because only a full login reaches connectors and Remote Control.

Rules:

1. Each account has one kind, and one Claude account is registered once. Two entries for one
   account count its room twice; the duplicate checks in 4A.4 and section 9 look for that.
2. `role` (`main` or `pool`) is separate from `kind`, and any kind can be main.
3. A `login` account is optional. A user whose default folder holds an account they do not want
   in the pool leaves it out.

### 4A.2 The launch recipe

`pick` chooses an account and returns a recipe. A caller applies the recipe and never branches on
the kind. A recipe has two parts:

- `env`: environment entries for the new session. Empty for `login` and `token`. For `folder` it
  holds `CLAUDE_CONFIG_DIR`.
- `args`: arguments added to the `claude` command. Always exactly two: `--settings` and the path
  of a launch file.

The launch file is `~/.agent-balancer/launch/<label>/<leaseId>.json`, mode 0600, written by `pick`
under the pick lock. It is a Claude Code settings file and holds:

- `env.AGENT_BALANCER_ACCOUNT`: the label, for every kind. The in-use reader uses it (4A.6).
- The token variable of Claude Code, for the `token` kind only, copied from the token file.
- The caller's own settings, when it gave some.

Claude Code takes one `--settings` value, and with two flags only the last counts. A caller
therefore hands its settings to `pick` (`pick --settings '<json>'`), `pick` merges them into the
launch file, and the caller passes no `--settings` of its own. A file path keeps the token out of
the command line, out of the chat that typed it and out of the session's saved flags. Because
every launched session names a launch file, its account is known exactly even though `login` and
`token` sessions share one folder.

What `pick` accepts as caller settings. Anything else exits 1 with the reason, and no lease or
file is written:

- One JSON object of at most 16 KB.
- Top-level keys only from `launch.settingsKeys` in config. The default is `["env"]`. A caller
  cannot switch hooks off or change permissions through a file that is not visible in the typed
  line.
- Inside `env`: string values only, and every name must be in `launch.envNames` in config and
  match `^[A-Z][A-Z0-9_]{0,63}$`. The default is `[]`, so a caller passes no `env` name until the
  user lists some. These names are never allowed, whatever the list says: the protected group
  (6.2) and its own extras, any `AGENT_BALANCER_*`, `PATH`, `HOME`, `NODE_OPTIONS`,
  `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, and any name ending in `_PROXY` in either case. An `env`
  entry sits in the same file as the token, so a caller-chosen proxy, certificate file or `PATH`
  could read or run with it.
- A refused pick exits 1, writes nothing, and names the offending key, never its value, so a
  secret in a rejected value cannot reach the chat that typed it.

Two ways to apply a recipe:

- **Typing caller** (a chat or a person types the line). The answer carries two ready strings.
  `launchPrefix` goes in front of `claude`: `CLAUDE_CONFIG_DIR='<folder>' ` for a folder account,
  empty otherwise. `launchArgs` goes after the caller's own flags: `--settings '<launch file>'`.
  Both are literals from one renderer, built only from values that passed the validators. The
  typed line is `<launchPrefix>claude --bg <the caller's own flags> <launchArgs> '<prompt>'`.
- **Launcher** (a program that starts `claude` itself): `pick --caller launcher`. The child's
  environment is the launcher's own, minus every name in `unsetEnv`, plus `env`. The argument
  array is `claude`, the launcher's own flags, then `args`. `launchPrefix` and `launchArgs` are
  null for a launcher, so no typed line can be built from a launcher pick.

`pick` never launches and never prints a token. In schema version 1 a recipe is returned only for
an account that passed its kind's checks at pick time (4A.5).

### 4A.3 The ambient rule

A recipe is applied on top of the caller's environment, and that environment can beat it. An
inherited `CLAUDE_CONFIG_DIR` chooses the folder and its supervisor. An inherited token beats a
stored login in a foreground launch and does not reach a background worker. A token in
`--settings` reaches a background worker. Each rule fails closed:

1. `pick --caller typed` (the default) with `CLAUDE_CONFIG_DIR` set in its own environment offers
   only `folder` accounts, whose prefix overrides it. `login` and `token` candidates are skipped
   with the reason `ambient CLAUDE_CONFIG_DIR set`.
2. `pick --caller typed` with a token or key variable in its own environment (the Claude Code
   token variable, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`) answers with
   `backgroundOnly: true` for every kind, a folder pick included. The caller uses that recipe only
   with `claude --bg`. Otherwise `backgroundOnly` is false.
3. `pick --caller launcher` skips nothing and returns `unsetEnv`: `CLAUDE_CONFIG_DIR` (unless
   `env` sets it), the Claude Code token variable, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
   `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`. The launcher removes
   those from the child's environment.
4. The tool never suggests unsetting a variable in a typed line.

| Case | `pick --caller typed` | `pick --caller launcher` |
|---|---|---|
| Nothing inherited | Every kind competes; `backgroundOnly` false | Same; `unsetEnv` is still returned |
| `CLAUDE_CONFIG_DIR` inherited | Only `folder` accounts; `login` and `token` skipped with `ambient CLAUDE_CONFIG_DIR set` | Skips nothing; `unsetEnv` lists `CLAUDE_CONFIG_DIR` unless `env` sets it |
| Token or key inherited | Every kind competes; `backgroundOnly` true for every kind | Skips nothing; `unsetEnv` removes the variables from the child |
| Both inherited | Only `folder` accounts; `backgroundOnly` true | Skips nothing; `unsetEnv` removes both |
| `key_in_settings`: the default folder's `settings.json` carries `apiKeyHelper` or an `env` name among the API key and token names | `token` accounts skipped with `settings carry an API key or key helper` | Same |

Recorded manual checks behind this rule (2026-11-10, spike runs S12 and S17, results in
`.claude/sprint/DECISIONS.md` "Spike results"):

- An inherited `CLAUDE_CONFIG_DIR` picks the folder, so a `login` or `token` recipe applied under
  it lands in the wrong folder. This is why typed callers keep only `folder` accounts (rule 1).
- A token in `--settings` reaches the worker's own requests: a bad token gave "API Error: 401
  Invalid bearer token". A foreground session passes a settings env variable to its Bash child. A
  `--bg` worker does not.
- `claude setup-token` was run through a pipe (S14); the token shape and capture rule are in 4A.4.
- Not measured: which account a `--bg` worker bills when a valid token is in `--settings`, and how
  an inherited API key changes billing beyond the 401 behavior above. The rule therefore assumes
  the worst case: an inherited key or token marks every answer `backgroundOnly` (rule 2), and a
  launcher removes the variables (rule 3). If the open check shows the default login billed,
  token accounts become foreground-only for launches.

`init` and `doctor` look for the settings case by name only, never by value, with the same parse
as the hook record (5.7), and warn `key_in_settings` (section 9).

### 4A.4 The token kind

Adding: `add <label> [--email <address>] [--ends <date>] [--ending-soon]` (kind `token` unless
`--kind` says otherwise), then `login <label>`.

1. `add` writes the registry entry only. `--email` is a note for the person. The tool shows the
   note and never checks it against a token. `add` refuses a label whose `tokens/<label>.json`
   is still there from an earlier account and says to run `remove <label>` first, so a new
   account never takes over a token it did not sign in with.
2. `login <label>` gets the token, in a terminal and never in a chat shell. It runs
   `claude setup-token` as a child. The browser opens, the person approves, and the tool takes
   the token from the child's output without showing it. `TokenCapture`, inside the `Tokens`
   module, reads the child's raw output first and takes the token. Only then is the rest handed
   to the scrubber, so the scrubber never removes the token before capture and no other module
   holds an unscrubbed buffer. `TokenCapture` returns a length and shape check to its caller,
   never text. The fallback form, `login <label> --paste`, has the person run
   `claude setup-token` themselves and paste the token at a prompt that does not echo. The pipe form
   (spike S14) is the default and `--paste` is the fallback. A pasted or captured token must have
   the shape `sk-ant-oat`, two digits, a dash and letters, digits, dashes or underscores; an API
   key or any other text is refused and nothing is saved. The token
   is never a command argument and never an environment variable of the tool.
3. The tool checks the token's shape, writes `tokens/<label>.json` (mode 0600, content
   `{"env":{"<token variable>":"<token>","AGENT_BALANCER_ACCOUNT":"<label>"}}`), records
   `tokenCreatedAt`, and runs one probe under it: the section 6.2 probe with
   `--settings <token file>` added and no `CLAUDE_CONFIG_DIR`. Before each probe the `Tokens`
   module checks that the token file is private and parses, and only a yes or no leaves it; the
   probe gets the path and never the token value. `tokenCreatedAt` is an optional ISO 8601 time on the account's
   config entry (7.1), set by every `login`; the config schema stays at version 1.
4. Duplicate check: if, after that probe, the new account's weekly reset time and 5-hour reset
   time both equal another account's, `login` warns `possible_duplicate` and names the other
   label. It is a warning, not an error, because two accounts first used in the same hour could
   match. `pick` still treats them as two accounts. The check runs in the reading cache's
   `afterProbe` hook, so it runs on every probe of a token account, at `login` and after it, and a
   token file swapped for another account's token shows as `possible_duplicate`. The status keeps
   what the last check found until the account's next probe checks again; the warning writes no
   event.

Expiry: a setup-token lasts one year. The tool shows `tokenCreatedAt` plus 365 days (the token
file's last change when the account has no `tokenCreatedAt`) as `loginExpiresAt` with `loginExpiresSource: "estimate"`, warns `login_expiring` 14 days before, and
shows `login_rejected` when a probe gets an auth error.

Replacing: `login <label>` on an account that already has a token. The new token replaces the file
in one rename, every live launch file of that label is rewritten with it, and a `token_replaced`
event is written. A tombstone (below) is never revived. A launch file that does not parse never
keeps the old token: one a session record names becomes a tombstone, and any other is deleted. The
replace lists the label's launch files again under the pick lock before it finishes, so a file that
a pick wrote during the rewrite is not missed, and the writer's leftover temporary files in
`tokens/` and that label's launch folder are deleted. A running or sleeping session keeps the token it
started with until its process restarts. The tool then says, every time, that the old token may
keep working until its year ends, because no way to cancel one is documented. Whether a new token
ends the old one is not yet known; a manual check at the token-path checkpoint records the answer,
and until then the text holds either way.

Removing: `remove <label>` never refuses because a session still names a launch file. Under the
pick lock it works in this order: (a) a launch file of the label that a session record names, or
whose lease has not ended, or any launch file when the records cannot be read cleanly, is
overwritten with a tombstone, and every other launch file of the label is deleted; (b) the label's
leases are deleted; (c) the launch files are listed again and (a) is repeated for any file a `pick`
wrote meanwhile; (d) every remaining file is read back, and when one still holds a token the remove
stops and keeps the token file and the account; (e) the writer's leftover temporary files in
`tokens/`, `tokens/<label>.json` and the stored reading are deleted; (f) the config entry is
deleted last, still under the pick lock, and the rebuild that follows writes the `account_removed`
event. A crash after any step leaves a state that `remove <label>` finishes on a
rerun, also when the config entry is already gone, and `doctor` lists a token file that has no
account. A tombstone is valid JSON, mode 0600, in the launch file's shape, with the token variable
set to the literal `invalid` and no other secret: a session that reads it fails to sign in instead
of falling back to the stored login. This keeps a launch file in place while any session record
names it, live or not, and still leaves no file holding the old token; upkeep deletes a tombstone
once no record names it and it is older than `picker.leaseMinutes`. `remove` says the same about the
token living on. `remove` on any kind also deletes that label's launch files, leases and stored
reading, so a label added again never inherits them. `remove` on a `folder` account never deletes
the folder. Every overwrite and delete goes through the no-follow writer and touches only a regular
file owned by the user named `l-<8 hex>.json` directly under `launch/<label>/` (or the token file
directly under `tokens/`). Any other entry, a link included, is skipped, not followed, and counted in
the output, and the writer's own leftover temporary files in `tokens/` and in that label's launch
folder are deleted and read back; any that could not be deleted are counted in the output.

Leftover temporary files: the no-follow writer writes each file whole to a `.tmp-<16 hex>` name and
renames it into place, so a process killed between the two leaves that temporary file, which can
hold a whole token. Every writer of `tokens/` and `launch/` holds the pick lock, so under that lock
such a file belongs to no write in progress. `remove`, a token replace and the launch file upkeep
(on `pick` and `refresh`) delete the ones in `tokens/` and in the launch folders: only names of that
shape that are regular files owned by the user, directly in the folder, through the no-follow
writer. `doctor` counts the ones that are left. A `login` checks, under the pick lock and right
before it writes the token file, that the registry still holds the label as a token account, and
writes nothing when it does not, so a `login` that a `remove` overtook leaves no token behind.

Renaming: `config set <label> label <new>` refuses on a token account, exits 1 and writes nothing,
because its token file and launch files carry the label; remove the account and add it again under
the new label.

Where a token may be: the token file, the launch files of that label, and nowhere else, except a
writer's temporary file that a write killed before its rename leaves in `tokens/` or
`launch/<label>/`; the next `remove`, token replace or upkeep pass deletes it under the pick lock
(Leftover temporary files, above). Not in
stdout or stderr, not in `status`, `events`, `history`, `picks.log` or the log, not in an argument
or an environment the tool builds, not in the app. The safety script enforces the source rule: the
Claude Code token variable name and any path under `tokens/` or `launch/` appear only in the
`Tokens` and `Launch` modules. Other modules (`Remove`, `Uninstall`, `Doctor`) reach those folders
only through calls those two modules offer (delete, count, has-lease) and build no path into them.
Both folders are marked as excluded from backups: the Paths writer sets the
`com.apple.metadata:com_apple_backup_excludeItem` attribute on the folder handle before the first
file lands in it.

### 4A.5 Checks per kind at pick time (fail closed)

| Kind | `pick` returns a recipe only when |
|---|---|
| `login` | `auth status` shows the default folder logged in as the configured email and plan |
| `token` | The token file exists, is a regular file owned by the user with mode 0600, holds a token that parses, and its last probe did not end in an auth error |
| `folder` | `verify` passes (5.7): every link in the manifest is intact and no hook entry recorded at link time is gone. A folder account must be linked, always: a never-linked folder is refused with the reason `not linked`, because a folder without the shared settings runs with no hooks. A user with nothing to share still runs `link` once; it records an empty manifest |

`init` always writes the hook record of the default folder, empty when there are no hooks. A
`login` or `token` account is refused with `settings_changed` when a recorded hook is later gone
or changed, or hooks are switched off. After `init`, a missing or unreadable record fails these
accounts too, with `settings_changed` and the text "Hook record missing. Run
`agent-balancer link --accept-source-change` in Terminal." A record that holds a fingerprint or
command hash other than 64 lowercase hex digits counts as unreadable, so no other value of it is
ever printed.

`pick --full-login` offers only `login` and `folder` accounts, for a session that needs
connectors, Remote Control or the claude.ai skills. Without it every kind competes on the picker
rules of section 7.

### 4A.6 Readings and in-use under each kind

- **Probe:** one probe per account under any kind. `login`: the 6.2 probe as written. `token`:
  the same plus `--settings <token file>`. `folder`: the same with `CLAUDE_CONFIG_DIR` in the
  child's environment.
- **Fable:** a Fable request adds the window `seven_day_overage_included`, which is the Fable
  weekly meter. A Fable probe reads it, and `fable.probe` is true by default. One costs roughly 20
  to 35 cents as the CLI prints it, so it runs at most once a day per account, before a Fable pick
  whose Fable reading is older than that, or when all-models use has risen by
  `fable.recheckAfterWeeklyRisePercent` (default 5) since the reading, or when the Fable window
  has reset. The rise and reset rechecks wait at least 10 minutes after the last Fable probe
  tried, so a failing probe is not repeated on every pick. A pick for another model runs no Fable
  probe at all; `refresh` runs one at most once a day. A Fable probe has its own
  budget and timeout, `fable.probeBudgetUsd` (default 0.50) and `fable.probeTimeoutSeconds`
  (default 20), set from the check recorded in 6.2, because a cold Fable probe costs more than
  the 0.05 cap of the plain probe and a cap below the cold cost still spends it and returns no
  reading. The estimate of 7.4 is the
  fallback for an account with no Fable reading yet, or with `fable.probe` switched off.
- **In use:** a session counts toward the account named by the launch file in its saved flags. A
  session in the default folder with no launch file counts toward the `login` account. A session
  in an account folder counts toward that folder's account.
- **Launch file upkeep:** `pick` and `refresh` run it under the pick lock, so it never removes the
  file of a pick in progress. The tool reads session records (section 8) and works from one of two
  cases.
  - Records read cleanly: a launch file is deleted only when no record names it, no open lease
    holds it and it is older than `picker.leaseMinutes`. A launch file that any record names is
    kept for as long as that record exists, whatever the session's state (running, sleeping,
    finished or failed); a background session's launch file is named in its job record
    (`respawnFlags`), a foreground session's record names none. A lease that ended without a
    launch leaves a file no record names, so it goes.
  - A record cannot be opened or read, is not a regular file, or is over 1 MiB: only files older
    than `launch.keepDays` (default 35) are deleted, and `inUse` is `unknown`.

  A removal touches only a regular file owned by the user, named `l-<8 hex>.json`, directly under
  `launch/<label>/`, through the no-follow writer; a link planted there is neither followed nor
  deleted. In both cases the pass also deletes the writer's leftover temporary files in `tokens/`
  and in each launch folder (Leftover temporary files, 4A.4), and `refresh` runs it even when no
  account is set up. What a respawned background session does when its launch file is gone was
  never measured, so the worst case is assumed (it runs on the stored login with no error), which
  is why a named file is never deleted. Whether a running or sleeping session re-reads a rewritten
  launch file is also unmeasured: a wake did not restart the process, so a session keeps the token
  it started with until its process restarts.
- **Trust and messages:** `login` and `token` sessions share the default folder, so a project
  trusted once is trusted for all of them and messages between their sessions work. Only `folder`
  accounts need the per-folder trust step and the file-only reports of 5.2.

### 4A.7 What ships for other people's Claude

1. **A skill file**, `skill/agent-balancer/SKILL.md`, in the repo and in the Homebrew share
   folder. It tells a user's Claude when to call `status` and `pick` and how to apply a recipe. The
   README gives the one line that links it into the user's skills folder. The tool itself never
   writes inside `~/.claude`.
2. **Versioned JSON output.** `schemaVersion` fields, the golden-output tests and
   `docs/CONTRACT.md`.
3. **A deny-rule snippet** in the README Limits section: permission deny rules for
   `~/.agent-balancer/tokens/` and `~/.agent-balancer/launch/`, for the user to paste into their
   own Claude Code settings. The tool never writes it. It narrows threat T26 and is advisory
   against code that runs as the user.

An optional steering hook, JSON Schema files and a Homebrew cask are parked for a later release.

## 5. Account folders, shared config and guarded launch

### 5.1 Folder layout

Root is `~/.agent-balancer/`, outside `~/.claude`. The shared source is the config key
`sharedSource`, default `~/.claude`, which the tool only reads.

| Piece | Shared or per account | How | Who makes it | Consent |
|---|---|---|---|---|
| Account folder `~/.agent-balancer/accounts/<label>/.claude` | per account | empty folder; the inner name `.claude` is deliberate so path rules written for Claude settings apply to its `settings.json` | `agent-balancer add <label> --kind folder` | the user runs `add`; the tool prints the login step and never logs in |
| Login (Keychain entry keyed to the folder) | per account | not touched by the tool | the user | the user's own `/login` |
| `.claude.json`, `sessions/`, `daemon/`, `jobs/`, `backups/`, `projects/`, `plugins/`, `stats-cache.json` | per account, never linked or copied | Claude Code makes them on first run | Claude Code | none; trust lives in `.claude.json`, which the tool never reads, so `doctor` repeats the trust step |
| `settings.json` | shared | one-hop symlink to the real file in `sharedSource`; a source that is itself a link is resolved to its real target first; refused if that target is not owned by the user or the destination exists | `agent-balancer link <label>` | a dry run lists every path, target and `lstat`; applying needs a terminal and the label typed back; no `--yes` flag |
| `CLAUDE.md` | shared | one-hop symlink, same checks | same | same |
| `skills/`, `agents/`, `commands/` | shared | one-hop folder symlinks, same checks | same | same |
| Hook scripts | shared by path | not in any folder; hook commands in settings use absolute paths | existing setup | none |
| Link manifest `~/.agent-balancer/links.json` | tool data | each link, its target, and the hook fingerprint of `settings.json` at link time (5.7) | `link` on apply | written only on apply; `unlink` removes a listed path only while it is still a symlink inside a configured account folder with the recorded target (section 13), so it is reversible and never deletes a regular file |

A source that does not exist is skipped with a printed note, not refused. Running `link <label>`
again later adds links for sources that exist by then. A source that is itself a symlink is
resolved to its final target, which must be a regular file or folder owned by the user. `link`
refuses, leaving the folder as it was, when a destination exists and is not the exact intended
link, a destination parent is a link, the folder is the default folder, or the folder is not owned
by the user.

Consent commands (`link`, `unlink`, `link --repair`, `link --accept-source-change`,
`schedule install`, `uninstall`, `config set-main`, `config set`, `remove`) refuse to run in a chat
shell, so a chat cannot type the label through a pseudo terminal. `run` and `login` never start
`claude` in a chat shell either. The Manage accounts window (section 11) runs `add`, `remove`,
`config set <label> ends|ending-soon` and `login` for a person who clicks, and it turns itself off
when the app's own environment carries the chat-shell variable.

The chat-shell test is `CLAUDE_CODE_CHILD_SESSION` present with any value, empty included. Claude
Code sets it in the subprocesses of its shell tools, hook commands and status line commands, and
IDE extensions do not set it, so it tells a nested session from a top-level `claude` in an
IDE-integrated terminal. `CLAUDECODE` alone is the wrong test, because IDE extensions set it in
their integrated terminals. The refusal message is "Run this in your own terminal, outside a
Claude Code session." Neither the tool nor its README ever suggests unsetting a variable.

### 5.2 The orchestrator launch line

The contract serves two kinds of caller. A **typing caller** runs `pick` and then types the launch
line itself. A **launcher** is a program that starts `claude` itself, as a child process whose
environment it builds, and takes only `label` and `env` from `pick`. Section 16 promises both.

The orchestrator first runs `agent-balancer pick --json`, which returns the recipe (4A.2). It then
types its own launch command with `launchPrefix` in front, as one literal command, so any gate
that reads typed commands sees and judges it. There is no launch template in config: the tool
prints only the prefix, from a folder path that passed the config validator. A typed line reads:

```
CLAUDE_CONFIG_DIR='<configDir>' claude --bg --name "<name>" --model <model> --settings '<launch file>' '<prompt>'
```

For the default folder the prefix is empty. The tool never puts the literal default path in the
prefix. Because a prefix-less line inherits the caller's environment, `pick` skips the
default-folder candidate with reason `ambient CLAUDE_CONFIG_DIR set` when that variable is set in
its own environment (4A.3), and keeps ranking the rest. The folder in the prefix must match
`^/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$` with no `.` or `..` segment, and a label must match
`^[a-z0-9][a-z0-9-]{0,31}$`. The config validator rejects anything else at load time, so a bad
value fails everywhere, and every printed command goes through one renderer. `--model` only
chooses the budget rule and must match `^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,63}$`. It is never
printed into a command. A literal path in the prefix is required, never a substitution, so the
account stays visible to a reader.

Conditions:

1. After launch, the caller confirms the folder with
   `CLAUDE_CONFIG_DIR='<configDir>' claude agents --json`. A session missing there means the
   launch did not land in that folder, so the caller stops launching onto that account and
   reports it.
2. Workers in a different account folder than their orchestrator report only through a receipt
   file, because messages between sessions do not cross config folders.
3. A session in an account folder has only the MCP servers and plugins added in that folder (5.1),
   and the project folder must be trusted on that account first. An untrusted folder can stall a
   `--bg` launch.

**The launcher.** A launcher never hands a command line to a shell or a chat. A program that
reserves or prints a line that a chat or shell then runs is a typing caller. What the tool asks of
a launcher:

1. Call `agent-balancer pick --json --caller launcher --model <model>` once per launch and use
   `label`, `env`, `args` and `unsetEnv`.
2. Start `claude` with the launcher's own environment minus every name in `unsetEnv`, plus every
   entry of `env`, as an environment beside an argument array, never pasted into a shell string.
   It never sets the default folder path by hand.
3. Never build an account folder path, never read `config.json` or any file under
   `~/.agent-balancer/`, and never keep a folder for a label from an earlier pick. One pick is
   good for one launch, within `leaseMinutes`.
4. Record `label` as the account in its own launch record.
5. Confirm the launch with the environment of step 2, never an inherited value.
6. Exit 2: launch nothing and park the item with `reason`. Exit 1: no pick; report the error.

### 5.7 Drift checks that fail closed

`verify <label>` runs before `pick` returns any account (cached 60 seconds in process memory only,
never on disk) and before `run`. Each check is a refusal that removes the account from `pick`:

1. every link is still a symlink to the recorded target;
2. each target still exists, is owned by the user, and is a regular file (`settings.json`,
   `CLAUDE.md`) or a folder (`skills/`, `agents/`, `commands/`). The tool never walks or reads
   inside the folders and compares no inode and no whole-file hash, so an ordinary edit of the
   shared files does not drop every account;
3. `settings.json` parses, has no `disableAllHooks`, and its hook fingerprint (the set of event,
   matcher and SHA-256 of each command string) still contains every entry recorded at link time,
   so adding a hook passes and removing or changing one fails;
4. `claude auth status --json` shows the folder's own `configDirectory` and the expected login;
5. for `pick` only, a reading is fresh enough.

`run` and `login` use `verify --no-reading` (checks 1 to 4), so a new account can be started
before its first reading. Missing, stale or unreadable counts as failed. `link --repair` re-links
only after the same typed approval. A changed hook set is re-accepted only with
`link --accept-source-change`, which prints the hook entries added and removed (event, matcher and
command hash, never the command text, which can hold secrets) and whether `disableAllHooks` is
present before asking for the typed word `accept`. With no label it re-accepts the default
folder's record; `--all` adds every linked folder. `status` and the menu show one banner,
"Settings changed" (section 9), instead of one error row per account, and the events record still
holds one `settings_changed` event per affected account. `verify` reads `settings.json` only to
parse the hook entries and that flag; it never logs or stores the file's content.

The default folder is never linked (5.1) and never counts as `not linked`. It still has hooks to
lose, and every `login` and `token` session runs in it. So `init`, `link` on apply and
`link --accept-source-change` record the hook fingerprint of the default folder's `settings.json`
in `links.json`, and check 3 runs on it as on every linked folder. `init` always writes the
record, an empty one when the user has no hooks. After `init`, a missing or unreadable record
fails these accounts with `settings_changed` and the text in 4A.5. The check compares command
strings only, so editing the script a command points to is not seen.

## 6. Usage readings

### 6.1 Sources, cheapest first

| Source | Gives | Cost | When |
|---|---|---|---|
| `claude auth status --json` | Logged in or not, email, `planTier`, `subscriptionType`, `loginExpiresAt`, `configDirectory` | Free (no model call) | Every refresh, every folder |
| One-turn probe | `rate_limit_event.rate_limit_info`: status, `unifiedWindows.five_hour` and `seven_day` utilization (0 to 1 on the wire; a value outside that range is `check_failed`) and `resetsAt` | About $0.008 API-equivalent | Only when the stored reading is older than `picker.maxReadingAgeMinutes`, or on `refresh --force` |

The probe reports utilization as a fraction from 0 to 1. The reader converts it once, at parse
time, to percent from 0 to 100 with one decimal (0.456 becomes 45.6). Every stored reading, every
room figure and every output uses percent.

### 6.2 The probe

Exact form, run by the tool as its own child process (argument array, no shell):

```
cwd: a fresh mkdtemp folder under ~/.agent-balancer/probe/, mode 0700, removed after the probe
     (so no project CLAUDE.md, .mcp.json or hooks load; several probes may run at once, so the
     probe refuses to run only if probe/ holds something that is not a probe folder, and it first
     removes a probe folder older than the probe timeout)
env: CLAUDE_CONFIG_DIR=<account folder>  (left unset for the default folder)
claude -p "Reply with the single word OK." --model haiku --tools "" --disallowedTools "mcp__*"
       --strict-mcp-config --max-turns 1 --no-session-persistence --max-budget-usd 0.05
       --output-format stream-json --verbose [--safe-mode]
```

- A Fable probe (4A.6) is this form with `--model` set to a Fable model, using
  `fable.probeBudgetUsd` and `fable.probeTimeoutSeconds` in place of the 0.05 cap and the 60
  second timeout.
- The tool reads only `type == "rate_limit_event"` lines and the final `result` line's error
  fields. Everything else is discarded unread. Captured stderr goes through the scrubber before
  any log line.
- `--safe-mode` keeps login and model selection working and stops CLAUDE.md, skills, plugins,
  hooks and MCP servers from loading. It is on only when `probe.safeMode` is true. If Claude Code
  does not know the flag, the row shows `check_failed` with the scrubbed error text; the probe
  never falls back to normal mode silently. With `safeMode` off, each probe runs the folder's
  hooks once, and `doctor` and the README privacy list say so.
- A probe reply counts as a reading only when at least one `rate_limit_event` carries a window
  with a `utilization` value. Events with no such value give `check_failed`, never an empty reading.
- Fable probe check, recorded on 2026-11-10 with the exact probe form above and a Fable model. A
  first, cold run with a 0.05 USD cap spent 0.099 USD in about 4 seconds and was cut off
  (`error_max_budget_usd`, no `rate_limit_event`, so no reading). A second run with a 1.00 USD cap
  succeeded in 3.2 seconds for 0.0067 USD, most likely from a warm prompt cache (inferred, not
  verified). Two earlier cold samples cost 0.19 and 0.33 USD. The defaults come from this check:
  `fable.probeBudgetUsd` is 0.50 USD, above every cold cost seen, and `fable.probeTimeoutSeconds`
  is 20, five times the longest run seen (about 4 seconds), which leaves 25 of the 45 second pick
  deadline.
- Manual smoke status, still open: the probe cost with and without `--safe-mode`, and the check
  that the two MCP flags start no server, are not yet recorded. The `probe.safeMode` default stays
  as it is until they are.
- A reset time from the probe must lie within the window it belongs to, measured from the time of
  the probe: no more than 300 seconds before it, and no more than one window length plus 300
  seconds after it. The window length is 5 hours for `five_hour`, 7 days for `seven_day` and the
  Fable window, and 31 days for a window name the tool does not know. A reset time that is
  outside that range, is not a number or a date, or is a boolean gives `check_failed`, like a
  usage value outside 0 to 1, and nothing is stored. A missing or null reset time is stored as
  unknown. Numbers above 100 billion are read as milliseconds. The same range of years, 2000
  to 2200, applies to dates read from `auth status`.
- A lock file per account folder stops two probes of one account at once. A caller that finds the
  lock held waits up to its deadline and then uses the stored reading. `refresh` and `pick` skip a
  probe when the stored reading is younger than `picker.maxReadingAgeMinutes`, unless
  `refresh --force`. A 60 second timeout marks the row `check_failed`.
- The protected group of environment names, named once here: `CLAUDE_CONFIG_DIR`, the Claude Code
  token variable, every `ANTHROPIC_*` and every `CLAUDE_CODE_USE_*`. Code holds the group once
  (`Sources/Core/Env/ProtectedEnv.swift`); every other site refers to it and adds only its own
  extras.
- Two child environments. Probe and `auth status` children get an allowlist: `PATH` set to the
  folder that holds `claude` plus `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`
  (a Finder-started app or a LaunchAgent has only a short `PATH`), `HOME`, `USER`, `LOGNAME`,
  `LANG`, `LC_*`, `TMPDIR`, plus `CLAUDE_CONFIG_DIR` only for a non-default folder. Everything
  else is dropped, including the protected group and an ambient `CLAUDE_CONFIG_DIR`, so a stray
  key or token can never bill the wrong account or fool a check. Proxy variables (`HTTPS_PROXY`,
  `HTTP_PROXY`, `NO_PROXY`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`) pass only when
  `probe.passProxyEnv` is true (default false). Person launches (`login`, `run`) are interactive
  sessions, so they get the user's own environment minus the protected group and an ambient
  `CLAUDE_CONFIG_DIR`, with the terminal attached. `doctor` warns, by name only and never by
  value, when such variables exist in the user's shell.
- `--tools` does not cover MCP tools, so the probe also denies `mcp__*` tools and passes
  `--strict-mcp-config` with no `--mcp-config`.
- The runner finds `claude` only in a fixed list (`~/.local/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin`), uses the path found there (not a versioned real target, so a Claude Code
  update does not break it), and refuses a file whose real target is not owned by the user or
  root, or is writable by group or others. The parent folder gets the same test only for
  `~/.local/bin`, because Homebrew's own bin folders are group-writable on a standard install and
  testing them would reject every Homebrew binary, the tool's own CLI included. No executable path
  is read from config or any file in the data folder; a user with `claude` somewhere else links it
  into `~/.local/bin`.

### 6.3 Cache and age

Each reading carries `source`, a `readAt` (when the last probe that fed it finished, which the age
rule reads) and one entry per window with its own `readAt` (when the stored value was taken). A
lower value that does not replace the stored one leaves the window's `readAt` where it was.
`state/readings/<label>.json` is a fixed set of keys that a golden test pins: `schemaVersion`,
`source`, `readAt`, `windows`, `fable` and `fableProbedAt`. `fable` has `source` `probe` (with
`usedPercent` as a share of the Fable cap, `resetsAt`, `readAt`, `weeklyUsedPercentAtRead`) or
`estimate` (with `upToPercentOfWeekly` and `guaranteedRoomPercentOfCap`, section 7.4).
`fableProbedAt` is the time of the last Fable probe tried, so the once-a-day limit holds when one
fails. `refresh --force` does not lift that limit.

`status` shows the age; the menu greys a row whose
reading is older than twice the refresh interval. `pick` refreshes any candidate whose reading is
older than `picker.maxReadingAgeMinutes` (default 15) and skips the probe when the reading is
younger (unless `refresh --force`). If that refresh fails, the candidate is skipped with reason
`stale reading, refresh failed`. For the protected account a stale reading is treated as worst
case (not eligible), never as zero use.

Readings merge by one rule: within one window (the same `resetsAt`, to the minute) stored use
never goes down, so each new reading is merged as the maximum for that window. A reading that
claims a later `resetsAt` before the stored reset time has passed is discarded. A stored
`resetsAt` further ahead than its window length plus 10 minutes (a file from before the bounds of
6.2, or an edited one) is not trusted, so the next valid reading replaces it. A stored file that
does not decode as a whole reads as no reading, and the next good probe writes a new one; a stored
reset time that does not decode reads as unknown, and a stored use outside 0 to 100 is dropped. A reading whose
`resetsAt` has passed, that has no weekly value, or that is dated more than 60 seconds in the
future counts as stale: it is refreshed first, and the account is skipped with
`window reset, refresh failed` or `no weekly reading` if that refresh fails. A `pick` forces the
probe for a candidate whose stored reading has a passed reset time, even when it is younger than
`picker.maxReadingAgeMinutes`. For a `main`
account a launch is allowed only on a probe reading from the current window no older than
`picker.maxReadingAgeMinutes`. The pre-pick refreshes run in parallel and `pick` answers within
`picker.deadlineSeconds` (default 45); a candidate whose refresh fails or misses the deadline is
skipped with `check_failed`; a probe left running past the deadline ends on its own and `pick`
does not wait for it.

### 6.4 Refresh cadence and daily cost

A probe costs about $0.008 API-equivalent. A probe is skipped while the stored reading is younger
than `picker.maxReadingAgeMinutes`, so real cost can be lower than the table.

| Background cadence (5 idle accounts) | Probes per day | API-equivalent per day |
|---|---|---|
| Every 15 minutes | 480 | $3.84 |
| Every 30 minutes | 240 | $1.92 |
| Every 60 minutes, background only | 120 | $0.96 |
| Every 60 minutes plus the pre-pick refresh at about 20 picks a day (default) | about 180 | about $1.44 |
| On demand only (about 20 launches a day) | about 20 | about $0.16 |

The default is 60 minutes in the background plus the on-demand refresh before `pick`.

The menu app runs `agent-balancer refresh` at launch when `status.json` is missing or older than
`refresh.backgroundMinutes`, then on its own timer at that interval, and runs
`agent-balancer status --cached` every 60 seconds so new readings show up. Every `refresh` ends by
rebuilding `status.json` (section 4). People who use only the CLI run
`agent-balancer schedule install`, which shows a user LaunchAgent plist in a dry run, writes it to
`~/Library/LaunchAgents/` only after a typed yes, and prints the `launchctl bootstrap` line for the
user to run, because the tool starts no child process other than `claude` and itself.
`schedule remove` prints the matching `launchctl bootout` line and deletes the plist.

## 7. The picker

### 7.1 Config

```json
{
  "schemaVersion": 1,
  "accounts": [
    { "label": "main", "kind": "main", "configDir": null, "email": "main@example.com",
      "expectedPlanTier": "max_20x",
      "reserve": { "points": [ { "daysLeft": 5, "maxUsedPercent": 50 },
                               { "daysLeft": 2, "maxUsedPercent": 90 } ],
                   "marginPercent": 5 },
      "fable": { "allowLaunches": false } },
    { "label": "pool-a", "kind": "pool", "configDir": "<account folder>",
      "email": "pool-a@example.com" },
    { "label": "pool-b", "kind": "pool", "configDir": "<account folder>",
      "email": "pool-b@example.com", "endsAt": null, "endingSoon": true }
  ],
  "picker": { "limitedAtPercent": 95, "minRoomPercent": 5, "maxReadingAgeMinutes": 15,
              "deadlineSeconds": 45, "leaseMinutes": 10, "expectedRunPercent": 5,
              "endingSoonAssumeDays": 2 },
  "fable": { "capPercentOfWeekly": 50, "probe": true, "probeBudgetUsd": 0.50,
             "probeTimeoutSeconds": 20, "minRoomPercentOfCap": 10,
             "recheckAfterWeeklyRisePercent": 5 },
  "launch": { "settingsKeys": ["env"], "envNames": [], "keepDays": 35 },
  "probe": { "safeMode": true, "timeoutSeconds": 60, "passProxyEnv": false },
  "refresh": { "backgroundMinutes": 60 },
  "history": { "retentionDays": 35 }
}
```

`configDir: null` means the default folder with `CLAUDE_CONFIG_DIR` unset. The tool cannot learn a
subscription's end date, because none of its sources carries one. An account that ends soon is
marked `endingSoon: true` (`config set <label> ending-soon true`): the picker spends such an
account first (rule 5 in 7.2), and the tool notices the end itself on the day the plan tier drops
(section 9, `account_ended`). `config set <label> ends <date>` sets a date that is known.

A token account also carries `tokenCreatedAt`, an ISO 8601 time that `login` sets each time it
saves a token (4A.4). It is optional, so a config from before it stays valid at schema version 1.

Every account also carries `expectedPlanTier` and `accountKey`. `init` records the tier
`auth status` shows; for an added account the first refresh after its sign-in records it.
`accountKey` is a random id that `init` and `add` make. It is no secret, and it goes on every
history and events line and into `status`, so a label removed and added again for another account
is never mixed with the old one.

An account may also carry `"fable": { "allowLaunches": false }` (7.2 rule 4; absent means
allowed). An account's `endsAt` date is its last day: the account counts as ended once that local
day is over. The validator refuses `picker.limitedAtPercent` outside 1 to 100,
`picker.minRoomPercent` and `picker.expectedRunPercent` outside 0 to 100,
`picker.deadlineSeconds`, `picker.leaseMinutes` and `launch.keepDays` below 1,
`picker.endingSoonAssumeDays` below 0, a `launch.envNames` entry that does not match
`^[A-Z][A-Z0-9_]{0,63}$`, and a `launch.settingsKeys` entry that is not a plain name. A key missing
from a section takes the default shown above.

`minRoomPercent` and every room figure are in percent of the weekly limit, except a Fable room
read from a Fable reading, which `fable.minRoomPercentOfCap` compares in percent of the Fable cap
(7.4). `sharedSource` (default `~/.claude`, section 5.1) is one more top-level key. There is no
launch template and no executable path in config. The 90 percent cap in the last reserve point is
the last point at which a launch may start. A validator refuses any point above 90 percent for a
`main` account unless `allowAbove90` is set.

### 7.2 Rules, in order

1. Candidates: every account not `ended`, logged in as the configured email, on the expected plan
   tier, not `limited`, with a fresh or refreshable reading.
2. Line for a protected account: with `d` = days to its weekly reset, the line is the configured
   point value, linear between points, flat beyond the ends. Eligible only if
   `weekly used + marginPercent <= line`.
3. Pool account: eligible only if `limitedAtPercent - weekly used >= minRoomPercent` and the
   5-hour window (when present) is under `limitedAtPercent`.
4. Model-aware: for a Fable launch, also require Fable room (7.4): with a Fable reading,
   `100 - usedPercent >= fable.minRoomPercentOfCap`, both in percent of the Fable cap; with no
   reading, the guaranteed room of the fallback `>= minRoomPercent`. Skip any account with
   `fable.allowLaunches: false`.
5. Rank the eligible by effective expiry `min(weekly reset, endsAt)`, soonest first. An account
   marked `endingSoon` with no `endsAt` ranks as if its `endsAt` were
   `picker.endingSoonAssumeDays` (default 2) from now; a known `endsAt` sooner than that still
   ranks ahead of it. Ties go to the most room (`line - marginPercent - used` for a protected
   account, `limitedAtPercent - used` for a pool account), then to config order, so the answer
   never flips between runs.
6. Nothing eligible: return `label: null` with one reason per account; exit code 2. Never fall
   back past the line.
7. Lease: `pick` runs its refreshes first, then holds an exclusive lock on `locks/pick.lock` (wait
   up to 30 seconds, else exit 1 with `pick busy`) while it reads `state/leases.json`, decides and
   writes its lease (an internal id for the pick log, label, model, time). A caller that did not
   launch does nothing; the lease lapses after `picker.leaseMinutes`, and a lease dated in the
   future is dropped. For `picker.leaseMinutes` (default 10) each open lease adds
   `picker.expectedRunPercent` (default 5) to that account's weekly used and 5-hour used before
   rules 2 to 4, so two callers picking seconds apart spread out. `pick --dry-run` takes the lock
   but writes no lease.
8. Units: the probe's `utilization` (0 to 1) is stored as percent 0 to 100 with one decimal
   before any rule runs.
9. A protected account also needs `fiveHour used + expectedRunPercent < limitedAtPercent` when a
   5-hour window is present, so a worker cannot lock the user out of the main account until the
   5-hour reset.

The line applies only to `pick`. The user's own chats on the main account never call `pick` and
are never gated.

### 7.3 Worked table: the reserve line on the main account

Line = most weekly use at which a launch may still go to the main account. The example uses the
points of 7.1 (50 percent at 5 days left or more, 90 percent at 2 days left or fewer) and a margin
of 5 points.

| Days left to the weekly reset | Line (max weekly used) | Launch only if used is at most | Reserve kept for the user |
|---|---|---|---|
| 7 | 50.0% | 45.0% | 50.0% |
| 6 | 50.0% | 45.0% | 50.0% |
| 5 | 50.0% | 45.0% | 50.0% |
| 4.5 | 56.7% | 51.7% | 43.3% |
| 4 | 63.3% | 58.3% | 36.7% |
| 3.5 | 70.0% | 65.0% | 30.0% |
| 3 | 76.7% | 71.7% | 23.3% |
| 2.5 | 83.3% | 78.3% | 16.7% |
| 2 | 90.0% | 85.0% | 10.0% |
| 1 | 90.0% | 85.0% | 10.0% |
| 0.5 | 90.0% | 85.0% | 10.0% |
| 0 (reset) | a new week starts: used falls to about 0 and days left return to 7 | | |

Between 5 and 2 days the line rises 13.3 points per day (40 points over 3 days).

### 7.4 Two budgets per account: the Fable reading and its fallback

Each account has an all-models weekly meter and a Fable sub-cap of 50 percent of that same week.
Fable use counts in both. A Fable launch needs room in both; any other model needs room only in
all-models.

**The reading.** A Fable probe reads the window `seven_day_overage_included` (4A.6), which is the
Fable weekly meter as a share of the Fable cap. The row says `source: probe`, `usedPercent` is
that reading, and Fable room is `100 - usedPercent` percent of the Fable cap. The pick needs
`100 - usedPercent >= fable.minRoomPercentOfCap` (default 10), in percent of the Fable cap on both
sides. `fable.capPercentOfWeekly` is used only by the fallback, so the unconfirmed 50 percent
ratio never decides a pick that has a reading. A Fable reading is stale for a Fable pick when it
is older than a day or all-models use has risen by `fable.recheckAfterWeeklyRisePercent` since it
was taken.

**The fallback.** It applies only to an account with no Fable reading yet, or with `fable.probe`
switched off. The tool then knows only that Fable used `F` sits between 0 and `min(T, 50)` percent
of the week, where `T` is all-models used. So:

- Guaranteed Fable room = `max(0, 50 - T)` percent of the week, which is `max(0, 100 - 2T)`
  percent of the Fable cap.
- Possible Fable room = up to the full cap, `min(50, 100 - T)` percent of the week.
- The picker uses only the guaranteed room. With `T = 41` the guaranteed room is 9 percent of the
  week (18 percent of the Fable cap). With `T = 55` it is 0, so the account is skipped for Fable
  with reason `Fable room not readable and not guaranteed above 50% weekly use`.
- As soon as a Fable reading exists, the exact value replaces the bound and the row says
  `source: probe`.

The menu shows a solid Fable meter when there is a reading. Only before an account's first Fable
reading does it draw the possibly-used span hatched and label the row "Fable: up to 82% used
(est.)". It never shows a single made-up number.

## 8. In-use detection

A session counts toward an account by the launch file its records name (4A.6). The default folder
is the only folder read in this version.

- Records are `sessions/*.json` (one per running session) and `jobs/*/state.json` in the default
  folder. The tool reads ids, names, state and launch file names from them and drops every other
  value as it reads. Other files there, such as `.key` files, are ignored. A missing `sessions/`
  or `jobs/` folder is an empty, clean read. A record that cannot be opened or read, is not a
  regular file (a link included), or is over 1 MiB makes the pass unclean.
- A `sessionId`, `resumeSessionId` or `jobId` is read only when it has the shape of a job folder
  name, which is the job id: 1 to 128 letters, digits, dots, underscores or hyphens, starting with
  a letter or digit. A record with any other id is treated as unreadable: the id is never printed
  or stored, the record's launch file names still count as named, and the pass is unclean. An
  entry of `jobs/` whose name has another shape, such as a hidden file, is not a job record.
- A session is live when its `sessions/<pid>.json` entry names a process that is alive. A live
  background session links to its job record by the entry's `jobId` (the `jobs/<jobId>/` folder)
  or an equal `sessionId`. A job whose state is finished, stopped, failed or similar never counts.
  Sessions are told apart by `sessionId`, so two sessions that share one launch file count twice.
- A record names a launch file when any string in it, after `\/` is unescaped, contains
  `launch/<label>/l-<8 hex>.json`, whatever the JSON shape. The label comes from that path, never
  from a field of the record or an environment variable. A live session whose records name no
  launch file counts toward the `login` account. One that names a label not in the config counts
  toward no account.
- The result is `inUse.count` and `inUse.sessions` (the first 8 characters of the session id and
  the scrubbed name, at most 80 characters), never prompts or paths. When the pass was unclean the
  row shows `inUse: { "count": null, "sessions": [], "unknown": true }` instead of guessing.
- When a live session's records name a launch file that does not exist, the label's row carries the
  warning `launch_file_missing` with a count (section 9). `doctor` lists those sessions by the
  first 8 characters of their ids.
- Not used: `claude agents --json` (it may start a supervisor), and reading other processes'
  environments (fragile, and close to snooping).

## 9. Errors and states

Row `state` is one of `ok`, `limited`, `error`, `ended`. Errors and warnings carry a code and a
short scrubbed text the menu shows as is.

| Code | Detected by | State | Menu text (example) |
|---|---|---|---|
| `login_rejected` | `auth status` says logged out, or the probe returns an auth error | error | "Login rejected. Run `agent-balancer login pool-b` in Terminal." |
| `wrong_account` | `auth status` email differs from config | error | "Folder is logged in as another account." |
| `duplicate_login` | two configured accounts report one email | error | "Logged in as the same account as pool-a. Log one folder into its own account." |
| `settings_changed` | a hook entry recorded at link time is gone or changed (5.7); or, after `init`, the hook record is missing or unreadable (4A.5) | error on every affected account, shown as one banner | "Settings changed. Run `agent-balancer link --accept-source-change` in Terminal." |
| `plan_changed` | `planTier` differs from `expectedPlanTier` | error | "Plan is max_5x, expected max_20x." |
| `account_ended` | `endsAt` passed; or, for an account marked `endingSoon`, the first reading where `planTier` differs from `expectedPlanTier` or is missing. Once ended that way it stays ended until `config set <label> ending-soon false` | ended | "Account ended." |
| `check_failed` | probe timeout, no `rate_limit_event`, unparsable output, `claude` missing | error | "Check failed: probe timed out after 60 s." |
| `limited` | probe status not `allowed`, or weekly or 5-hour use at or above `limitedAtPercent`; a full Fable sub-cap alone is the warning below | limited | "Limited until Wed 4:00 PM." |
| `fable_limited` (warning) | Fable use is readable and at or above `limitedAtPercent` of the Fable cap; only Fable picks skip the account | ok | "Fable limited until Thu 9:00 AM." |
| `login_expiring` (warning) | `loginExpiresAt` within 7 days; for a token account within 14 days of its estimated end (4A.4) | ok | "Login expires Dec 7." |
| `token_missing` | a token account whose token file is absent, is not a regular 0600 file owned by the user, or does not parse | error | "No token saved. Run `agent-balancer login pool-a` in Terminal." |
| `not_linked` | a folder account that was never linked (4A.5) | error | "Settings not shared. Run `agent-balancer link spare` in Terminal." |
| `possible_duplicate` (warning) | a token account whose weekly and 5-hour reset times both equal another account's (4A.4) | ok | "Same reset times as pool-a. If this is the same account, remove one." |
| `key_in_settings` (warning, no event) | the default folder's `settings.json` carries `apiKeyHelper` or an `env` name among the API key and token names, read by name only (4A.3) | ok | "Settings carry an API key or key helper. Token accounts are skipped." |
| `stale` (warning) | reading older than twice the refresh interval | ok | "Last read 2 h ago." |
| `launch_file_missing` (warning, no event) | a live session's records name a launch file that does not exist (section 8); the text carries a count only, never a session name or a path | unchanged | "1 live session names a launch file that is gone." |

A rejected login on an account marked `endingSoon` stays `login_rejected`, because the tool cannot
tell an ended subscription from an expired login, but its text says both. When several errors apply
to one account, the row shows the first of: `login_rejected`, `settings_changed`, `token_missing`,
`wrong_account`, `duplicate_login`, `plan_changed`, `check_failed`. An `endsAt` that has passed
beats all of them. `duplicate_login` compares the emails of every account in the config, a token
account's note included. An account in `error` or `ended` is never the `next` choice, and the
state of an account in `error` takes precedence over `limited`.

Every change of `state`, every error code that appears or clears (one `settings_changed` error
event per affected account, though the menu shows one banner), and the first sight of a
`login_expiring` warning is also appended to the events record (sections 10.3 and 13). Event types
are eight (10.3); every error code of this table travels as an `error` event carrying that `code`.

## 10. JSON schemas

All four JSON outputs (`status`, `pick`, `events`, `history`) carry `schemaVersion`. Additive
changes keep the version; removals or renames bump it. Times are ISO 8601 UTC. Percentages are
numbers 0 to 100 with one decimal.

### 10.1 `agent-balancer status --json`

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-09T21:10:00Z",
  "banner": null,
  "accounts": [
    {
      "label": "pool-a",
      "email": "pool-a@example.com",
      "role": "pool",
      "kind": "token",
      "fullLogin": false,
      "configDir": null,
      "accountKey": "key-pool-a",
      "endingSoon": false,
      "linked": null,
      "state": "ok",
      "stateSince": "2026-11-05T02:03:10Z",
      "limited": null,
      "error": null,
      "warnings": [],
      "planTier": "max_20x",
      "weekly":   { "usedPercent": 22.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe", "readAt": "2026-11-09T21:06:12Z" },
      "fable":    { "usedPercent": null, "guaranteedLeftPercentOfCap": 56.0, "possibleLeftPercentOfCap": 100.0,
                    "resetsAt": null, "source": "estimate" },
      "fiveHour": { "usedPercent": 9.0, "resetsAt": "2026-11-09T23:40:00Z", "source": "probe", "readAt": "2026-11-09T21:06:12Z" },
      "readingsAge": 228,
      "inUse":    { "count": 1, "sessions": [ { "id": "1a2b3c4d", "name": "build-worker-1" } ] },
      "endsAt": null,
      "loginExpiresAt": "2026-12-07T10:08:56Z",
      "loginExpiresSource": "estimate",
      "reserve": null
    }
  ],
  "next": {
    "all":   { "label": "pool-a", "reason": "Soonest weekly reset: resets Wed 6:00 PM." },
    "fable": { "label": "pool-a", "reason": "Soonest weekly reset: resets Wed 6:00 PM. Fable room guaranteed at 56% of cap." }
  }
}
```

Field rules:

- `role` is `main | pool`. `kind` is `login | token | folder` (4A.1). `fullLogin` is true for
  `login` and `folder`. `configDir` is the account folder for `folder` and null otherwise.
- For a token account `email` is the note typed at `add` (never checked), `planTier` is null, and
  `loginExpiresAt` is an estimate with `loginExpiresSource: "estimate"` (4A.4). No field ever
  holds a token or the path of a token or launch file.
- `banner` is null, or `{ "code", "text" }` for a problem of the whole setup. This version sets it
  for `settings_changed`, with the text "Settings changed. Run `agent-balancer link
  --accept-source-change` in Terminal.", or the "Hook record missing" text of 4A.5.
- `readingsAge` is the age of the account's reading in seconds, or null with no reading.
  `loginExpiresSource` is `estimate` for a token account, `auth` for a `login` account (from
  `auth status`), and null when no expiry is known. `inUse` is `{ "count", "sessions" }`, or with
  an unreadable record `{ "count": null, "sessions": [], "unknown": true }` (section 8).
- `state` is one of `ok | limited | error | ended`. `error` is null or
  `{ "code": ..., "text": ... }`. `source` is one of `probe | estimate | none`.
- `reserve` is present only on `main` accounts:
  `{ "linePercent": 63.3, "marginPercent": 5, "launchAllowed": true, "daysLeft": 4.0 }`.
- `fiveHour` is null when the plan has no 5-hour window.
- `stateSince` is when the tool first saw the current `state` with its error code (null before the
  first reading of an account that is `ok`).
  `limited` is null unless `state` is `limited`; then it is
  `{ "window": "weekly" | "fiveHour", "since": ..., "until": ... }`, where `since` is
  when the tool first saw the account limited and `until` is that window's `resetsAt`. The sample
  row shows the Fable fallback; with a Fable reading `fable.usedPercent` is a number, `source` is
  `"probe"` and the two bound fields are null. The rebuild keeps state, error code and since times
  in `state/current.json`, written under the history lock with the events line, so neither depends
  on retention. `limited.window` is the window whose reset frees the account: of the windows at or
  over `limitedAtPercent`, or named by a probe's rejected status, the one with the latest
  `resetsAt`. When `until` has passed and no new reading exists, the row stays `limited` until the
  next reading; `limit_cleared` comes from a reading, never from the clock alone. A full Fable
  sub-cap is the `fable_limited` warning, never a `limited` window (section 9).
- `planTier` is the plan tier `auth status` reports when it is 1 to 64 letters, digits, dots,
  underscores or hyphens, starting with a letter or digit. Any other value reads as unknown, the
  same as a missing one, so it is never stored or printed.
- Each account also carries `accountKey` (7.1), `endingSoon` and `linked` (true or false for a
  `folder` account; null for `login` and `token` accounts).
- The document carries a top-level `next` object (`label` is null when nothing fits),
  `{ "all": { "label", "reason" }, "fable": { "label", "reason" } }`, computed with the picker
  rules but without leases and without the main account's probe-source and age rules, so the menu
  header can show the next launch without running `pick`. `pick` confirms, and its answer can
  differ while a lease is open or the main account's probe is old.
- Error and warning texts are scrubbed of token-like strings, email addresses and ids before they
  are stored.

### 10.2 `agent-balancer pick --json`

Full form: `pick --json [--model <name>] [--settings <json>] [--full-login] [--caller typed|launcher] [--exclude <label>] [--dry-run]`.
A token account's answer:

```json
{
  "schemaVersion": 1,
  "pickedAt": "2026-11-09T21:10:03Z",
  "model": "fable",
  "label": "pool-a",
  "env": {},
  "args": ["--settings", "/Users/<user>/.agent-balancer/launch/pool-a/l-7f3a9c.json"],
  "launchPrefix": "",
  "launchArgs": "--settings '/Users/<user>/.agent-balancer/launch/pool-a/l-7f3a9c.json'",
  "unsetEnv": null,
  "backgroundOnly": false,
  "reason": "Soonest weekly reset with guaranteed Fable room: resets Wed 6:00 PM, Fable at least 56% of cap left.",
  "candidates": [
    { "label": "main",   "eligible": false, "reason": "Fable launches not allowed on the main account." },
    { "label": "pool-a", "eligible": true,  "reason": "Resets Wed 6:00 PM." },
    { "label": "pool-b", "eligible": false, "reason": "Login rejected." }
  ]
}
```

The same pick landing on a folder account differs in two fields:

```json
  "env": { "CLAUDE_CONFIG_DIR": "/Users/<user>/.agent-balancer/accounts/spare/.claude" },
  "launchPrefix": "CLAUDE_CONFIG_DIR='/Users/<user>/.agent-balancer/accounts/spare/.claude' ",
```

`model` echoes `--model`, or is `default` when the flag is absent. Reasons that callers may see in
`candidates` include `excluded by caller`, `ambient CLAUDE_CONFIG_DIR set`,
`settings carry an API key or key helper`, `token sessions have no connectors`, `no token saved`,
`login rejected`, `no weekly reading`, `window reset, refresh failed`,
`stale reading, refresh failed` and `Fable reading is stale, refresh failed`; their text is
informational and not stable. The `pick busy` refusal (lock not taken within 30 seconds) and every
refused flag or caller settings exit 1 with a message on stderr and write nothing.

`label: null` with `reason` when nothing fits (exit 2); then `env`, `args`, `launchPrefix`,
`launchArgs` and `unsetEnv` are null, `backgroundOnly` is false and no launch file is written.
`--model` takes `fable`, a Fable model id, or anything else (treated as all-models only). The
answer does not carry the kind, whether it is a full login, the readings age, the account key or
any organization grouping; `status --json` carries them per account (10.1). A caller applies
`env` and `args` (or the two typed strings) the same way for every kind and never branches on the
kind (4A.2).

Stable in schema version 1, promised to both callers (section 16): `label` (a string, or null when
nothing fits); `reason` (a string in every answer); `env` (on exit 0 an object of strings,
possibly empty; null on exit 2); `args` (a list of strings on exit 0, null on exit 2);
`launchPrefix` and `launchArgs` (the typed forms of the same two, each a literal string, possibly
empty, and both null under `--caller launcher`); `unsetEnv` (a list of names under
`--caller launcher`, null otherwise); `backgroundOnly`; the exit codes 0, 2 and 1; and the rule
that a recipe is returned only for an account that passed its kind's checks at pick time (4A.5).
`candidates` is required in every answer and is informational. A folder account is always linked
and every hook entry recorded for it is still present (5.7), so a caller can count on the shared
hooks.

Flags:

- `--settings <json>`: the caller's own settings for the session, merged into the launch file
  under the allowlist of 4A.2. A caller never passes `--settings` to `claude` itself.
- `--full-login`: offer only `login` and `folder` accounts (4A.5); a token candidate then shows
  the reason `token sessions have no connectors`.
- `--caller typed|launcher` (default `typed`): `launcher` turns off the ambient skips, fills
  `unsetEnv` and makes `launchPrefix` and `launchArgs` null (4A.3). Any other value exits 1.
- `--exclude <label>` (repeatable): leaves those labels out of this pick with the reason
  `excluded by caller`, for a caller whose own check refused a folder or whose worker just hit a
  limit there. There is no `release` command and no lease id in the answer: a caller that did not
  launch does nothing, and the lease lapses after `picker.leaseMinutes`.
- `--dry-run`: writes no lease, no launch file and no pick log line, and returns `candidates` with
  `label` and `eligible` for every account. The answer has `dryRun: true`, the chosen `label`
  when one fits (exit 0, or exit 2 when none), and `env`, `args`, `launchPrefix`, `launchArgs` and
  `unsetEnv` all null, because no launch file exists to name. It still refreshes stale readings
  and takes the pick lock.

### 10.3 `agent-balancer events --json`

Full form: `events --json [--after <seq>] [--since <time>] [--label <label>] [--type <type>] [--limit <n>]`.
The record of state changes. It answers "what changed since I last looked": the caller keeps the
`cursor` from its last call and passes it back as `--after`.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-09T21:10:00Z",
  "recordId": "r-4c1e9a",
  "cursor": 42,
  "oldestSeq": 3,
  "gap": false,
  "more": false,
  "events": [
    { "seq": 41, "at": "2026-11-09T19:02:11Z", "notBefore": "2026-11-09T18:01:40Z",
      "label": "pool-a", "type": "limited", "window": "weekly",
      "resetsAt": "2026-11-12T02:00:00Z", "text": "Limited until Wed 6:00 PM." },
    { "seq": 42, "at": "2026-11-09T20:15:03Z", "notBefore": "2026-11-09T19:14:55Z",
      "label": "pool-b", "type": "error", "code": "login_rejected", "window": null,
      "resetsAt": null, "text": "Login rejected." }
  ]
}
```

- `type` is one of eight: `limited`, `limit_cleared`, `error` (carries `code`, one of the section
  9 codes), `recovered` (an error cleared; `text` names which), `login_expiring`,
  `account_added`, `account_removed`, `token_replaced`. `possible_duplicate` and `key_in_settings`
  stay warnings with no event. A `settings_changed` error event is written once per affected
  account, though `status` and the menu show one banner. `launch_file_missing` writes no event.
  New types may appear; a caller skips types it does not know. A state change writes at most one
  event per account in one rebuild, chosen in this order: a new error code (`error`), a cleared
  error (`recovered`), `limited`, `limit_cleared`, then `login_expiring`. `account_added` and
  `account_removed` come from comparing `accountKey`s with `state/current.json`, so a renamed label
  writes none and a label removed and added again for another account writes both.
- `seq` rises by one per event. A damaged record (a line in the middle that does not parse, a
  `seq` that does not rise, or a missing header) is set aside as `events-damaged-<time>.jsonl`,
  starts a new `recordId`, and `seq` restarts at 1; there is no counter file. A line with a value
  the tool never writes (a label that does not match the label pattern of 5.2,
  `\A[a-z0-9][a-z0-9-]{0,31}\z`; a type, code or window outside its list; or a `seq` below 1 or
  at or above 10^12) counts as a line that does not parse, and a header whose `recordId` is not
  `r-` and six lowercase hex digits counts as a missing header; neither value is ever returned. Pruning
  (section 13) keeps each label's newest line, so `seq` can have gaps in the middle. Before the
  first rebuild
  `recordId` is null and `cursor` is 0. `cursor` is the `seq` of the last event this answer covers: when
  `--limit` cut the answer short it is the `seq` of the last event returned and `more` is true,
  and the caller calls again at once; otherwise it is the highest `seq` in the record, also when
  `events` is empty, and `more` is false. `oldestSeq` is the oldest event still kept (null for an
  empty record). `gap` is true when `--after` is below `oldestSeq - 1` (an event after the
  caller's cursor was pruned) or above `cursor`; the caller then reads `status --json` once and
  carries on from the new `cursor`. `--after 0` on a record that still holds seq 1 is not a gap.
- Each answer carries `recordId`, a random id made when `events.jsonl` is created: `r-` and six
  lowercase hex digits. A caller that sees a `recordId` it does not know treats that as a gap too:
  the record was started over.
- `--label` must match the label pattern of 5.2 and is never used to build a path otherwise;
  `--limit` is 1 to 1000. The same holds for `history` (10.4).
- `at` is when the tool first saw the change. `notBefore` is the time of the last reading that
  still showed the old state, or null. The real change lies between the two, so "limited since" is
  only as exact as the readings are frequent.
- `window` and `resetsAt` are set on `limited` and `limit_cleared` only. `login_expiring` is
  written once per expiry date.
- Events come oldest first, at most `--limit` (default 200). `text` is scrubbed like every status
  text; an event never holds an email, an organization id, a session name or a path. An empty
  answer is exit 0.

### 10.4 `agent-balancer history --json`

Full form: `history --json [--label <label>] [--since <time>] [--limit <n>]`. The readings over
time, for a chart or a burn-rate estimate.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-09T21:10:00Z",
  "accounts": [
    { "label": "pool-a",
      "readings": [
        { "at": "2026-11-09T20:06:12Z", "source": "probe", "state": "ok",
          "weekly":   { "usedPercent": 20.5, "resetsAt": "2026-11-12T02:00:00Z" },
          "fiveHour": { "usedPercent": 6.0,  "resetsAt": "2026-11-09T23:40:00Z" },
          "fable":    { "usedPercent": null, "resetsAt": null } }
      ] }
  ]
}
```

The rebuild step appends one line for an account when a number, a reset time or the state differs
from that account's last line, at most one line per 15 minutes unless the state changed, so a gap
means nothing was read. `--since` defaults to 24 hours back and `--limit` to 500 readings per
account (the newest ones, listed oldest first). `--since` takes an ISO 8601 time or a span such as
`30m`, `24h` or `7d`. Lines older than `history.retentionDays` (default 35, five weekly windows)
are dropped (section 13). With 0 no history line is kept and `history` answers with empty lists;
the events record then keeps only each label's newest line.

## 11. Menu bar

- **Icon:** the splitter tile. The app and README use `design/icons/splitter-tile-color.svg`; the
  menu bar uses `design/icons/splitter-tile-menu.svg`, a template image (black plus alpha, 18
  points) with the same silhouette and two lamps and without the chevrons, which blur at that
  size.
- **Header:** "Next launch: <label>" and "Next Fable: <label>" with reasons in small text (from the
  status document's `next`). The menu shows nothing about the main account's reserve line. The
  numbers stay in `status --json` as `reserve` (10.1) for a caller.
- **Empty and first-run states:** no config yet: one card "Run `agent-balancer init`" with a Copy
  button; config but no readings: rows say "Reading accounts" until the first probe finishes; CLI
  not found: an error card with the lookup paths tried; a status file with a newer
  `schemaVersion`: "Update agent-balancer". Never an empty window.
- **Finding the CLI:** the app looks only at `/opt/homebrew/bin/agent-balancer`, then
  `/usr/local/bin/agent-balancer`, after the same owner and mode test the runner applies to
  `claude` (6.2). No executable path comes from config.
- **Size:** the popover caps at the visible screen height minus 40 points and scrolls inside;
  every command shown has a Copy button. Open at login is a checkmark item in the menu, off until
  the user turns it on. The refresh interval is changed with
  `agent-balancer config set refresh.backgroundMinutes <n>` in a terminal; the app writes no file.
- **Rows:** one per account: label and email, role badge (main or pool), two thin meters (all
  models, Fable), reset times, an in-use marker with a count. Error rows show the error text and a
  fix action; an ending account shows "ends Nov 16". The row does not show the account's kind; the
  Manage accounts window does.
- **Text rule for every screen:** short labels. A ? icon beside a label shows one or two sentences
  on hover or keyboard focus, and only where the label does not explain itself.
- **Fable meter:** a solid meter from the Fable reading. Only before an account's first Fable
  reading: a hatched span for "possibly used" and the label "up to N% used (est.)" (7.4).
- **Actions:** Refresh now (runs `agent-balancer refresh`, shows progress, then the rebuilt status
  or the CLI's error text), Manage accounts, Open usage page (the one claude.ai usage URL, opened
  in the browser), Open at login, Quit.
- **Manage accounts window:** one ordinary window. While it is open the app shows the tool's icon
  in the Dock. Left: the account list with sign-in state and plus and minus buttons. Right: the
  panel for the selected account's kind.
  - *Token panel:* sign-in state and "Sign in again" (runs `agent-balancer login <label>`), the
    estimated token expiry, Ends, Remove.
  - *Folder panel:* sign-in state and "Sign in again" (runs `login <label> --browser`, which runs
    the documented `claude auth login --email <expected email>` in that folder and then checks the
    email with `auth status`), the folder path with Copy, shared-settings state, Ends, Remove.
  - The `login` account shows its sign-in state and role and has nothing to change here.
  - **Consent:** the window runs six command shapes only: `add`, `add --kind folder`, `remove`,
    `config set <label> ends|ending-soon`, `login <label>` (a token account) and
    `login <label> --browser` (a folder account). Remove asks for the label typed into its sheet.
    `link`, `unlink`, `config set-main`, `config clear-main`, a change of email or label, and
    removing a main account are not in the window: it shows the command with a Copy button, so
    everything that shares hooks or moves protection keeps its typed consent in a terminal (5.1).
    The app has no scripting surface, and it turns management off, with a one-line reason, when
    its own environment carries the chat-shell variable (5.1).
  - **No file writes:** every change is one CLI command, run with an argument array; a bar at the
    bottom of the window shows the last command and its result or error text.
  - **The same account, never another:** "Sign in again" appears only on a folder that is logged
    out, names the expected email and passes it as the pre-fill; the window has no field that
    changes an account's email.
  - **End date:** no end date; "Ending soon, date unknown" (`ending-soon true`); or "Ends on" with
    a date picker that takes today or later (`ends <date>`).
- **Look:** system font, vibrancy material, macOS menu spacing, light and dark from the system,
  hover highlight on rows, full keyboard navigation, VoiceOver labels on meters.
- **Data:** reads `~/.agent-balancer/state/status.json` and checks whether `config.json` exists; a
  file watcher updates the view when the CLI writes. It writes no file and never runs `claude`
  itself.

## 12. Install, update, uninstall

- **Install:** the CLI with Homebrew from the project's tap. The app ships as a zip attached to
  the GitHub release; the README gives the unzip, drag to Applications and Open Anyway steps.
- **First run, in this order:**
  1. `agent-balancer init [--label <label>]` creates `~/.agent-balancer/` (0700), reads the
     default folder with `auth status`, asks for that account's label (`--label` is required when
     not interactive), records the email `auth status` shows as its expected email, and writes
     `config.json` with that account as a `login` account with role `pool`. It also always writes
     the hook record (5.7).
  2. `agent-balancer refresh`, then open the app: the first account shows at once.
  3. `agent-balancer add <label> [--email <address>] [--ends <date>] [--ending-soon]` writes the
     registry entry of a `token` account and creates no folder (4A.4).
  4. `agent-balancer login <label>`, in Terminal: it runs `claude setup-token`, the browser opens,
     the person approves once, and the tool keeps the token and runs one probe under it.
     `login <label> --paste` is the fallback form.
  5. `agent-balancer status` shows the new account with its first reading.

  A token account shares the default folder, so its hooks, skills and trust are the ones the user
  already has. No account is protected until the user names one (`config set-main <label>`).

  A `folder` account is the later, optional path, for sessions that need the full login:
  `agent-balancer add <label> --kind folder --email <address>` creates an account folder and
  records the email that folder must log in as; `agent-balancer link <label>` (dry run, then
  apply) shares the config; `agent-balancer login <label>` starts `claude` in the new folder so
  the first `/login` and that project's trust prompt happen together. It is allowed only while the
  folder is logged out, refuses when the folder is not linked, and afterwards runs `auth status`
  and says whether the folder holds the expected email. `config set <label> email|ends|ending-soon|label <value>`
  changes one field with a dated backup. The tool never logs in for the user.
- **One account per folder, for good.** A folder is signed into one account and stays on it,
  because saved thinking from a model works only in the account that produced it, and a chat that
  meets a second sign-in loses it. `login <label>` runs only while the folder is logged out and
  checks the email afterwards. `add`, `login` and the README print "Never sign a different account
  into a folder that already has chats. Add a new folder for the new account instead." A folder
  found on another account shows `wrong_account`, drops out of `pick`, and its fix text says to
  sign the expected account back in, not to relabel the folder.
- **Unsigned app:** the README shows the unzip, drag and System Settings, Privacy & Security, Open
  Anyway steps. The app needs Open Anyway after the first install and again after each upgrade
  until it is signed.
- **Update:** `brew upgrade` for the CLI; the app is replaced from the new zip. Config carries
  `schemaVersion`; the CLI migrates forward and keeps a dated backup.
- **Uninstall, in this order:** `agent-balancer uninstall`, then delete the app from Applications,
  then `brew uninstall agent-balancer`. `agent-balancer uninstall` shows what the tool created
  (links, `links.json`, state, logs, the LaunchAgent if installed, with its `launchctl bootout`
  line), then removes its own files only after the typed word `uninstall` in the user's own
  terminal (refused in a chat shell, 5.1). Account folders and their logins belong to the user and
  are never deleted. Only `agent-balancer uninstall` deletes every token and launch file, after
  the typed word.

## 13. Data folder layout and permissions

```
~/.agent-balancer/                 0700
  config.json                      0600   user config (labels, kinds, emails, rules); never a token
  tokens/                          0700   token accounts only; excluded from backups
  tokens/<label>.json              0600   one setup-token as a settings file with env only (4A.4)
  launch/<label>/                  0700   launch files; excluded from backups
  launch/<label>/<leaseId>.json    0600   one per pick: label, the caller's allowlisted settings,
                                          and for a token account the token (4A.2); removed by the
                                          upkeep rule in 4A.6
  accounts/<label>/.claude/        0700   folder accounts only (section 5.1); the tool writes only
                                          the links listed in links.json
  links.json                       0600   link manifest: link, target, hook fingerprint at link time
  state/status.json                0600   last merged status (what the menu reads)
  state/readings/<label>.json      0600   last reading per account, with source and time
  state/picks.log                  0600   one line per pick: time, model, label or none, lease id
                                          or `-`, reason; no line for a dry run
  state/history/<label>.jsonl      0600   readings history, one JSON line per changed reading (10.4)
  state/events.jsonl               0600   a header line with the record id, then state changes, one
                                          numbered JSON line each (10.3)
  state/current.json               0600   each label's current state, error code and since times, the
                                          last sign-in and probe errors, the label the last duplicate
                                          check matched (4A.4), and what the settings file last showed
                                          (10.1; labels, codes, times and scrubbed text only)
  state/leases.json                0600   open leases (internal id, label, model, time), pruned
  probe/                           0700   one fresh temporary folder per probe, removed afterwards
  locks/probe-<label>.lock        0600   one probe at a time per folder
  locks/pick.lock                  0600   one pick decision at a time (section 7.2 rule 7)
  locks/history.lock               0600   one writer at a time for the history and events files
  logs/agent-balancer.log          0600   scrubbed lines from the status rebuild (rotation at 1 MB
                                          is not built yet)
  backups/config-<date>.json       0600   before every migration
```

The tool sets `umask 077` at start. The `Paths` module opens the data root and each subfolder with
`O_DIRECTORY | O_NOFOLLOW`, refuses one that is a link, not owned by the user, or wider than 0700,
and does every create, append, rename, lock and mode change relative to those folder handles
(`openat`, `renameat`, `fchmod`), with `O_NOFOLLOW` on the final name and `O_EXCL` on temporary
names chosen at random, so a planted symlink can never redirect a write. A refusal is logged and
the write is skipped. `unlink` and `uninstall` remove a path only when `lstat` shows a symlink
whose parent is a configured account folder under the data root and whose target equals the
recorded target; they never remove a regular file or anything outside the data root. Nothing is
written under `~/.claude` or any account folder except what the user approves in section 5.

Token and launch files are the one exception to "never remove a regular file": the tool made them,
so `remove`, a token replace, the upkeep rule and `uninstall` delete them, and only them: a path
directly under `tokens/` or `launch/<label>/`, opened through the same folder handles, that
`lstat` shows as a regular file owned by the user, the writer's own leftover temporary files there
included. `remove` also deletes the label's stored reading and its empty launch folder through the
same writer. A token file is written whole to a random temporary name in `tokens/` and renamed into
place, so a reader never sees half a token, and after a crash the token file is the old one or the
new one. A crash between the write and the rename can also leave the temporary file, which may hold
a whole token; the next `remove`, token replace or upkeep pass deletes it under the pick lock, and
`doctor` counts it until then (4A.4). Only the `Tokens` and `Launch` modules open these two folders
(4A.4). `status.json`, the history, the events, the pick log and the log never hold a
token or the path of a token or launch file; the pick log records the lease id.

The history and events files are append-only JSON lines with one writer, the status rebuild step,
which takes `locks/history.lock` before it reads any reading, lease or config file and holds it
until `status.json` has been renamed into place, so rebuilds run one at a time from start to end.
A rebuild that waits more than 30 seconds for the lock writes neither file and logs it. The
history step runs last, after the command's own result is written and printed; a failure in it is
logged and never changes that output or the exit code, so a damaged record cannot stop a `pick`.
A last line that does not parse is cut off under the lock and logged. An events line in the middle
that does not parse, or whose `seq` does not rise above the previous one, marks the file damaged:
it is written aside under a new name, a new record with a new `recordId` starts, and `seq`
restarts at 1. An events line with a value the tool never writes (a label that does not match the
label pattern of 5.2, `\A[a-z0-9][a-z0-9-]{0,31}\z`; a type, code or window outside its list; or a
`seq` below 1 or at or above 10^12) counts as a line that does not parse, and an events
header whose `recordId` is not `r-` and six lowercase hex digits counts as a missing header. A
history line in the middle that does not parse, or whose state or source the tool never writes,
is skipped. A `state/current.json` that does not parse, or holds a label, state, code, window,
plan tier or date the tool never writes, is logged and started over. Lines older than
`history.retentionDays` (default 35)
are dropped by rewriting the file through the same no-follow writer, at most once a day; the
newest events line of each label is always kept. The files hold labels, percentages, times, states
and scrubbed texts only: no email, no organization id, no session name, no path. With five
accounts and the 15 minute floor of 10.4 they stay under about 5 MB. The rebuild after
`remove <label>` writes an `account_removed` event and leaves that label's history to age out.
`uninstall` removes the files with the rest of `state/`.

## 14. Threat model

**Assets:** (1) Claude logins (Keychain entries and fallback files), which the tool never touches,
and the setup-tokens it stores for token accounts, (2) account emails and usage numbers, (3) the
integrity of the shared hooks and settings that apply to every session, (4) the user's weekly
capacity, (5) release artifacts, (6) the machine (no network exposure).

T1 below is the rule list the safety script enforces on `Sources/`: Security or Keychain API;
network API; `http` literals except the one usage-page URL constant in a single named file of the
app; `.credentials.json` or `.claude.json` names; `Process`, `NSTask`, `posix_spawn`, `system(`,
`popen`, `execv` or `dlopen` outside the `Runner` module; file reads (`contentsOf`, `FileHandle`,
`fopen`, `open(`) outside the `Paths` module; environment reads outside the `Env` module;
`security ` or `curl` strings; a non-example.com email or organization id in `Sources/`,
`Tests/`, `docs/` and `skill/`; the attribution phrase rule; the Claude Code token variable name
or any path built under `tokens/` or `launch/` outside the `Tokens` and `Launch` modules; and any
file deletion outside the no-follow writer.

| # | Threat | Mitigation |
|---|---|---|
| T1 | The tool reads or leaks a credential it was never given | No code path opens the Keychain, `.credentials.json` or `.claude.json`. The one credential it holds, a token account's setup-token, is covered by T20 to T23. The safety script enforces structure, not behavior; tests cover the rest |
| T2 | A token-like string lands in output or logs (for example echoed in a `claude` error) | The scrubber's token pass works on whole captured buffers after the size cap and before parsing, so a token split across two reads is still caught. A second pass (email addresses, UUIDs, `/Users/<name>`) runs only on stderr, error texts and log lines, never on the JSON fields the readers map. The leak test plants canaries in every input |
| T3 | Network exfiltration or telemetry | No networking code; the safety script fails if `URLSession`, `Network` or socket APIs appear; the only network user is the `claude` binary |
| T4 | Command injection through config | `Process` with argument arrays only, never a shell; labels and folders must match the patterns in 5.2, and folders must be owned by the user |
| T5 | A fake `claude` earlier on `PATH` | The runner looks for `claude` only in the fixed list in 6.2 and refuses a binary whose real target is not owned by the user or root, or is writable by group or others; `doctor` shows the path |
| T6 | A shared settings link gives chats a second path to edit the settings that apply to every session | Section 5: where links live, and the user's own path rules for settings files |
| T7 | Probe runaway spends capacity | Lock per account folder, the reading-age skip rule (6.2), `--max-budget-usd 0.05`, timeout |
| T8 | Two callers pick the same account at once | `pick` decides and writes its lease under an exclusive lock (7.2 rule 7), so the next pick sees the first one |
| T9 | Supply chain | One dependency (swift-argument-parser, pinned to an exact version); Dependabot; pinned action SHAs; release checksums in the formula; attestations at public release |
| T10 | Wrong account logged into a folder | Email and plan check on every refresh; `wrong_account` error; `pick` skips it |
| T11 | Files readable by others | 0700 and 0600, `umask 077`, mode check on write |
| T12 | An inherited key, token or ambient `CLAUDE_CONFIG_DIR` reaches a child | Allowlisted child environment (6.2); `pick` skips the default-folder candidate under an ambient variable, unless the caller is a launcher that sets the child's environment itself (5.2) |
| T13 | A chat forges consent through a pseudo terminal | Consent commands, `run` and `login` refuse in a chat shell (5.1); the user's own policy can also refuse those commands in chats |
| T15 | Public docs or history leak private labels, paths or tooling details | This document is public-safe; issue bodies, PR text and release notes pass a local banned-string list before they are posted |
| T16 | A same-user process, a chat included, edits files under `~/.agent-balancer/` to skip consent, pass `verify`, move the main role, drop the reserve, forge a reading, or make the tool run a program of its choosing | No executable path is read from any file in the data folder; the `verify` cache lives in process memory only; config changes that move protection (`set-main`, `set`, `remove`) refuse in a chat shell. Against code that runs as the user this is advisory |
| T17 | A planted symlink redirects one of the tool's writes or deletes | No-follow, handle-relative writes and symlink-only removal (section 13) |
| T18 | The history and events files expose usage patterns, or a same-user process forges or deletes lines to mislead a caller | 0600 files that hold labels, percentages, times and scrubbed texts only; a retention cap; the leak test reads both files. The files are information, never authority: `pick` and `verify` decide from live checks and never read the history |
| T19 | A chat uses the Manage accounts window to add, remove, re-date or sign in an account: it starts the app itself, or drives the window by scripting the screen | The window runs six command shapes only and none that shares hooks or moves protection; it turns management off when its environment carries the chat-shell variable; the app has no scripting surface |
| T20 | A stored token is read by another process that runs as the user, by a backup or by a sync tool, and stays usable for up to a year | 0600 files in 0700 folders; `tokens/` and `launch/` are marked as excluded from backups; `doctor` warns when the data folder sits inside a synced folder. Against code that runs as the user this is advisory, and it is the same exposure as Claude Code's own fallback credential file |
| T21 | A token reaches output: `pick`'s JSON, an error text, a log line, the history, the app, a crash report | Only the `Tokens` and `Launch` modules read a token, and they return paths, never values. `pick` prints the launch file's path only. The scrubber runs on every captured buffer; `TokenCapture` reads the `claude setup-token` child's raw output first |
| T22 | A caller's settings JSON carries a key that switches hooks off, changes permissions or chooses another account, into a launch file not visible in the typed line | `pick` accepts only allowlisted top-level keys (`env` by default) and only `env` names listed in `launch.envNames` (empty by default), never the protected names such as `CLAUDE_CONFIG_DIR`, `PATH`, `NODE_OPTIONS`, proxy and certificate variables, and refuses without writing anything (4A.2) |
| T23 | Launch files pile up, each with a token, or one outlives its account | The upkeep rule in 4A.6; `remove` deletes every file of the label; a token replace rewrites them; `uninstall` removes both folders; `doctor` prints the count and the oldest age, never a file's content |
| T24 | Something in the caller's environment beats the recipe: a worker bills another account, or lands in a folder with no hooks | The ambient rule (4A.3): folder-only picks under an inherited `CLAUDE_CONFIG_DIR`, `backgroundOnly` under an inherited token, `unsetEnv` for launchers. The post-launch check in section 16 item 4 catches a launch that landed in the wrong folder |
| T25 | A folder account with a missing link runs sessions with no hooks | `pick` runs `verify` on a folder account before every recipe and refuses on any broken or missing link, and a never-linked folder is always refused; `run` refuses the same way |
| T26 | Any chat that can run `pick` learns the path of a file that holds a token, and can read it; a token session can print its own token | Not prevented by the tool, and said so. Same-user limit as T16 and T20: the user's own policy is the boundary. The README Limits section gives a deny-rule snippet for `~/.agent-balancer/tokens/` and `~/.agent-balancer/launch/` |

Threat numbers are not reused or renumbered.

## 15. Testing

- **Unit (Core):** picker tables (every row of 7.3, Fable bounds in 7.4, end dates, ties, nothing
  fits), config validation, stream parser on recorded events (allowed, limited, missing window,
  garbage), scrubber.
- **Test framework:** Swift Testing (`import Testing`), never XCTest (Build settings). `swift test`
  runs with `HOME` set to a temporary folder, and each test that touches the data folder gets its
  own temporary home, because Swift Testing runs tests in parallel.
- **Fake `claude`:** a small executable that answers `--version`, `--help`, `auth status` (exit 0
  logged in, exit 1 logged out, both with JSON) and `-p` from a scenario file: logged in, logged
  out, wrong email, plan changed, 401, timeout, no `rate_limit_event`, Fable window present. Tests
  place it at `.local/bin/claude` under the temporary `HOME`, the first entry of the runner's fixed
  list, and one test asserts the runner resolved the fake. No automated test calls a live `claude`.
- **Leak test:** `Tests/CLITests/LeakTests.swift` plants a canary of each shape (an OAuth-shaped
  and an API-key-shaped token, a non-example.com email, a UUID organization id, an organization
  name, a `/Users/<name>` path, and a second OAuth-shaped token in the shape spike S14 recorded
  for a real one: 108 characters with dashes) in every input a later slice adds (fake `claude`
  stdout and stderr, an extra `auth status` field, the probe `result` error text, a `settings.json` `env`
  value, the parent environment, a token file's value, fake `setup-token` output, a pasted token,
  a caller's settings JSON). It runs every command against every scenario, collects stdout,
  stderr, logs and written files, and fails on any canary outside a token file and that label's
  launch files, on any token-like match, and on any email outside `example.com`. A canary split
  across two 4 KB reads is still caught. A positive control proves the detector fires. Planted
  tokens and planted safety violations are assembled at runtime from split strings, never stored
  whole in a file.
- **Safety script tests:** `scripts/check-safety.sh` is tested with planted violations for each
  rule, assembled at runtime in a temporary tree. The script passes on the real tree.
- **Fixtures:** probe and auth fixtures are recorded from real runs, then scrubbed and relabeled
  to `example.com`; unit normalization (0 to 1 versus 0 to 100) has its own tests.
- **Golden JSON:** `status --json`, `pick --json`, `events --json` and `history --json` outputs for
  fixed scenarios, so schema changes show up in review.
- **History and events:** transition tables (ok to limited and back, each error code appearing and
  clearing, `login_expiring` once per expiry date, an account added and removed), the `notBefore`
  rule, `cursor`, `oldestSeq` and `gap` after pruning, retention, the 15 minute floor, and two
  rebuilds racing for the lock without a lost or doubled `seq`.
- **Caller flag tests:** `pick --caller launcher` returns `launchPrefix: null`; without the flag,
  under an ambient `CLAUDE_CONFIG_DIR`, the default folder is skipped; any other `--caller` value
  exits 1; `--exclude <label>` never returns that label; a lease dated in the future is dropped.
- **Contract tests for both callers:** every exit 0 `pick` output carries `label`, `env` and
  `args`; `args` is exactly `--settings` and a path under `launch/<label>/` that exists with mode
  0600; `env` holds `CLAUDE_CONFIG_DIR` exactly for a folder account; the typed strings render the
  same two values; every exit 2 output has them null and wrote no file; `pick` never returns a
  folder that fails `verify`, a token account with no token file, a login account that is logged
  out, or a never-linked folder account.
- **Recipe and launch file tests:** the launch file of each kind holds the label, the token only
  for a token account, and the caller's settings merged. Each refused caller setting (a key off
  the allowlist, an `env` name not in `launch.envNames`, a never-allowed name such as a proxy,
  certificate, `PATH` or `NODE_OPTIONS` name even when listed, a non-string value, more than
  16 KB, not an object) exits 1, writes nothing and names the key in its text, never the value.
  The upkeep rule removes an unclaimed file after `leaseMinutes` and keeps one a live session
  names. `--full-login` never returns a token account.
- **Ambient tests:** one row of the 4A.3 table each, plus a planted settings file with
  `apiKeyHelper` or a key name in `env`.
- **Hook record tests:** after `init` the record exists, empty for a user with no hooks; a deleted
  or unparsable record fails `login` and `token` accounts with `settings_changed` and the "Hook
  record missing" text; `link --accept-source-change` with `accept` restores it.
- **Token tests (fake `claude setup-token`):** capture writes the token file with mode 0600 and
  prints no token; `--paste` reads without echo and never from an argument; a wrong shape is
  refused; replace rewrites the file and every launch file of the label and writes one
  `token_replaced` event; `remove` deletes both; the duplicate warning fires on two accounts with
  equal reset times, on any probe, and not otherwise; `token_missing` on a deleted or widened file.
- **Safety tests:** no network APIs linked; no forbidden file names in the source; file modes are
  0600 and 0700 after every command.
- **Human smoke list (each release):** install from the tap in a fresh macOS virtual machine or on
  a second Mac, with Claude Code installed and one test account logged in; `init`; `add` an
  account and log in; `status` shows it; log it out and see `login_rejected`; `pick` with and
  without `--model fable`; the menu shows rows, meters and the error row in light and dark; the
  Open Anyway steps match the README; the uninstall dry run lists everything.

## 16. The contract callers use

This tool keeps its own job and outputs, and the caller builds everything that uses them. One
contract serves any orchestrator, the skill file that ships for other people's Claude (4A.7) and
any program, and it covers both ways of applying a recipe (4A.2). `docs/CONTRACT.md` is the
public copy.

1. **Pick before every launch:**
   `agent-balancer pick --json --model <model> [--settings '<your settings JSON>'] [--full-login]`,
   with a command timeout of at least 90 seconds (`pick` may refresh stale readings for up to 45
   seconds and wait up to 30 seconds for the pick lock). Exit 2: do not launch; leave the item
   waiting and show `reason`. Exit 1: no pick; report the error. Exit 0: a recipe.
2. **Apply the recipe, the same way for every account:**
   - **Typing caller:** type `<launchPrefix>claude --bg <your own flags> <launchArgs> '<prompt>'`
     as one literal line. Copy the two strings exactly; never rebuild them, wrap the line in a
     script or use a substitution. When `backgroundOnly` is true the line must be a `claude --bg`
     launch.
   - **Launcher:** add `--caller launcher`. Start `claude` with your own environment, minus every
     name in `unsetEnv`, plus every entry of `env`, and with `args` after your own flags, as an
     argument array. Never paste any of it into a shell string.
3. **Never:** pass your own `--settings` to `claude` (give it to `pick`); branch on the account
   kind; open, copy, print or keep a launch file or anything else under `~/.agent-balancer/`;
   build a folder or file path yourself; reuse a recipe. One pick is one launch, within
   `leaseMinutes`.
4. **Check the launch:** `<launchPrefix>claude agents --json` lists the new session, matched by
   its session id, not by its presence in the list (a launcher runs the same check with the
   environment of item 2, never an inherited one). A short worker may have finished before the
   check, and the plain list shows finished background sessions only with `--all`. If the session
   is missing, the launch did not land where the recipe pointed: stop launching onto that label
   and report it.
5. **If you did not launch** after an exit 0 pick (your own check refused it, the launch or its
   check failed, or your timeout fired after the answer): do nothing about the lease, which lapses
   after `leaseMinutes`; pick again, with `--exclude <label>` for a label you refused or one that
   just hit a limit.
6. **Need the full login?** A session that needs claude.ai connectors, Remote Control or the
   claude.ai skills asks with `--full-login`. Token accounts cannot give those.
7. **Read state** with `agent-balancer status --json --cached` for every periodic read: it reads
   saved readings only, starts no child process and never spends a model call. Plain
   `status --json` may run `auth status` and never probes (only `refresh` and `pick` probe). Never
   parse the menu or logs.
8. **What changed:** `agent-balancer events --json --after <cursor>`. Keep the `cursor` from each
   call and pass it back, and call again while `more` is true. A `recordId` you have not seen
   means the record was started over: treat it as a gap. On `gap: true`, read `status --json`
   once and carry on from the new `cursor`. `status --json` carries `stateSince` and `limited`
   (`since`, `until`, `window`), and `agent-balancer history --json --label <label>` gives the
   readings over time.
9. **Information is not authority:** decide a launch from `pick`, never from `events`, `history`
   or an old `status`.
10. **Stable in `schemaVersion: 1`** (new fields may appear, and none of these change or go away):
    in `pick`, the fields and flags that 10.2 lists as stable, `--exclude`, `label` and `eligible`
    in `candidates`, the exit codes, and the promise that a recipe is returned only for an account
    that passed its kind's checks at pick time; in `status`, the fields of 10.1; in `events` and
    `history`, the fields of 10.3 and 10.4. `docs/CONTRACT.md` and the golden-output tests are the
    checked copy.
11. **Per kind, for whoever sets accounts up** (a caller does not need this to launch): `login` and
    `token` sessions share the default folder, so they have one trust list, one list of
    background sessions, working messages between sessions, and the user's own hooks, skills and
    MCP servers. A `folder` session has its own trust list (a person opens `claude` there once per
    project, or a `--bg` launch can stall), only the MCP servers and plugins added in that folder,
    and it can report to a session in another folder only through a file (5.2).
12. **Separate callers** are serialized only by the pick lock and the lease: launch within
    `leaseMinutes` or pick again.

Notes for the caller's side: the caller's own policy must allow `--settings <launch file>` in a
typed line; its launch check must ask the supervisor the recipe points at, not the default one;
its messaging features must work with workers that can report only through a file when they sit in
a folder account; and a caller that itself runs on a token account gets `backgroundOnly: true` on
every pick, while one inside a folder account is offered only folder accounts by a typed pick
(4A.3).

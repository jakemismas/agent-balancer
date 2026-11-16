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
   keys. `run` and `link <label>` never open it: they use the verdict those readers save (4A.5).
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

`scripts/check-safety.sh` scans `Sources/` for rules 1, 2, 4, 7, 9 and 10 as text, checks that only
the readers rule 3 names open the settings file, and scans
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
      Paths/       data folder, account folders, 0700 and 0600 enforcement, no-follow writer (NoFollowWriter.swift, the only file the safety scan lets write or delete), `FileStamp` (a stat of a path: device, inode, size, modification and change time, never an open)
      Runner/      Process with an argument array (never a shell), timeout, output size cap,
                   scrubber on every captured byte. `ClaudeRunner.runSetupToken` runs
                   `claude setup-token` with the person's environment and hands the raw output
                   once to a callback of the `Tokens` module before it scrubs the remainder.
                   `ClaudeRunner.launchAttached` starts `claude` for `run` with the terminal's own
                   input and output and the person's environment minus the protected group (6.2).
                   `CLIRunner` starts the agent-balancer tool for the menu app: found only at
                   `/opt/homebrew/bin` and `/usr/local/bin`, owner and mode test of 6.2, the probe
                   environment, never `claude`. `ChildProcess` is the one capture-and-timeout loop
                   both runners share
      Readers/     auth status reader, probe reader (stream-json parser), sessions reader
                   (`SessionsReader`: the default folder's `sessions/` and `jobs/` records, section 8)
      Readings/    reading cache (state/readings/<label>.json), the merge rule of 6.3, and the
                   refresher that runs probes under a lock per account
      Env/         the one shared group of protected environment names (6.2)
      Picker/      pure function: (config, readings, now, model) -> PickResult; `RunService.swift`
                   adds `PickService.prepareRun`, the checks, lease and launch file of `run`
      Accounts/    AccountKind (login, token, folder): each kind's checks, probe context and
                   recipe parts; the only place that branches on kind
      Launch/      launch files: caller settings allowlist, merge, lease, upkeep (`Upkeep`, 4A.6)
      Status/      `StatusBuilder`: merges readings, sign-in checks and in-use sessions into the
                   status document and rebuilds `state/status.json` (sections 10.1 and 13)
      Doctor/      `DoctorChecks`: the launch file count and oldest age, and the synced-folder test,
                   both used by the `doctor` command (the other checks stay in the command)
      Uninstall/   `Uninstall`: the plan `uninstall` lists and the removal after the typed word,
                   built on the uninstall steps of `TokenAccounts`, the listed-link removal of
                   `HookRecord` and the name rules of section 12 (`Uninstall.OwnNames`)
      Tokens/      the token file: `TokenStore` (read, save, delete), `TokenCapture` (the capture and
                   the shape check), `TokenAccounts` (install, replace and remove under the pick
                   lock, with the launch files rewritten or deleted through `Launch`)
      History/     append-only readings history (`ReadingHistory`), state-change events
                   (`EventLog`), the rule that turns a change of state into one event
                   (`Transitions`), and the `events` and `history` answers (`Queries`)
      Scrub/       token-like string redaction used by Runner and the logger
      ViewModels/  what the menu app shows, with no UI code: `StatusSnapshot` (a lenient reader of
                   `status.json` and `StatusReader`, which reads it and checks `config.json` through
                   the no-follow reader), `MenuBuilder` (the row, header, banner and empty-state
                   models, the tip texts, the time and percent formats) and `MenuController`
                   (launch refresh, the refresh timer, the `status --cached` poll, Refresh now)
    agent-balancer/          CLI (swift-argument-parser)
      Commands/    one file per command: Init, Doctor, Config, Link, Refresh, Pick, Status, Events,
                   History, Add, Login, Remove, Run, Uninstall, and the `Shared` helper that ends a writing command with the status
                   rebuild
    AgentBalancerBar/        SwiftUI MenuBarExtra app (window style, LSUIElement): the views, the
                             palette of design/render.html, the template icon, `UsagePage.swift`
                             (the one http literal), and the render flags of the same binary:
                             `--render <dir>` (each view at 2x, light and dark, flat materials) and
                             `--iconset <dir>` (the app icon sizes); both write through the
                             no-follow writer, into a folder under the current folder's
                             `build/` that is written without `..`, has no link on its path,
                             has no folder named `.claude` or `.agent-balancer` (in any case)
                             below the current folder, and is not inside the home's `.claude`
                             or `.agent-balancer`; any other folder exits 1 and writes nothing.
                             A HOME that is set but empty, is not an absolute path, or has a
                             `..` segment stops every render.
                             Each home must be a folder, and its `.claude` and
                             `.agent-balancer` missing or a folder (a link to one included): a
                             link to nothing, a link loop, a link to a file or a file there
                             exits 1 before anything is made, since a run could make the
                             folder such a link names. The folder is
                             opened once, one name at a time with no link followed, and each
                             file is written relative to that handle after a check that every
                             name still names the folder opened and that neither it nor a
                             folder above it is one of the home's tool folders as they
                             resolve at that moment; a folder swapped part way, or a tool
                             folder that comes to name it, stops the run. The render scenes
                             hold made-up data only: `RenderScenes.swift` and
                             `Manage/ManageScenes.swift` draw the frames of design/render.html,
                             and `ReadmeScenes.swift` holds the three status documents the
                             README pictures are drawn from. Tests rebuild each row of
                             `Manage/ManageScenes.swift` and of the two documents the Manage window
                             draws through the status writer's own build, and the README test
                             checks the menu document's rows against the writer's rules as it
                             states them
  skill/agent-balancer/SKILL.md   the skill file for a user's Claude (4A.7)
  scripts/check.sh           the test command: typecheck, format lint, tests, the safety scan
                             (`scripts/check-safety.sh`), the README check, the secret scan
  scripts/build-app.sh       build/AgentBalancerBar.app: release build, hand-made bundle, iconutil
                             icon, ad hoc signature, no Xcode; it refuses a written Info.plist
                             that declares a scripting, URL, service, document or extension key
  scripts/render-views.sh    builds the app and the CLI, runs the render flag into
                             build/renders/ (an older render of a README picture is deleted
                             first), copies the three README pictures that run drew, light and
                             dark, into docs/media/ and runs the README check with that CLI
  scripts/check-readme.sh    the README check. README.md holds only printable ASCII and tabs. The
                             check reads every inline code span of README.md and every line of a
                             fenced code block (three or more backticks or tildes, closed only by
                             a run of the same mark at least as long) except a json block, with a
                             leading `$ ` or `% ` prompt dropped. A fence closes before the list
                             item that holds it ends: a line that is not blank and is indented
                             less than the opening fence ends it, and a fence that ends there or
                             at the end of the file without closing fails. A json block parses as
                             JSON (read by `osascript` with JavaScript, which ships with macOS),
                             and each key and each string of the parsed value is read as a later
                             part of a chain, so a key that appears twice is read with its last
                             value only. Each span or line is cut into parts at &&, ||, ;, & and |
                             (a | before a flag is a choice in a usage line), each $(...) or
                             backtick substitution is a part of its own, and quotes, backslashes
                             and parentheses read as spaces. The first part starts with
                             agent-balancer, claude, brew, gh or mkdir, or is one word naming a
                             path, file or key. In every part but a claude, brew, gh or mkdir
                             line, each word agent-balancer, and a path to it that starts the
                             part, begins a command whose subcommand and flags are in its --help.
                             No code span runs across a line break, no code, pre, kbd, samp or tt
                             HTML tag is used, and no flag sits in plain text, where
                             agent-balancer followed by spaces or tabs and a word fails unless
                             that word is on the check's word list. Each local file that an
                             inline link or picture, or a src or srcset attribute, names exists.
                             The pictures carry no compressed chunk, and their metadata chunks
                             hold no absolute path of two or more parts (also right after a URL's
                             scheme and host), home path (`~/`, `~user/` or `$HOME/`), address
                             outside example.com, org id or token. The scene sources the pictures
                             are drawn from (`ReadmeScenes.swift`, `ManageScenes.swift`,
                             `RenderScenes.swift`) name accounts only by the labels main,
                             personal, lab, spare-a and spare-b; every word with a letter in
                             their strings and comments, lowercased and ISO times aside, is a
                             label or on the check's word list; and they hold only those labels'
                             example.com addresses, each with at most one leading hyphen, and the
                             fixture's paths. When the local
                             banned-string list is present, neither the metadata nor the scene
                             sources may hold a banned string. With no binary given, it builds
                             the CLI when the CLI is missing
  docs/media/                the README pictures, PNG, light and dark, of made-up accounts only
  CONTRIBUTING.md            tools, build and check, the safety rules the scan enforces, issue
                             first, landing, license
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
stays `scripts/check.sh` and the install check stays unchanged. `scripts/check.sh` runs the README
check (`scripts/check-readme.sh`), and `scripts/render-views.sh` runs it again after it copies the
pictures.

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
`status` and `refresh` never read the default folder's settings file (rule 3). Of the commands
that read it (`init`, `doctor`, `pick`, `verify` and `link --accept-source-change`), all but
`doctor` pass what they saw, the hook record status and whether keys are present, to the rebuild,
and `link <label>` passes what the saved verdict says; the rebuild keeps it in
`state/current.json` and carries it over for every rebuild that did not read the file. In the same way a sign-in check
(`status` and `refresh` run `auth status` for each login and folder account) and a probe
(`refresh`, `pick`) each pass their result, and a rebuild that observed nothing carries the last
error over unchanged, so `status --cached` never invents a recovery. The rebuild that records a
probe's `login_rejected` dates it to the stored reading it reads, or to its own second when it
has none it can read and decode, and never earlier than the latest reading the status had seen;
while the rejection stands, no rebuild moves that time back. A rebuild that sees a stored reading
newer than that time clears the rejection. A probe that works with a newer reading clears it
only when its rebuild has no stored reading it can read and decode: while it reads one, that
reading decides, because a stored reading older than the probe's own puts the order in doubt (a
clock set back, or a file put back). One probe clears it whatever the times: the first check of
a token that `login` saves, when it works and the rebuild that records it saves
`state/current.json` (4A.5). `refresh` probes again an account whose sign-in
a probe found rejected, as the status records it, even when its reading is fresh (6.2).
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

- One JSON object of at most 16 KB, with no `__proto__`, `constructor` or `prototype` key at any
  depth and no nesting deeper than 8.
- Top-level keys only from `launch.settingsKeys` in config. The default is `["env"]`. The list
  may hold only `env` and `crossSessionInbound` (a string, such as `"accept"`), so a caller
  cannot switch hooks off, run a command, set a key helper or change permissions through a file
  that is not visible in the typed line, whatever else the config lists.
- Inside `env`: string values only, and every name must be in `launch.envNames` in config and
  match `^[A-Z][A-Z0-9_]{0,63}$`. The default is `[]`, so a caller passes no `env` name until the
  user lists some, such as `CLAUDE_ROLE` and `CLAUDE_CLIENT`. These names are never allowed,
  whatever the list says: the protected group with its login locations (6.2), every
  `CLAUDE_CODE_*` name (the chat marker included), `CLAUDE_JOB_DIR` and `CLAUDE_PID`, any
  `AGENT_BALANCER_*`, `PATH`, `HOME`, `NODE_OPTIONS`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, the
  other certificate, shell start-up, language load path, XDG folder, temporary folder, editor
  and pager names that `CallerSettings` lists, any name that starts with a loader or
  tool prefix (`DYLD_`, `LD_`, `GIT_`, `NODE_`, `BASH_`, `LC_`, `NPM_`, `BUN_`, `DENO_`, `SSH_`,
  `AWS_`, `GOOGLE_`, `AZURE_`, `OTEL_`), and any name ending in `_PROXY` in either case. An `env`
  entry sits in the same file as the token, so a caller-chosen proxy, certificate file, loader
  or `PATH` could read or run with it.
- One check holds both lists to these rules, when the config loads and again at pick time, so a
  config that lists a refused key or name fails every command that loads it, with the list's
  name and never a value.
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

`run` is a launcher of its own kind: its argument array is `--settings <launch file>`, then the
person's arguments, and its printed line is `claude`, `launchArgs`, then the person's arguments
quoted. The settings pair comes first so nothing the person typed can take it or turn it into
prompt text, and a value-taking option or a second double dash after it cannot reach it. `run`
refuses, before it writes anything, a `--settings` in the person's arguments (`--settings` or
`--settings=...`, because a recipe carries exactly one) and a first argument that is a `claude`
command name such as `auth` or `mcp` (it would act on the default login, not start a session).
`run --print-command` is a typing caller: it applies the ambient rule (4A.3), the rule for an
inherited credential name, and the two refusals of a typed line (a name that switches hooks off
or that chooses the stored login) through the same predicates as a typed `pick`, and refuses for
that label, writing nothing, when any of them applies.

`pick` never launches and never prints a token. In schema version 1 a recipe is returned only for
an account that passed its kind's checks at pick time (4A.5).

### 4A.3 The ambient rule

A recipe is applied on top of the caller's environment, and that environment can beat it. An
inherited `CLAUDE_CONFIG_DIR` chooses the folder and its supervisor. An inherited token beats a
stored login in a foreground launch and does not reach a background worker. A token in
`--settings` reaches a background worker. Each rule fails closed:

1. `pick --caller typed` (the default) offers a prefix-less candidate (`login` or `token`) only
   where the caller's own folder is shown to be the default one. A `folder` account is always
   offered, because its literal prefix overrides whatever the caller holds. The `login` and
   `token` candidates are skipped when any of these holds, judged from variable and file names
   only (never a file's content):
   a. `CLAUDE_CONFIG_DIR` is set, empty included: reason `ambient CLAUDE_CONFIG_DIR set`.
   b. `CLAUDE_JOB_DIR` is set and is not exactly `<home>/.claude/jobs/<one segment>`, checked as
      text (absolute, no `.` or `..` segment, no link resolved), in any shell: reason
      `ambient session folder not default`.
   c. The shell is a chat shell (5.1) with neither variable set, unless a file named
      `<CLAUDE_PID>.json` (`CLAUDE_PID` all digits) is found by name in the default folder's
      `sessions/` and in no folder account's `sessions/`: reason `chat folder not confirmed
      default`. A missing or non-numeric `CLAUDE_PID`, an unreadable `sessions/` and two matches
      all skip.
   With no candidate left, `pick` exits 2. `run --print-command` uses the same predicate, and
   `doctor` prints one line for the session folder (`default`, `folder <label>` or
   `not confirmed`), by label only. It names a folder account only for a `CLAUDE_CONFIG_DIR` that
   is exactly the account's folder, or a `CLAUDE_JOB_DIR` that is exactly
   `<account folder>/jobs/<one segment>`, checked as text like rule b (absolute, no empty, `.` or
   `..` segment, no link resolved). A launcher caller and a shell that is not a chat with neither
   variable set are unchanged. The tool never sets `CLAUDE_CONFIG_DIR` to the default path.
2. `pick --caller typed` with a credential name in its own environment answers with
   `backgroundOnly: true` for every kind, a folder pick included. The caller uses that recipe only
   with `claude --bg`. Otherwise `backgroundOnly` is false. A credential name is one that carries
   a credential or chooses the account a session bills (`ProtectedEnv.carriesCredential`): the
   Claude Code token variable, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and the other API key
   and token names, `ANTHROPIC_CUSTOM_HEADERS`, every `CLAUDE_CODE_OAUTH_*` name, the token file
   descriptor names (`*_FILE_DESCRIPTOR`), the base URLs (`ANTHROPIC_*_BASE_URL`,
   `CLAUDE_CODE_API_BASE_URL`, `CLAUDE_CODE_CUSTOM_OAUTH_URL`, `ANTHROPIC_UNIX_SOCKET`), the
   profile and federation names (`ANTHROPIC_PROFILE`, `ANTHROPIC_CONFIG_DIR` and the
   organization, workspace, identity and scope names), every `CLAUDE_CODE_USE_*` provider name,
   the host credential names, and the login locations of 6.2. A name that is protected but
   carries no credential, such as `CLAUDE_CODE_SUBAGENT_MODEL` or `ANTHROPIC_MODEL`, which a chat
   shell carries, changes no answer.
3. `pick --caller launcher` skips nothing and returns `unsetEnv`: a fixed list, less
   `CLAUDE_CONFIG_DIR` when `env` sets it, plus every protected name (6.2), `CLAUDE_JOB_DIR`,
   `CLAUDE_PID` and `CLAUDE_CODE_*` name the caller's environment holds. The fixed list is
   `CLAUDE_CONFIG_DIR`, the Claude Code token variable, `ANTHROPIC_API_KEY`,
   `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`,
   `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_USE_MANTLE`, the two
   stored-login names of rule 5, the hooks-off names and settings sources of rule 6,
   `CLAUDE_JOB_DIR` and `CLAUDE_PID`. The launcher removes those from the child's environment.
4. The tool never suggests unsetting a variable in a typed line.
5. `pick --caller typed` refuses, exits 1 and writes nothing when its own environment holds
   `CLAUDE_SECURESTORAGE_CONFIG_DIR` (empty included) or `CLAUDE_CODE_CUSTOM_OAUTH_URL`. Claude
   Code names the Keychain entry of the stored login from these ahead of `CLAUDE_CONFIG_DIR`, so
   a folder prefix does not override them and no kind is safe on that line. The refusal names the
   variable, never its value.
6. `pick --caller typed` refuses, exits 1 and writes nothing when its own environment holds a
   name that may switch hooks off: `CLAUDE_CODE_SIMPLE`, `CLAUDE_CODE_SAFE_MODE`,
   `CLAUDE_CODE_PERSONAL_HOOKS_OFF`, `CLAUDE_CODE_RESTRICTED`,
   `CLAUDE_CODE_RESTRICT_PERSONAL_CONFIG`, a settings source (`CLAUDE_CODE_MANAGED_SETTINGS_PATH`,
   the policy folder; `CLAUDE_CODE_REMOTE_SETTINGS_PATH`, the remote settings override file;
   `CLAUDE_CODE_MOCK_REMOTE_SETTINGS`), or any other `CLAUDE_CODE_*` name that holds `SIMPLE`,
   `SAFE`, `RESTRICT` or `HOOKS`, so a name a later version adds is still refused. Policy
   settings outrank the launch file, so a settings source can switch hooks off where the line
   cannot be seen. No measurement says a background worker ignores such a name. A launcher
   removes all of them (rule 3), and `run` drops them from the person's environment (6.2).

| Case | `pick --caller typed` | `pick --caller launcher` |
|---|---|---|
| Nothing inherited | Every kind competes; `backgroundOnly` false | Same; `unsetEnv` is still returned |
| `CLAUDE_CONFIG_DIR` inherited | Only `folder` accounts; `login` and `token` skipped with `ambient CLAUDE_CONFIG_DIR set` | Skips nothing; `unsetEnv` lists `CLAUDE_CONFIG_DIR` unless `env` sets it |
| Credential name inherited (rule 2) | Every kind competes; `backgroundOnly` true for every kind | Skips nothing; `unsetEnv` removes the variables from the child |
| Both inherited | Only `folder` accounts; `backgroundOnly` true | Skips nothing; `unsetEnv` removes both |
| A stored-login name inherited (rule 5) | Refused: exit 1, nothing written | Skips nothing; `unsetEnv` lists both names |
| A hooks-off name or settings source inherited (rule 6) | Refused: exit 1, nothing written | Skips nothing; `unsetEnv` removes it |
| `key_in_settings`: the default folder's `settings.json` carries `apiKeyHelper`, or a credential name of rule 2 or `CLAUDE_CONFIG_DIR` (which renames the stored login's Keychain entry) in its `env` | Every account skipped with `settings carry an API key or key helper`: `login` and `token` sessions run in the default folder, and a `folder` account is skipped too, since a linked folder shares that file | Same |
| The default folder's `settings.json` carries a hooks-off name or a settings source of rule 6 in its `env`, by its exact spelling | Every account refused with `settings_changed`, as for `disableAllHooks` (4A.5) | Same |

Recorded manual checks behind this rule (2026-11-10):

- An inherited `CLAUDE_CONFIG_DIR` picks the folder, so a `login` or `token` recipe applied under
  it lands in the wrong folder. This is why typed callers keep only `folder` accounts (rule 1).
- A token in `--settings` reaches the worker's own requests: a bad token gave "API Error: 401
  Invalid bearer token". A foreground session passes a settings env variable to its Bash child. A
  `--bg` worker does not.
- `claude setup-token` was run through a pipe; the token shape and capture rule are in 4A.4.
- Not measured: which account a `--bg` worker bills when a valid token is in `--settings`, and how
  an inherited API key changes billing beyond the 401 behavior above. The rule therefore assumes
  the worst case: an inherited key or token marks every answer `backgroundOnly` (rule 2), and a
  launcher removes the variables (rule 3). If the open check shows the default login billed,
  token accounts become foreground-only for launches.

`init` and `doctor` look for the settings case by name only, never by value, with the same parse
as the hook record (5.7), and warn `key_in_settings` (section 9). The `env` scan checks only the
credential names of rule 2, `CLAUDE_CONFIG_DIR`, and the exact hooks-off and settings source names
of rule 6, never the whole protected group, so a harmless name such as
`CLAUDE_CODE_SUBAGENT_MODEL`, or a timing name that only holds one of the words of rule 6, skips
no account.

What the read rule leaves unseen. The settings read takes only hook entries, `disableAllHooks`,
whether `apiKeyHelper` is present and the names of `env` keys (rule 3 of the binding design
rules). So `forceLoginMethod`, `forceLoginOrgUUID`, `awsAuthRefresh`, `awsCredentialExport` and
`gcpAuthRefresh` in the default folder's settings are never seen, and a sign-in method or cloud
credential command they choose is outside every check. The working folder's project and local
settings are never read either (5.1).

### 4A.4 The token kind

Adding: `add <label> [--email <address>] [--ends <date> | --ending-soon]` (kind `token` unless
`--kind` says otherwise), then `login <label>`. `--ends` and `--ending-soon` together are refused
and nothing is written: an account keeps one end marker (7.1).

1. `add` writes the registry entry, and deletes a reading another account left under the label
   (6.3). `--email` is a note for the person. The tool shows the
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
   is the default and `--paste` is the fallback. A pasted or captured token must have
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
4. Duplicate check: if, after that probe, the new account's weekly reset time equals another
   account's, both still ahead, and so does its 5-hour reset time when both accounts have one (an
   idle account has none, so the weekly time alone decides then), `login` warns
   `possible_duplicate` and names the other label. It is a warning, not an error, because two
   accounts first used in the same hour could match. `pick` still treats them as two accounts and
   skips neither for it, the main account included; like threat T16, the check is advisory
   against code that runs as the user. The check runs in the reading cache's
   `afterProbe` hook, so it runs on every probe of a token account, at `login` and after it, and a
   token file swapped for another account's token shows as `possible_duplicate`. The status keeps
   what the last check found until the account's next probe checks again; the warning writes no
   event.

Expiry: a setup-token lasts one year. The tool shows `tokenCreatedAt` plus 365 days (the token
file's last change when the account has no `tokenCreatedAt`) as `loginExpiresAt` with `loginExpiresSource: "estimate"`, warns `login_expiring` 14 days before, and
shows `login_rejected` when a probe gets an auth error.

Replacing: `login <label>` on an account that already has a token. The new token replaces the file
in one rename, every live launch file of that label that carries a token is rewritten with it, and
a `token_replaced` event is written. A tombstone (below) is never revived, and a launch file that
carries no token, such as one that a pick of a renamed `login` account left under its old label
(Renaming, below), never gains one. A launch file that does not parse never
keeps the old token: one a session record names becomes a tombstone, and any other is deleted. The
replace lists the label's launch files again under the pick lock before it finishes, so a file that
a pick wrote during the rewrite is not missed, and the writer's leftover temporary files in
`tokens/` and that label's launch folder are deleted. A running or sleeping session keeps the token it
started with until its process restarts. The tool then says, every time, that the old token may
keep working until its year ends, because no way to cancel one is documented. Whether a new token
ends the old one is not yet known; a manual check at the token-path checkpoint records the answer,
and until then the text holds either way.

Every token save, a first one included, deletes the label's stored reading, under the pick lock
and the label's probe lock and before the token file is written, so the first check (step 3)
stores a reading of the new token's reply alone, with nothing read under another token merged in
(6.3). A first save after `add` finds none, since `add` deletes a reading left under the label. A
first save after the token file went missing while the reading stayed, as after a restore from a
backup that left out `tokens/`, which is excluded from backups (Where a token may be, below),
deletes the old token's reading. When the first check works, it also ends a probe's rejection
recorded before that check, whatever the reading times, once the status rebuild that records the
check saves `state/current.json` (4A.5). Only a replace writes
`token_replaced`.

Removing: `remove <label>` never refuses because a session still names a launch file. Removing
the main account needs a person at a terminal (5.1): with standard input not a terminal, `remove`
of a main account exits 1 and changes nothing. Under the pick lock it first reads the config again
and checks that rule once more, before anything is written or deleted, and stops, writing nothing,
when the label now names another account than the one it read (another `accountKey`). When another
`remove` of the label finished while it waited, it finishes what is left, as a rerun does. Every
command that saves the registry (`init`, `add`, `login`, `refresh`'s plan record, `config set`,
`config set-main`, `config clear-main`) saves under the same lock, so through the tool neither the
role nor the account behind the label can change between that check and the last delete; the
entry is deleted only while it still has the `accountKey` the check saw, and otherwise the remove
stops and keeps it. A process that edits `config.json` directly takes no lock and is outside this
guarantee (section 14, T16). Then it works in this order: (a) a launch file of the label that a
session record names, or whose lease has not ended, or any launch file when the records cannot be
read cleanly, is overwritten with a tombstone, and every other launch file of the label is deleted;
(b) the label's leases are deleted; (c) the launch files are listed again and (a) is repeated for
any file a `pick` wrote meanwhile; (d) every remaining file is read back, and when one still holds
a token the remove stops and keeps the token file and the account; (e) the writer's leftover
temporary files in `tokens/`, `tokens/<label>.json` and the stored reading are deleted; (f) the
config entry is deleted last, still under the pick lock, and the rebuild that follows writes the
`account_removed` event. A crash after any step leaves a state that `remove <label>` finishes on a
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
the new label. It refuses on a folder account the same way, because the account's folder is named
for the label: "A folder account cannot be renamed: its folder is named for the label. Nothing was
changed." On a `login` account it changes the label in the registry and, under the pick lock and
both labels' probe locks (6.3), moves what the tool keeps for the account under its label: its
stored reading goes to the new label, where it replaces a reading stored there before (none is
left there when the account has none), and none stays under the old label, so the account is
judged by its own newest reading or by none, a rename back included; and its open leases go to the
new label, so a pick made before the rename counts for the account (7.2 rule 7). Before it saves
the registry, it reads the reading and the leases and deletes a reading stored under the new
label, which no account holds; it moves the reading and the leases only once the registry is
saved, so a rename that the save refuses, such as while another folder account's folder is wider
than 0700, exits 1 and moves nothing. A reading file that it cannot read stops it before it changes
anything, and it prints the reader's refusal, such as `Refused to read main.json: it is not a
regular file.` for a folder where `main.json` belongs. A launch file that a pick made before the
rename stays where it was written while its lease is open, and a session started from it keeps the
old label in its environment. A token saved later under the old label is never written into such
a file, which carries none (Replacing, above), and `remove <old label>` keeps it as a tombstone
while its lease is open, as it keeps the label's own (Removing, above), so a session that starts
from it after that fails to sign in. When the account removed under the old label is a `folder`
account, whose remove keeps no launch file for an open lease (5.1), that file goes with the
label's own unless a session record names it or the records cannot be read cleanly, and a session
that would start from it finds no settings file. The account's history lines follow its
`accountKey` (10.4), and an account added later under the old label starts with no reading, no
lease and none of those lines.

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
| `token` | The token file exists, is a regular file owned by the user with mode 0600, holds a token that parses, and its last probe did not end in an auth error. While its probe's `login_rejected` stands and the status has seen its latest reading (only a probe that works stores a newer one), it is skipped as `login rejected` before any probe, even on a fresh reading. `pick` and `run` read the rejection again under the pick lock right before they decide, `pick` after its sign-in checks there, and `pick` also skips the account when its own probe, still running at its deadline, ends with an auth error before the pick decides (6.4). A rejection whose command has not finished its status rebuild by then is not seen, nor is the pick's own probe while it still runs. The rejection ends once the status sees a stored reading newer than the time the rejection is dated to (section 4), or, when the rebuild has no stored reading it can read and decode, records a probe that works with a newer reading (a `refresh` probes it again, 6.2, and so does `login` when it saves a new token). A `login` that saves a new token also ends it once its first check of that token works, whatever the reading times, in the status rebuild that records that check: the rejection was recorded before that check, of the token it replaced or of the new token by a probe that ran between the save and the check, and `login` holds the label's probe lock from that check until the rebuild has run, so no later probe's rejection is ended by it. So a rejection dated to a reading stored while the wall clock ran ahead keeps the token out, once the clock is set right, until the clock passes that time, even when the token works again; a `login` with a new token whose first check works brings the account back at once, once that rebuild saves `state/current.json`. When that rebuild is skipped at its 30 second wait for the history lock, saves no `state/current.json` or fails, nothing stored marks the check, so a rejection dated ahead of the clock stands, `pick` and `run` keep the token out, and the account comes back with another such `login` whose rebuild saves the file, or with a stored reading newer than the rejection once the clock passes its time; one dated at or before the clock ends at the next rebuild, which sees the check's newer stored reading. Otherwise the order of probes is judged by reading times, and no rebuild moves a standing rejection's time back, so neither a reading file put back in an older form nor an older working probe whose rebuild lands late after the wall clock is set back ends it while the stored reading can be read. Two routes remain. With the wall clock set back before a rejection, a reading or a working probe from before the step that no rebuild had seen can look newer than the rejection, when the stored reading cannot be read at the rebuild that records the rejection or at that probe's own late rebuild. And a process that runs as the user can write a reading newer than the rejection, or hide one no rebuild had seen while the rejection is recorded and put it back later (T16). A `state/current.json` that cannot be read, is of another schema version or is unsound counts as no rejection |
| `folder` | `verify` passes (5.7): every link in the manifest is intact and no hook entry recorded at link time is gone. A folder account must be linked, always: a never-linked folder is refused with the reason `not linked`, because a folder without the shared settings runs with no hooks. A user with nothing to share still runs `link` once; it records an empty manifest |

`init` always writes the hook record of the default folder, empty when there are no hooks. A
`login` or `token` account is refused with `settings_changed` when a recorded hook is later gone
or changed, or hooks are switched off: by the `disableAllHooks` flag, or by a hooks-off name or a
settings source of 4A.3 rule 6 in the file's `env`, by its exact spelling. Every account, a
`folder` account included, is refused with `key_in_settings` while the file carries
`apiKeyHelper`, or a credential name of 4A.3 rule 2 or `CLAUDE_CONFIG_DIR` in its `env`. After
`init`, a missing or
unreadable record fails these
accounts too, with `settings_changed` and the text "Hook record missing. Run
`agent-balancer link --accept-source-change` in Terminal." A record that holds a fingerprint or
command hash other than 64 lowercase hex digits counts as unreadable, so no other value of it is
ever printed.

`run` runs the `login` and `token` checks above without the reading check, and it never opens the
default folder's `settings.json`. It takes the settings checks from the verdict a reader saved
(`state/settings-seen.json`): the hook entries, whether hooks are off (the flag or such an `env`
name), whether the settings carry a key,
and the stamp of the file (device, inode, size, modification time and change time, for the path and
for what it resolves to). `init`, `doctor`, `pick`, `verify` and `link --accept-source-change`
save it, only when the stamp is the same before and after their read; they are the only readers of
the file (rule 3). `run` stats the file, never opens it, and compares the stamp and the live hook
record. It refuses with `settings_changed` and the text "Settings changed since the last check.
Run `agent-balancer doctor` in Terminal." when the verdict is missing, unreadable, malformed or
older than the file's stamp, or when the stamp cannot be taken. A settings path that no reader can
make usable gets a text that names the fix, since running `doctor` alone cannot clear it: a link
that goes nowhere (a link to nothing, or a loop) refuses with "The default folder's settings file
is a link that goes nowhere. Repair the link or remove it, then run `agent-balancer doctor` in
Terminal.", and a folder or special file there with "The default folder's settings file is not a
file. Replace it with a file or remove it, then run `agent-balancer doctor` in Terminal." A hook
record that is missing or changed gives the texts above. Every account is refused with
`key_in_settings` when the verdict says the settings carry a key. A change time cannot be put back
by an ordinary call, so a same-size edit with the modification time restored still refuses. Every
settings edit therefore makes `run` refuse until a reader records it again. This verdict is not the
`verify` cache of 5.7.

`pick --full-login` offers only `login` and `folder` accounts, for a session that needs
connectors, Remote Control or the claude.ai skills. Without it every kind competes on the picker
rules of section 7.

### 4A.6 Readings and in-use under each kind

- **Probe:** one probe per account under any kind. `login`: the 6.2 probe as written. `token`:
  the same plus `--settings <token file>`. `folder`: the same with `CLAUDE_CONFIG_DIR` in the
  child's environment.
- **Fable:** a Fable request adds the window `seven_day_overage_included`, which is the Fable
  weekly meter. A Fable probe reads it, and `fable.probe` is true by default. One costs roughly 20
  to 35 cents as the CLI prints it, so it runs once a day per account, before a Fable pick whose
  Fable reading is older than that, or when all-models use has risen by
  `fable.recheckAfterWeeklyRisePercent` (default 5) since the reading, or when the Fable window
  has reset. The rise and reset rechecks wait at least 10 minutes after the last Fable probe
  counted as tried, so a failing probe is not repeated on every pick. A Fable probe counts as
  tried only once its command takes its result (6.2). One still running when its pick rebuilds
  the status, or when its command's process ends, as when the menu ends a `refresh`, is not
  counted, and neither is one whose reading or time a file error keeps from being saved: it runs
  again at the next Fable pick, and at the next `refresh` once a day has passed since the last one
  counted. A pick for another model runs no Fable probe at all; `refresh` runs one once a day by
  that count. A Fable probe has its own
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
   folder. It has front matter with a name and a one-sentence description. It tells a user's
   Claude to read with `status --json --cached`, to run `pick --json` before every launch, to apply
   `env` and `args` (or the typed strings) the same way for every account, to give its own
   settings to `pick --settings` and never to `claude`, never to branch on `kind`, never to open a
   launch file, and to use `--full-login` when a session needs connectors. A test greps for each
   of those commands and rules, and the banned-string check covers the file. The README gives the
   one line that links it into the user's skills folder (slice 11). The tool itself never writes
   inside `~/.claude`.
2. **Versioned JSON output.** `schemaVersion` fields, the golden-output tests and
   `docs/CONTRACT.md`, the public copy of section 16: both kinds of caller, the exit codes,
   `--exclude`, `--full-login`, the fields stable in schema version 1, `events` and `history`, and
   the rule that information is not authority. It says `configDir` is not a contract field and
   names no orchestrator, guard or client.
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

`link <label>` lists every link, its resolved target and what `lstat` shows at the destination,
then asks for the label typed back before it changes anything (`--dry-run` stops after the list).
It links whichever of `settings.json`, `CLAUDE.md`, `skills/`, `agents/` and `commands/` exist and
never anything else. A run again adds links for sources that exist by then and leaves the rest.
`link --repair <label>` replaces a link the tool made whose recorded target has moved and removes
one whose source is gone, after the same typed approval. `unlink <label>` removes a listed link
only while it is still a symlink with the recorded target, then forgets the account's entries, so
the account counts as not linked. In this version `sharedSource` must be the default folder,
because the hook record covers that folder's settings; any other value makes `link` refuse. A
folder is also refused when it is a link or is not owned by the user. `remove` on a folder account
deletes the registry entry, the label's launch files (a recent pick's file included, because none
holds a token) and its leases, forgets the label's manifest entries, and never touches the folder.

Consent commands (`link`, `unlink`, `link --repair`, `link --accept-source-change`, `uninstall`,
`config set-main`, `config clear-main`, `config set`, `remove`) refuse to run in a chat
shell, so a chat cannot type the label through a pseudo terminal. `run` and `login` never start
`claude` in a chat shell either. `run` there prints the command to type in your own terminal,
`agent-balancer run <label> -- <arguments>`, and writes nothing. The Manage accounts window (section 11) runs `add`, `remove`
(of a pool account), `config set <label> ends|ending-soon` and `login` for a person who clicks,
and it turns itself off when the app's own environment carries the chat-shell variable.

Applying a change also needs a person at a terminal. `link <label>` and `link --repair <label>`
(after the list), `link --accept-source-change [--all]` (after the printed hook entries) and
`unlink <label>` check that standard input is a terminal before they ask for the typed label (or
the word `accept`), and refuse before the prompt, writing nothing, when it is not: "Applying needs
an interactive terminal. Run this in your own terminal and type the label (or `accept`) when
asked. Nothing was changed." Piping the label in does not count. The check is one closure
(`isatty` on standard input) with no variable, flag or file that turns it off. `remove <label>` of
a main account uses the same check: typing the command in a terminal is its consent, so with no
terminal it refuses before it changes anything and says to run `agent-balancer remove <label>` in
Terminal (4A.4). The menu app runs the tool with a pipe as standard input, so the window cannot
remove a main account through the tool, including a role or label change saved at the same moment
(4A.4); only a process that edits `config.json` directly is outside that. A pool account's
`remove` needs no interactive terminal, and `--dry-run` changes nothing and needs none either, but
both still refuse in a chat shell, since `remove` and `link` check for one before they act on a
flag or read a file. An editor's integrated terminal (only `CLAUDECODE` set) passes. `init` and
`uninstall` ask through the same prompt helper and are unchanged: `init`
checks for a terminal itself when it must ask for a label, and `uninstall` keeps its typed word
without this check.

While the person reads the list, nothing is locked. After the typed answer, `link`, `link
--repair` and `unlink` take `locks/links.lock`, read the account's entries and its linked mark
again and write only if they equal what the list was built from; otherwise they refuse, writing
nothing, and say to run the command again (the approval was for that list). `link` and `link
--repair` also check the default folder's settings verdict again under that lock (5.7).
`link --accept-source-change` does the same with the default folder's hook record, and reads the
settings again to check they are still the ones it showed. `remove` and `uninstall` only clear
entries and check nothing against the list; `uninstall` reads the session records, the lease
window and every file again once it holds the pick lock (section 12).

The chat-shell test is `CLAUDE_CODE_CHILD_SESSION` present with any value, empty included. Claude
Code sets it in the subprocesses of its shell tools, hook commands and status line commands, and
IDE extensions do not set it, so it tells a nested session from a top-level `claude` in an
IDE-integrated terminal. `CLAUDECODE` alone is the wrong test, because IDE extensions set it in
their integrated terminals. The refusal message is "Run this in your own terminal, outside a
Claude Code session." Neither the tool nor its README ever suggests unsetting a variable.

**Accepted residuals of the launch file.** A token account's setup-token sits in the launch
file's `env`, so the launched session holds it and exports it to the subprocesses of its shell
tools, hooks and status line commands (threat T26). A misbehaving session can print it into its
own transcript, outside the tool's two homes. Whether Claude Code removes that variable from
subprocess environments is not measured. The tool also writes `disableAllHooks: false` into every
launch file, so a project or local settings file cannot switch hooks off for that session, but it
does not read the working folder's settings (the sacred read rule), so a project `apiKeyHelper`
or `env` entry there is out of scope. A person who works in a folder with project settings
reviews them in `claude` itself. The same read rule leaves `forceLoginMethod`,
`forceLoginOrgUUID`, `awsAuthRefresh`, `awsCredentialExport` and `gcpAuthRefresh` in the default
folder's settings unseen (4A.3), and the profile base folders `HOME` and `XDG_CONFIG_HOME` stay
in a person launch and a typed line (6.2).

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
value fails everywhere (for a folder account it also rejects, at every save, a folder that is a
link, is wider than 0700 or is not owned by the user, and a data folder path that is not
absolute, has a `.` or `..` segment or fails the folder pattern; a folder that does not exist
yet passes; the save is the only place the validator runs this rule, and every use of the folder (`link`, `verify`, `pick`, `run`, `login`) opens it without following a link and refuses a folder that is a link or not owned by the user). A save that finds such a folder refuses for every account until it is fixed, and its error names the account and the fix: make the folder mode 0700 and owned by you, or run `agent-balancer remove <label>`. Every printed command goes through one renderer. `--model` only
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

`verify <label>` prints each failure with its code and exits 1 when any check fails (a login or
token label is refused: it verifies folder accounts only). Check 4 compares the folder that
`auth status` reports with the account's own folder after links are resolved; a reported value
with a `.` or `..` segment never matches. The runner redacts long random-looking runs in what it
captures, so a `[redacted]` marker stands only for text inside one path segment and never matches
a `/`. Every segment without a marker must match literally. The reported value must be an
absolute path with as many segments as the folder, a last segment with no marker, and at least
one other segment with no marker. In any other segment a marker stands for at least one
character, two markers side by side for at least one each, and the text between markers must
appear in that order, so a marker never matches an empty run. The label segment (the one before
the last) tells two account folders apart, so a marker there matches only when the scrubber turns
the account's own label into exactly that segment: a label of 32 or more characters that the
entropy rule redacts, or one that holds the token prefix (`sk-ant-`, the shortest run the
redaction replaces). A label the scrubber leaves as it is never matches a marker. A
`configDirectory` that is missing, empty, not a string, not absolute, only markers or short of
segments counts as a failed check 4 for a folder account ("Check failed: the folder of this
sign-in could not be confirmed." or "...the sign-in is not in this account's own folder."), so
`pick`, `run`, `login` and `verify` all refuse.

The expected login of check 4, and of the `login` kind's check in 4A.5, is the account's expected
email. The installed client's `claude auth status --json` (read as text in version 2.1.325, never
run) always prints `loggedIn`, `authMethod`, `apiProvider`, `analyticsDisabled`,
`projectsDirectory`, `configDirectory` and `loginExpiresAt`; for a stored claude.ai sign-in
(`authMethod` `claude.ai`, which a `login` or `folder` account has) it adds `email`, `orgId`,
`orgName`, `subscriptionType`, `storedClaudeAiLogin` and `planTier`, with `email` null when the
client holds no account record. The email names the account, so an account with an expected
email fails the check when the report carries a different email (`wrong_account`) or none at
all (`check_failed`, "Check failed: the sign-in reported no email, so it could not be confirmed
as this account."). The tool reads no other identity field: `orgId` is an organization id, which
never leaves `auth status` (binding rule 6), and `loginExpiresAt` is the stored sign-in's end, not
the account. For an account with no expected email, only the plan tier (`plan_changed`) can mark
a wrong account. Check 2 also fails a shared source (`settings.json`,
`CLAUDE.md`, `skills/`, `agents/`, `commands/`) that exists in the default folder, by `lstat` with
no read, while the manifest lists no link for it; the failure is the broken-link text, and
`link --repair <label>` (or `link <label>`) adds the link after the same typed approval. Repair
still refuses, writing nothing, when the source is a link that goes nowhere, is not owned by you
or is not a plain file or folder, or when the destination in the account folder is in the way;
each refusal names the item to fix (in the default folder or in the account folder) and says to
run the same command again, and the broken-link text says so too. A folder whose
manifest has no `settings.json` link is not hit by a hook change, because it loads none of those
hooks. Failures map to these texts: never linked, `not_linked` ("Settings not shared. Run
`agent-balancer link <label>` in Terminal."); a broken link or target, `settings_changed` ("A
shared link is broken. Run `agent-balancer link --repair <label>` in Terminal. If repair refuses, fix the item it names, in the default folder or in the account folder, then run it again."); a changed hook
set, `settings_changed` with the `--all` text of section 9.

`run` and `login` use `verify --no-reading` (checks 1 to 4), so a new account can be started
before its first reading. For the default folder, `run` takes check 3 from the saved verdict of
4A.5 and does not read `settings.json`; that verdict is a file, and is not the cache above. Missing, stale or unreadable counts as failed. `link --repair` re-links
only after the same typed approval. `link <label>` and `link --repair <label>` take the settings
verdict when they build the plan and refuse to ask while it fails; after the typed label, under
the links lock and before any link changes, they check it again and refuse, changing nothing,
when it now fails or is no longer the verdict the plan was built with (another stamp included),
as they refuse when the account's links or its linked mark changed. A changed hook set is
re-accepted only with `link --accept-source-change`, which prints the hook entries added and
removed (event, matcher and command hash, never the command text, which can hold secrets) and
whether `disableAllHooks` is present before asking for the typed word `accept`. After the typed
word it reads the settings again and records nothing when they differ from what it showed, or
when the hook record changed meanwhile. `unlink` removes nothing when the links it listed, or the
linked mark, changed before the typed label. `unlink` checks no settings verdict: it only removes
links, so no settings reach a folder through it, and the folder then counts as not linked. With
no label it re-accepts the default
folder's record; `--all` adds every linked folder. `status` and the menu show one banner,
"Settings changed" (section 9), instead of one error row per account, and the events record still
holds one `settings_changed` event per affected account. `verify` reads `settings.json` only to
parse the hook entries and that flag; it never logs or stores the file's content.

The default folder is never linked (5.1) and never counts as `not linked`. It still has hooks to
lose, and every `login` and `token` session runs in it. So `init` and
`link --accept-source-change` record the hook fingerprint of the default folder's `settings.json`
in `links.json`, and check 3 runs on it as on every linked folder. `init` always writes the
record, an empty one when the user has no hooks. After `init`, a missing or unreadable record
fails these accounts with `settings_changed` and the text in 4A.5. The check compares command
strings only, so editing the script a command points to is not seen.

## 6. Usage readings

### 6.1 Sources, cheapest first

| Source | Gives | Cost | When |
|---|---|---|---|
| `claude auth status --json` | Logged in or not, email, `planTier`, `subscriptionType`, `loginExpiresAt`, `configDirectory` | Free (no model call) | Every refresh, every login and folder account |
| One-turn probe | `rate_limit_event.rate_limit_info`: status, `unifiedWindows.five_hour` and `seven_day` utilization (0 to 1 on the wire, or above 1 once use runs past a window's cap, which counts as 1; a negative or non-number value, minus infinity included, in any window with a valid name, is `check_failed`, and a number too large to read leaves its line unread, 6.2) and `resetsAt` | About $0.008 API-equivalent | When the stored reading is older than `picker.maxReadingAgeMinutes`, or a stored five-hour or weekly reset time has passed (`pick`); on `refresh --force` and a token account's `login` (its first check); and on `refresh` for an account whose sign-in a probe found rejected, as the status records it |

The probe reports utilization as a fraction from 0 to 1, or above 1 once use runs past a window's
cap. The reader converts it once, at parse time, to percent from 0 to 100 with one decimal (0.456
becomes 45.6, and any value above 1 becomes 100). Every stored reading, every room figure and
every output uses percent.

### 6.2 The probe

Exact form, run by the tool as its own child process (argument array, no shell):

```
cwd: a fresh mkdtemp folder under ~/.agent-balancer/probe/, mode 0700, removed after the probe
     (so no project CLAUDE.md, .mcp.json or hooks load; several probes may run at once, so the
     probe refuses to run only if probe/ holds something that is not a probe folder, `p-` and 16
     of the ASCII characters 0-9a-f, and it first removes a probe folder older than the probe
     timeout)
env: CLAUDE_CONFIG_DIR=<account folder>  (left unset for the default folder)
claude -p "Reply with the single word OK." --model haiku --tools "" --disallowedTools "mcp__*"
       --strict-mcp-config --max-turns 1 --no-session-persistence --max-budget-usd 0.05
       --output-format stream-json --verbose [--safe-mode]
```

- A Fable probe (4A.6) is this form with `--model` set to a Fable model, using
  `fable.probeBudgetUsd` and `fable.probeTimeoutSeconds` in place of the 0.05 cap and the 60
  second timeout. It runs after the plain step. The status records its auth error as the
  probe's `login_rejected`, and its working, where no plain probe ran, as a probe that works; any
  other failure of it records nothing. One still running at a pick's deadline records nothing
  either, unless it ends with an auth error before that pick's status rebuild (6.4). It counts as
  tried for the once-a-day limit and the 10-minute wait of the rechecks (6.3, 4A.6) only once its
  command takes its result: one still running when its pick rebuilds the status, or when its
  command's process ends, is not counted, so it stays due for the next Fable pick, and for the
  next `refresh` once a day has passed since the last one counted.
- The tool reads only `type == "rate_limit_event"` lines and the final `result` line's error
  fields. Everything else is discarded unread, a line that does not parse as JSON included, such
  as one with a number too large to read. Captured stderr goes through the scrubber before any
  log line.
- `--safe-mode` keeps login and model selection working and stops CLAUDE.md, skills, plugins,
  hooks and MCP servers from loading. It is on only when `probe.safeMode` is true. If Claude Code
  does not know the flag, the row shows `check_failed` with the scrubbed error text; the probe
  never falls back to normal mode silently. With `safeMode` off, each probe runs the folder's
  hooks once, and `doctor` and the README privacy list say so.
- A probe reply counts as a reading only when it carries a `seven_day` usage value, and also a
  `five_hour` usage value when it names `five_hour` (an entry with or without a value) or the
  stored reading holds one. Otherwise it gives `check_failed` (the reply carried no weekly, or
  no 5-hour, usage) and nothing is stored. The reason: the merge would keep the stored copy of the
  missing window under the new reading's `readAt`, and `pick` would judge the account, the main
  account included, on old use as if it were current. A window entry with no `utilization` key
  adds no value, and a reply with no usage value at all gives `check_failed`, never an empty
  reading. The reading cache checks the weekly part and the stored 5-hour part again where every
  probe reading is saved, so no path records a probe reading without them. "The stored reading"
  is the one under the account's current label, as the cache reads it (6.3). While it holds a
  5-hour window, a reply without one is refused, so if the service stops sending `five_hour` for
  an account, every probe of that account gives `check_failed`. When it holds none, whatever the
  cause (for example none was ever stored, an email change or a token save deleted the
  reading, a `login` account that had none was renamed, or the stored file does not decode as a
  reading or holds a 5-hour use outside 0 to 100, 6.3), a reply without one is stored. A stored file that
  cannot be read at all fails every refresh of the account instead (6.3).
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
  seconds after it. It is stored rounded to the minute, and both the time the probe gave and the
  rounded time must lie in that range, so rounding never widens it: a time even 1 second outside
  is refused, never rounded back in. The window length is 5 hours for `five_hour`; 7 days for
  `seven_day`, the Fable window and any other name that starts with `seven_day`; and 31 days for
  any other name. A reset time that is outside that range, is not a number or a date, or is a
  boolean gives `check_failed`, like a negative usage value, and nothing is stored. A
  missing or null reset time is stored as unknown. Numbers above 100 billion are read as
  milliseconds. The same range of years, 2000 to 2200, applies to dates read from `auth status`.
- These checks apply to every window entry with a valid name and a `utilization` key, whatever
  its name and whether or not the cap below keeps it: a usage value that is null, not a number,
  negative or not finite, or a reset time that is malformed or outside its window's range, gives
  `check_failed` for the whole reply, and nothing is stored. The reason: the parser fails closed,
  and a reply that carries a value the tool cannot trust does not vouch for its other values. The
  cost: if the service starts sending such a value in any window, every account's probe gives
  `check_failed` until the parser changes, and no account is picked on a guess meanwhile.
- A finite usage value above 1 counts as full use of its window, 100 percent, and acts as a full
  window does. In `five_hour` or `seven_day` the account shows as `limited`, with `until` at the
  reset time of the window that frees it, the later one when both are full (10.1). In the Fable
  window, read while `fable.probe` is on, it gives the `fable_limited` warning, so only Fable
  picks skip the account (section 9). In any other window it changes no state and no pick. The
  reason: the client the probe runs reports values above 1 as normal, for use that runs past a
  window's cap, so the value says the window is spent; failing the whole reply for it would show
  `check_failed` instead and leave the account's other windows unread until the next probe.
- A reply keeps `five_hour`, `seven_day` and the Fable window, which never count toward a cap, and
  at most 14 other window names: the first in name order across the whole reply, so the choice
  never depends on the order the reply lists them in. Every entry is checked as above before the
  cap applies, so a bad value in a name past the cap still gives `check_failed`.
- A lock file per account folder stops two probes of one account at once. A caller that finds the
  lock held waits up to its deadline and then uses the stored reading. `refresh` and `pick` skip a
  plain probe when the stored reading is younger than `picker.maxReadingAgeMinutes`, except in
  the cases 6.1 lists. `refresh` also probes again an account whose sign-in a probe found
  rejected, even when its reading is fresh, because only a probe that works or a new sign-in by
  `login` clears that `login_rejected` (10.1); a reading newer than the time the rejection is
  dated to (section 4), which only a probe that worked can store, puts the account back under the
  age rule, and the next status rebuild, such as the menu's `status --cached` each minute, ends
  the rejection. A 60 second timeout marks the row `check_failed`.
- The protected group of environment names, named once here: `CLAUDE_CONFIG_DIR`,
  `CLAUDE_ENV_FILE`, every `ANTHROPIC_*`, every `CLAUDE_CODE_*` except the chat marker
  `CLAUDE_CODE_CHILD_SESSION` (the Claude Code token variable, the `CLAUDE_CODE_USE_*` provider
  names and the `CLAUDE_CODE_OAUTH_*` names among them), and the login locations. The login
  locations are the names outside those prefixes that the installed `claude` (2.1.325, read from
  the binary, never run) reads to find a stored login, a credential store, a token file or a
  sign-in endpoint, or that hold one of its own credentials: `CLAUDE_SECURESTORAGE_CONFIG_DIR`
  (it names the Keychain entry of the stored login, ahead of `CLAUDE_CONFIG_DIR`),
  `CLAUDE_SESSION_INGRESS_TOKEN_FILE`, `CLAUDE_TRUSTED_DEVICE_TOKEN`,
  `CLAUDE_REMOTE_TOOLS_BRIDGE_URL`, `USE_LOCAL_OAUTH`, `USE_STAGING_OAUTH` and
  `AGENT_PROXY_AUTH_TOKEN`, with the families of its background, bridge, runner, remote and local
  sign-in plumbing: every `CLAUDE_BG_*`, `CLAUDE_BRIDGE_*`, `CLAUDE_RUNNER_*`, `CCR_*` and
  `CLAUDE_LOCAL_OAUTH_*` name. Code holds the group once (`Sources/Core/Env/ProtectedEnv.swift`);
  every other site refers to it and adds only its own extras. The sites are the person and probe
  environments below, `unsetEnv` (4A.3 rule 3), the never-allowed list of 4A.2, `doctor`'s
  warning, and the typed checks of 4A.3, which use two subsets: the credential names of rule 2
  and the stored-login names of rule 5. Two base folders stay out of the group: `HOME` and
  `XDG_CONFIG_HOME`. When no `ANTHROPIC_CONFIG_DIR` is set, `claude` looks for a profile's
  credentials under `$XDG_CONFIG_HOME/anthropic`, else `~/.config/anthropic`, but the person's own
  tools need both names, so a person launch and a typed line keep them, while the probe gets
  `HOME` as the tool sees it and no `XDG_CONFIG_HOME`. This is an accepted limit.
- Two child environments. Probe and `auth status` children get an allowlist: `PATH` set to the
  folder that holds `claude` plus `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`
  (a Finder-started app or a LaunchAgent has only a short `PATH`), `HOME`, `USER`, `LOGNAME`,
  `LANG`, `LC_*`, `TMPDIR`, plus `CLAUDE_CONFIG_DIR` only for a non-default folder. Everything
  else is dropped, including the protected group and an ambient `CLAUDE_CONFIG_DIR`, so a stray
  key or token can never bill the wrong account or fool a check. Proxy variables (`HTTPS_PROXY`,
  `HTTP_PROXY`, `NO_PROXY`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`) pass only when
  `probe.passProxyEnv` is true (default false). Person launches (`login`, `run`) are interactive
  sessions, so they get the user's own environment minus the protected group (an ambient
  `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` included), `CLAUDE_JOB_DIR` and
  `CLAUDE_PID`, with the terminal attached. `doctor` warns, by name only and never by value, when
  protected variables exist in the user's shell.
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
`fableProbedAt` is the time read once the account's plain step ended, before the last Fable probe
counted as tried began; in `refresh` the status rebuild that records the plain step comes between
(6.4). It is noted once the command takes that probe's result (6.2), so the once-a-day limit holds
when one fails, and a probe that is not counted leaves it as it was. `refresh --force` does not
lift that limit.

None of those keys names an account: readings are kept by label. `state/readings/<label>.json`
holds the reading last saved under that label, and everything that reads one for an account (the
checks of 6.2, the merge and the age rule below, `pick` and `status`) reads the one under the
account's current label. So each command that changes which account or sign-in a label stands
for moves or deletes that reading under the locks it saves the change under. A rename (`config set
<label> label <new>`, a `login` account only, 4A.4) moves the account's reading to its new label
once the registry holds that label, where it replaces a reading stored there before (or deletes
that one when the account has none), and leaves none under the old label, so the account is judged
by its own newest reading or by none, a rename back included; a rename that the registry save
refuses moves nothing, and only a reading stored earlier under the new label, which no account
holds, is gone. `add` and `init` delete a reading another account left under the label they
give a new account, so its own replies set its reset times. `config set <label> email <new>` on a
`login` or `folder` account deletes the label's reading when the new email differs from the
stored one, compared without letter case as the sign-in check compares them, just before it saves
the new email (12); the same email again, in any letter case, keeps the reading. Every token save
of a token account's `login`, a first one included, deletes the label's reading before it writes
the token file (4A.4), so a reading that stayed while the token file went missing, as after a
restore from a backup that left out `tokens/`, never judges the new token. `remove` deletes the
reading with the account, and `uninstall` deletes every reading (4A.4, 12). Nothing else moves or
deletes a reading: an email or label changed by a hand edit of `config.json`, or a token file put
in place by hand, keeps the reading stored under the label, which then counts like any stored one
(section 14, T16).

The email change, the token save, the rename, `add` and `init` each hold the pick lock and, for
each label whose reading they move or delete, that label's probe lock
(`locks/probe-<label>.lock`), and let neither go until they have saved the change and moved or
deleted the reading. A `refresh` holds a label's probe lock from a registry check it makes once
it has the lock until it has saved its reading and run the status rebuild that records it (6.4), and
goes ahead only while the saved registry still
holds the account it was given under that label, with the same `accountKey`, kind and email (the
email compared without letter case), or while no registry is saved. So a probe already under way
when one of those commands starts saves its reading first, and the command then moves or deletes
that one too. After an email change, a rename, an `add` or an `init`, a probe that waited for the
lock, or that a `pick` or `refresh` began from a registry read before the change, runs no probe and
saves nothing (`refresh` prints `not checked: the account changed while the check waited`). A token
save leaves the registry holding the same account, so a probe that waited for its lock goes ahead
and reads the token file as the save left it, with the new token. No reading taken for the old
account, sign-in or token is saved under the label after the change: the next probe there starts
from the moved reading or from none, at `pick` or `refresh` after a rename or an email change, and
at the first check of a token save. `pick` and `run` read the registry again once they hold the
pick lock, and neither judges nor starts an account that it no longer holds under its label
(7.2 rule 7). `remove` and `uninstall` take only the pick lock: a probe under way during `remove`
can save a reading under the removed label after `remove` ends; `add`, `init` and a rename onto
that label delete it before an account starts on it, and so does a rerun of `remove <label>`. A
command waits for a probe lock, while it holds the pick lock, up to the probe timeout plus the
Fable probe timeout plus 60 seconds, 140 seconds with the defaults, so a `pick` or `run` that
starts meanwhile can stop at the pick lock (7.2 rule 7); when the command cannot have the probe
lock, it changes nothing and says
`A check of '<label>' is still running, so nothing was changed. Try again in a moment.`
A probe lock is also held through status rebuilds: a refresh records each account's result before
it lets that account's probe lock go, after the plain step and again after a Fable probe, and
`login` records its first check the same way (4A.5). Each such rebuild waits up to 30 seconds for
the history lock (section 13), so while other rebuilds hold that lock, a probe lock can stay held
past that wait, and the command refuses as above.

The rebuild that an email change or a token save runs records no `limit_cleared` for the label
whose reading it deleted, as a removed account's records none (10.3): that limit belonged to the
old sign-in or token and did not clear. Another rebuild that runs while one of these commands
works, such as one during the email change's own sign-in check or the token save's first check,
does not know of the delete and can record one. So can the next rebuild after one of these
commands stops once it has deleted the reading, such as an email change that the registry save
refuses (12), because such a command runs no rebuild of its own. A rename moves the reading, so
the account's state stays as it was.

`status` shows the age; the menu greys a row whose
reading is older than twice the refresh interval. `pick` refreshes any candidate whose reading is
older than `picker.maxReadingAgeMinutes` (default 15) and skips the probe when the reading is
younger (unless `refresh --force`). If that refresh fails, the candidate is skipped with reason
`stale reading, refresh failed`. For the protected account a stale reading is treated as worst
case (not eligible), never as zero use.

Readings merge by one rule: within one window (the same `resetsAt`, to the minute) stored use
never goes down, so each new reading is merged as the maximum for that window. A reading that
claims a later `resetsAt` before the stored reset time has passed is discarded. Whether a stored
reset time has passed is judged at the new reading's own time (its `readAt`, the clock read when
its probe ended), never at a later read of the clock. So a reset time
decides how long a stored use holds, and a fake one that passes the range of 6.2 holds its window
the same way: the merge keeps the stored use, and discards every reading with another reset
time, until that reset time has passed. For `five_hour`, `seven_day` and the Fable window, the
windows a pick reads, a held window keeps its reset time but never less use than the newest reply
gives: a higher use in a discarded reading still raises it, with that reading's `readAt`, so a
hold never shows less use than the reply says. The reset time it keeps still counts: a main
account's reserve line (7.2 rule 2) reads the days to the held weekly reset, so a held reset
sooner than the reply's can give a higher line than the reply's own reset would, by up to 40
points on the standard reserve, until it passes. When one reply names one
of these windows more than once, its entries merge by the same rule, and because they were read
at one moment the highest use among them stands, in any order, with one exception, also in any
order: an entry whose reset time had passed when the reply was read is left out when another
entry's reset time is later or unknown, because its window had ended, so its use never counts
toward the window after it. The range caps the hold at
one window length plus 300 seconds after the probe that reported it: 5 hours 5 minutes for
`five_hour`, 7 days 5 minutes for `seven_day`, the Fable window and any other name that starts
with `seven_day`, and 31 days 5 minutes for any other name. From that time on,
the next reading with a later reset time replaces it. A stored `resetsAt` more than its window
length plus 600 seconds after the new reading's time (a file from before the bounds of 6.2, an
edited one, or a reading taken while the clock ran ahead) is not trusted, so the next valid
reading replaces it at once. A stored file that does not decode as a whole, or whose `source` is
not `probe` or `estimate`, reads as no reading, and the next good probe writes a new one; a stored
reset time that does not decode reads as unknown, and a stored use outside 0 to 100 is dropped. A
stored file that cannot be read at all (for example a link, a file that is not regular, or one
over 1 MiB) is neither read nor replaced: every refresh of that account fails until the file can
be read, and `pick` skips the account as `no weekly reading`. A reading whose
`resetsAt` has passed, that has no weekly value, or that is dated more than 60 seconds in the
future counts as stale: it is refreshed first, and the account is skipped with
`window reset, refresh failed` or `no weekly reading` if that refresh fails. A `pick` forces the
probe for a candidate whose stored reading has a passed reset time, even when it is younger than
`picker.maxReadingAgeMinutes`. For a `main`
account a launch is allowed only on a probe reading from the current window no older than
`picker.maxReadingAgeMinutes`. The pre-pick refreshes run in parallel (at most 8 probes at once,
6.4) and `pick` answers within `picker.deadlineSeconds` (default 45); a candidate whose refresh
fails with `check_failed`, or whose plain probe is still running at the deadline, is skipped as
stale and recorded as `check_failed`, one whose probe had not begun by then is judged on its
stored reading, with nothing recorded for it, and one whose Fable probe alone is still running is
recorded by its plain step (6.4). `pick` does not wait for a probe left running past the
deadline, and its process ends with its answer, so what that probe reads is saved only if the
probe ends before that process does; an auth error it gets before the pick's status rebuild is
recorded all the same (6.4).

Stored window names that no reading reports are evicted, and the rule is the same for every name.
When a probe reading is merged before it is saved, each stored window that the reading does not
carry is dropped when its `readAt` is more than 32 days before the new reading's time, or more
than 60 seconds after it (a clock that moved back). A window's `readAt` is never later than the
last reading that carried it, so a name that no reading has reported for more than 32 days goes
at the next saved reading; and 32 days is longer than any window a reset time may span (31 days
plus 300 seconds), so a window whose reset time may still be ahead stays. A dropped name that a
later reading reports again starts over. Then at most 14 stored names other than `five_hour` and
`seven_day` stay: those the new reading carries first, then the newest `readAt`, then name order.
Every recorded probe reading carries `seven_day`, and carries `five_hour` whenever the stored
reading holds one (6.2), so neither is ever a name the reading leaves out, and eviction never
removes them; the merge also keeps them itself, so a later change to the probe rule cannot turn a
picker refusal into a pick. Nothing is evicted when a file is loaded, after a failed probe, or
when only the Fable probe time is saved, and eviction never touches the Fable reading, the
reading's own `readAt` or the file format.

### 6.4 Refresh cadence and daily cost

A probe costs about $0.008 API-equivalent. A plain probe is skipped while the stored reading is
younger than `picker.maxReadingAgeMinutes`, except in the cases 6.1 lists, so real cost can be
lower than the table. The table leaves out the Fable probe, which runs even on a fresh reading, as
4A.6 says.

| Background cadence (5 idle accounts) | Probes per day | API-equivalent per day |
|---|---|---|
| Every 15 minutes | 480 | $3.84 |
| Every 30 minutes | 240 | $1.92 |
| Every 60 minutes, background only | 120 | $0.96 |
| Every 60 minutes plus the pre-pick refresh at about 20 picks a day (default) | about 180 | about $1.44 |
| On demand only (about 20 launches a day) | about 20 | about $0.16 |

The default is 60 minutes in the background plus the on-demand refresh before `pick`.

One refresh runs at most 8 probes at once (`Refresher.maxProbesAtOnce`). Each probe is its own
`claude` process, so a long account list would otherwise start that many processes together; 8
is above the 5 accounts this table assumes, so a usual refresh or pick never waits. With more
accounts, the rest wait for a free slot and each is probed as soon as one frees, so every account
is still read. Each refresh starts at a randomly chosen account and takes the rest in list order,
going back to the top after the last, so when more accounts are slow than there are slots, the
accounts left waiting change from one refresh to the next instead of always being the last ones
in the config. When a pick's deadline passes, no probe begins after it, plain or Fable. An account
whose probe has not begun, still waiting for a slot or for its lock, is not probed, and nothing
is recorded for it: only a probe that ran changes an account's status, so its status, events and
history keep what they showed, and the pick judges it on its stored reading (a stale one is
skipped with `stale reading, refresh failed`). An account whose plain probe is still running at
the deadline is recorded as `check_failed`. An account whose Fable probe is still running is
recorded by its plain step alone, a fresh stored reading or a plain probe that finished. `pick`
does not wait for that Fable probe, and its process ends with its answer, so what the Fable probe
reads is saved by the usual rules only if the probe ends before that process does. A probe still
running at the deadline that ends with an auth error before the pick's status rebuild is
recorded as the account's `login_rejected` in place of the above, also when the pick ends
`pick busy`, and when it ends so before the pick decides, while the pick waits for the pick lock
or checks sign-ins again under it, the pick skips the account as `login rejected`. A Fable probe
still running when the pick rebuilds the status is not
counted as tried (6.3), so it stays due instead of waiting a day.

The menu app runs `agent-balancer refresh` at launch when `status.json` is missing or older than
`refresh.backgroundMinutes`, then on its own timer at that interval, and runs
`agent-balancer status --cached` every 60 seconds so new readings show up. Every `refresh`
rebuilds `status.json` (section 4) as each account's probes end, before it lets that account's
probe lock go, and once more at its end with the sign-in checks and each result whose own rebuild
did not finish with `state/current.json` saved (section 13), so a refresh that the menu ends after
its 300 second timeout keeps what its finished probes found, unless such a rebuild was skipped at
its 30 second wait for the history lock, saved no `state/current.json` or failed, or the menu
ended the refresh after a probe finished but before that probe's own rebuild did. The menu's end
stops the process, so the last rebuild does not run, and those results are lost from the status:
a reading that a working probe stored shows at the next rebuild, a token account's rejection that
its own rebuild recorded still keeps the token out, since that rebuild records it apart from
`state/current.json`, and any other error is lost until the account's next probe. A failed plain
probe leaves the reading as old as it was, so the next refresh probes the account again; a Fable
probe whose own rebuild had not finished is not counted as tried (6.3), so the next refresh runs
it again, while one whose own rebuild was skipped or saved no `state/current.json` was counted
and runs again once a day has passed. Until then `pick` and `run` judge the account as they did
before that probe. This version has no command that schedules `refresh` for
people who use only the CLI: `schedule install` and `schedule remove`, which would manage a user
LaunchAgent, are parked for a later release.

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
account first within its 5-hour group (rule 5 in 7.2), and the tool notices the end itself on the
day the plan tier drops (section 9, `account_ended`). `config set <label> ends <date>` sets a date
that is known.

An account keeps one end marker: `config set <label> ends <date>` also clears `endingSoon`,
`config set <label> ending-soon true` also clears `endsAt`, `config set <label> ends none` clears
both, and `ending-soon false` clears only the flag. Each is one save, so one change never leaves
both markers or neither. `add` refuses `--ends` with `--ending-soon`. A config saved earlier with
both keeps working, the date first as the picker and the window read it, until the next change
clears one. `config set` saves under the pick lock, like every command that saves the registry
(4A.4).

A token account also carries `tokenCreatedAt`, an ISO 8601 time that `login` sets each time it
saves a token (4A.4). It is optional, so a config from before it stays valid at schema version 1.

Every account also carries `expectedPlanTier` and `accountKey`. `init` records the tier
`auth status` shows; for an added account the first `refresh`, or folder `login`, whose sign-in
check placed the expected account's sign-in in its own folder, for the email the account has when
the plan is saved, records it (10.1). `config set <label> email <new>` on a `login` or `folder`
account forgets the tier in the same write that saves a new email, and records the new sign-in's
when its own check places it; otherwise the next such `refresh` or folder `login` does, so the
first check that places the new sign-in reports no `plan_changed` and ends no account marked
`endingSoon` by plan. An ending-soon plan drop that a check of the old email marked (10.1) ends with
that email: the first status rebuild after the email changes, the email change's own included,
clears it, so `status` and `pick` agree on such an account.
`accountKey` is a random id that `init` and `add` make. It is no secret, and it goes on every
history and events line and into `status`, so a label removed and added again for another account
is never mixed with the old one.

An account may also carry `"fable": { "allowLaunches": false }` (7.2 rule 4; absent means
allowed). An account's `endsAt` date is its last day: the account counts as ended once that local
day is over. The validator refuses `picker.limitedAtPercent` outside 1 to 100,
`picker.minRoomPercent` and `picker.expectedRunPercent` outside 0 to 100,
`picker.deadlineSeconds`, `picker.leaseMinutes` and `launch.keepDays` below 1,
`picker.endingSoonAssumeDays` below 0, a `launch.envNames` entry that does not match
`^[A-Z][A-Z0-9_]{0,63}$`, a `launch.settingsKeys` entry that is not a plain name, and an entry of
either list that 4A.2 never allows. A config may add `crossSessionInbound` to `settingsKeys` and
names of its own, such as `CLAUDE_ROLE` and `CLAUDE_CLIENT`, to `envNames`. A key missing from a
section takes the default shown above.

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
   5-hour window (when present) is under `limitedAtPercent`. With no 5-hour window, rule 10
   applies.
4. Model-aware: for a Fable launch, also require Fable room (7.4): with a Fable reading,
   `100 - usedPercent >= fable.minRoomPercentOfCap`, both in percent of the Fable cap; with no
   reading, the guaranteed room of the fallback `>= minRoomPercent`. Skip any account with
   `fable.allowLaunches: false`.
5. Rank first the eligible that have a 5-hour window, then those without one (rule 10); within
   each group, by effective expiry `min(weekly reset, endsAt)`, soonest first. An account marked
   `endingSoon` with no `endsAt` ranks as if its `endsAt` were `picker.endingSoonAssumeDays`
   (default 2) from now; a known `endsAt` sooner than that still ranks ahead of it. Ties go to the
   most room (`line - marginPercent - used` for a protected account, `limitedAtPercent - used` for
   a pool account), then to config order, so the answer never flips between runs.
6. Nothing eligible: return `label: null` with one reason per account; exit code 2. Never fall
   back past the line.
7. Lease: `pick` runs its refreshes first, then holds an exclusive lock on `locks/pick.lock` (wait
   up to 30 seconds, else exit 1 with `pick busy`) while it reads `state/leases.json`, decides and
   writes its lease (an internal id for the pick log, label, model, time). A caller that did not
   launch does nothing; the lease lapses after `picker.leaseMinutes`, and a lease dated in the
   future is dropped. For `picker.leaseMinutes` (default 10) each open lease adds
   `picker.expectedRunPercent` (default 5) to that account's weekly used and 5-hour used before
   rules 2 to 4, so an account near its limit is not handed out again seconds later. Rule 5 still
   ranks the soonest expiry first within each group, so two callers picking seconds apart can land
   on the same account. `pick --dry-run` takes the lock but writes no lease. Once it holds the
   lock, `pick` reads the registry again and skips, as `the account changed while the pick
   waited`, every account that the saved registry no longer holds under its label with the same
   `accountKey`, kind and email (the email compared without letter case), so a rename and an `add`
   under the old label made while its probes ran never get the renamed account judged by the new
   account's reading; `run <label>` refuses such an account the same way and starts nothing. A
   command that changes which sign-in a label stands for can hold the lock while it waits for that
   label's probe lock, up to 140 seconds with the default timeouts (6.3), so a `pick` that starts
   then can exit 1 with `pick busy` after its 30 seconds, and `run` with `Another pick is running.
   Try again in a moment.`
8. Units: the probe's `utilization` (0 to 1, a value above 1 counting as 1) is stored as percent
   0 to 100 with one decimal before any rule runs.
9. A protected account also needs a 5-hour window and
   `fiveHour used + expectedRunPercent < limitedAtPercent`, so a worker cannot lock the user out
   of the main account until the 5-hour reset. A window with a use and no reset time is present.
   Without one it is not eligible: `No 5-hour reading, which the main account needs.`
10. No 5-hour reading. A protected account whose stored reading, the one under its current label
    (6.3), holds no 5-hour window is never picked (rule 9), and with nothing else eligible the
    pick returns `label: null` (rule 6); `config clear-main` makes it a pool account, without its
    reserve line. A pool account with no 5-hour window is judged on its weekly use (rules 3, 4 and
    7) and ranks after every eligible account that has one (rule 5). When it is eligible, its
    candidate reason ends with `5-hour use unknown.`, and so does the pick's reason when it is
    picked, after any Fable note. A pick of an account that has a 5-hour window, made while an
    account without one is eligible, ends with `Accounts with no 5-hour reading go last.` Whether
    an account has a 5-hour reading follows the reading stored under its current label, as the
    cache reads it (6.2, 6.3). While that reading holds a 5-hour window, a reply without one is
    refused (6.2), so once the reading is stale or its window has reset, the account is skipped as
    `stale reading, refresh failed` or `window reset, refresh failed` until a reply carries the
    window or the stored reading no longer holds one. When the stored reading holds no 5-hour
    window, whatever the cause (for example the service never reported one, an email change or a
    token save deleted the reading, a `login` account that had none was renamed, or the stored
    file does not decode as a reading or holds a 5-hour use outside 0 to 100, 6.3), the next reply
    without the window is stored, and the account is judged as one with no 5-hour reading. A
    stored file that cannot be read at all fails every refresh instead, so the account is skipped
    as `no weekly reading` until it can be read (6.3). So when the service never reports a 5-hour
    window for an account, no reply adds one, and the account is judged as one with no 5-hour
    reading unless the reading stored under its label holds one, which only a hand edit under
    `~/.agent-balancer/` (of `config.json` or a token file, section 14, T16) or an earlier version
    of the tool can have left there (6.3). In that case the
    account is judged by that reading, its 5-hour window included, while the reading is fresh
    (younger than `picker.maxReadingAgeMinutes`, 15 minutes by default), so a main account can be
    picked on it, and is skipped once the reading is stale or its window has reset. A reply that names
    `five_hour` with no value fails the probe. `init` and `add` make pool accounts; of the
    commands, only `config set-main` makes a main one. The reason: with no 5-hour reading the tool
    cannot show that a run leaves the user room on the main account, and a lockout until the reset
    cannot be undone, so there the unknown is the worst case. On a pool account an unread limit
    costs worker runs, so it stays usable but never ahead of an account known to have room.

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
and the folder of each folder account are read, one pass each. A session whose record sits in an
account's own folder counts toward that account, whatever launch file it names, and the launch
files its records name are protected like any other.

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
| `settings_changed` | a link of a folder account is broken, or a hook entry recorded at link time is gone or changed (5.7); or, after `init`, the hook record is missing or unreadable (4A.5); or, for `run`, the saved verdict is missing or older than the file, or the settings path is a link that goes nowhere or is not a file | error on every affected account, shown as one banner | "Settings changed. Run `agent-balancer link --accept-source-change` in Terminal." For `run`, with no verdict that matches the file's stamp: "Settings changed since the last check. Run `agent-balancer doctor` in Terminal." For a settings path that no reader can fix, the texts of 4A.5 that name the repair |
| `plan_changed` | `planTier` differs from `expectedPlanTier` | error | "Plan is max_5x, expected max_20x." |
| `account_ended` | `endsAt` passed; or, for an account marked `endingSoon`, the first sign-in check that placed the expected account's sign-in, for its current email (10.1), where `planTier` differs from `expectedPlanTier` or is missing. Once ended that way it stays ended until the flag is cleared (`config set <label> ending-soon false`, `ends <date>` or `ends none`) or the account's email changes (7.1) | ended | "Account ended." |
| `check_failed` | a sign-in that reports no email for an account with an expected email (5.7), probe timeout, no `rate_limit_event`, unparsable output, `claude` missing, a reply with no weekly use (or no 5-hour use when one is named or stored), a bad value in any window with a valid name | error | "Check failed: probe timed out after 60 s." |
| `limited` | probe status not `allowed`, or weekly or 5-hour use at or above `limitedAtPercent`; a full Fable sub-cap alone is the warning below | limited | "Limited until Wed 4:00 PM." |
| `fable_limited` (warning) | Fable use is readable and at or above `limitedAtPercent` of the Fable cap; only Fable picks skip the account | ok | "Fable limited until Thu 9:00 AM." |
| `login_expiring` (warning) | `loginExpiresAt` within 7 days; for a token account within 14 days of its estimated end (4A.4) | ok | "Login expires Dec 7." |
| `token_missing` | a token account whose token file is absent, is not a regular 0600 file owned by the user, or does not parse | error | "No token saved. Run `agent-balancer login pool-a` in Terminal." |
| `not_linked` | a folder account that was never linked (4A.5) | error | "Settings not shared. Run `agent-balancer link spare` in Terminal." |
| `possible_duplicate` (warning) | a token account whose weekly and 5-hour reset times both equal another account's (4A.4) | ok | "Same reset times as pool-a. If this is the same account, remove one." |
| `key_in_settings` (warning, no event) | the default folder's `settings.json` carries `apiKeyHelper`, or a credential name of 4A.3 rule 2 or `CLAUDE_CONFIG_DIR` in its `env`, read by name only (4A.3) | ok | "Settings carry an API key or key helper. Every account is skipped." |
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
  `loginExpiresSource` is `estimate` for a token account, `auth` for a `login` or `folder` account
  (from the last sign-in check that placed the expected sign-in, for the current email), and null
  when no expiry is known.
  `inUse` is `{ "count", "sessions" }`, or with
  an unreadable record `{ "count": null, "sessions": [], "unknown": true }` (section 8).
- `state` is one of `ok | limited | error | ended`. `error` is null or
  `{ "code": ..., "text": ... }`. `source` is one of `probe | estimate | none`.
- `reserve` is present only on `main` accounts:
  `{ "linePercent": 63.3, "marginPercent": 5, "launchAllowed": true, "daysLeft": 4.0 }`.
  `launchAllowed` is the reserve line's answer alone (7.2 rule 2); `pick` also applies rules 7
  (open leases), 9 and 10, and `next` rules 9 and 10, so either can refuse a main account whose
  `launchAllowed` is true.
- `fiveHour` is null when the stored reading holds no 5-hour window, whether or not the plan has
  one (7.2).
- `stateSince` is when the tool first saw the current `state` with its error code. It is null for
  an `ok` account until a rebuild has read a reading of it or dated a probe's rejection of it
  (section 4), so an account whose rejection was recorded before its first reading, such as a
  `folder` account that `login` then signs in again, shows it with no reading.
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
  same as a missing one, so it is never stored or printed. It comes from the last sign-in check,
  kept only when that check placed the expected account's sign-in (a folder account in its own
  folder); a check that found another account (`wrong_account`), could not confirm the folder,
  saw the account logged out or could not run keeps none. A check also counts only for the
  account and email it was made for: `state/current.json` keeps, with each check's result, the
  digest of the account key and lowercased email it was made for (section 13), and while the
  account's own digest differs, after `config set <label> email`, an edit of `config.json`, or
  `remove` and `add` of the same label, the row has no `planTier`, no `loginExpiresAt` from a
  check and no `signed_in` until a check of the new email. An entry with no digest, as an
  earlier version wrote it, reads the same way. A check made for the email the account had
  before, whose command saves its result after the email changed, whether or not it read a
  status, records nothing at all, so it never clears what a check of the new email found, such as
  `wrong_account`. These commands record a check: `status` (not
  `--cached`), `pick`, `run` (once it has written its launch file), `verify`, `refresh` (for each
  `login` and `folder` account whose reading did not fail, every time it runs), `init`,
  `login` for a folder account (the check of a folder it refuses as signed in already, and the
  one after its sign-in), `link <label>` (once its links are made) and
  `config set <label> email`. Only a check that placed the expected sign-in, for the current
  email, feeds `expectedPlanTier` (7.1), `loginExpiresAt` and the ending-soon plan drop
  (section 9). The row leaves it null while the account's last check or probe says
  `login_rejected`, `check_failed` or `wrong_account`. A plan drop marked for an earlier email
  goes with that email, as its tier does (7.1).
- `signInCheck` is on `folder` rows only (login and token rows have no such key): the result of
  the last sign-in check of the folder that read an answer from `auth status`. `signed_in` is the
  expected account (any account when none is expected) signed in in the account's own folder;
  `signed_out` is no account signed in; `other_account` is another account signed in in that
  folder; `not_confirmed` is an account signed in that the check could not place in that folder,
  or could not confirm as the expected account because the sign-in reported no email.
  It is null before the first such check. A check that could not run or whose answer could not
  be read leaves it as it was. A `signed_in` from a check made for another account or email
  reads null (`planTier` above). A status written before this field has no key; its writer kept
  the plan tier through a doubt, so the window reads such a linked folder row by its tier only
  while the row shows no code that can hide one and is not `check_failed` (section 11). The
  window reads a `signInCheck` that is not a string as no key, and still loads the rest of the
  status.
- Each account also carries `accountKey` (7.1), `endingSoon` and `linked` (true or false for a
  `folder` account; null for `login` and `token` accounts).
- The document carries a top-level `next` object (`label` is null when nothing fits),
  `{ "all": { "label", "reason" }, "fable": { "label", "reason" } }`, computed with the picker
  rules but without leases and without the age rule of `picker.maxReadingAgeMinutes`, the main
  account's included, so the menu header can show the next launch without running `pick`. The
  main account's probe-source rule stays: a main account whose reading is not a probe reading is
  not picked for `next`. `pick` confirms, and its answer can differ while a lease is open or a
  reading is old.
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
informational and not stable. Every refused flag or caller settings exit 1 with a message on
stderr and write nothing. The `pick busy` refusal (lock not taken within 30 seconds) exits 1 with a
message on stderr and writes no lease, launch file or pick log line; the status records what its
probes found.

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
  writes none and a label removed and added again for another account writes both. The rebuild
  that an email change or a token save runs writes no `limit_cleared` for the reading it deleted,
  as a removed account's writes none; another rebuild that runs during the command, such as during
  the email change's own sign-in check or the token save's first check, can write one, and so can
  the next rebuild after a command that stopped once it had deleted the reading, such as an email
  change that the registry save refused (6.3).
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
- An event is written at least once for a change the next rebuild can still see, such as one in
  the config or a stored reading. If `state/current.json` cannot be saved after the events were
  (section 13), the next rebuild compares with the old file, finds those changes again and writes
  them again with new `seq` numbers. A repeat has a higher `seq`, the `at` of the rebuild that
  wrote it, and the same `label`, `type`, `code`, `window`, `resetsAt` and `notBefore` as the
  first copy; only its `text` can read differently. A caller reads each event as the state it
  reports for its label (limited until a time, an error code, recovered, added, removed), never
  as a count, so a repeat restates what the first copy reported and applying it again changes
  nothing. A change only a probe or a sign-in check saw (a probe error, a rejected login, or a
  recovery from one) is kept only in `current.json`, so after that file failed to save, or the
  events step failed, it is seen again only when a later probe or sign-in check of that account
  sees it, and until then `status --json` holds the state of the last rebuild that saved
  `current.json`. If the state has gone back to what the old file holds by the time a rebuild
  could see a change again, that rebuild finds no change and writes nothing: the record keeps a
  change the state no longer shows (a `recovered` for an account that is in error again, or an
  `error` for one that recovered) until the label's next event, and when the events step itself
  failed, the change gets no event at all. So after a failed save a label's last event and
  `status --json` can disagree, and either can be behind until the label's next event; `pick`
  decides from live checks and, for a token account, from the probe rejection
  `state/current.json` records.
- Each answer carries `recordId`, a random id made when `events.jsonl` is created: `r-` and six
  lowercase hex digits. A caller that sees a `recordId` it does not know treats that as a gap too:
  the record was started over.
- `--label` must match the label pattern of 5.2 and is never used to build a path otherwise;
  `--limit` is 1 to 1000. The same holds for `history` (10.4).
- `at` is when the tool first saw the change. `notBefore` is the time of the last reading that
  still showed the old state (or, after a probe's rejection, the time that rejection is dated to,
  section 4), or null. The real change lies between the two, so "limited since" is only as exact
  as the readings are frequent.
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
means nothing was read. An append also compares the line with the last line in the account's
file and writes nothing when the account, the numbers, the reset times, the state and the source
are the same, so appends are idempotent: a rebuild that runs again after a failed step (section
13) never writes a reading twice. Lines are written under the account's label at the time, each
with its `accountKey`, and a configured account lists its own lines from every label's file, by
that key, oldest first: after a rename it keeps the lines from before it, and it never lists
another account's lines, such as those of an account removed from its label or the one that held
its old label; a label no account holds lists its file as it is. A history file that the reader
refuses, such as a link, stops only the listings whose lines it may hold: that of the account under
its label and that of the `login` account, the one kind a rename moves. `history --json` then
exits 1 when such a listing is asked for, and a listing of any other account, such as
`--label <label>` for a token account, goes on without that file. `--since` defaults to 24 hours
back and `--limit` to 500 readings per account (the newest ones, listed oldest first). `--since` takes an ISO 8601 time or a span such as
`30m`, `24h` or `7d`. Lines older than `history.retentionDays` (default 35, five weekly windows)
are dropped (section 13). Retention counts back from the earlier of the clock and the newest
stored reading of a configured account that has a `five_hour` or `seven_day` reset time at most
270 seconds before the reading's own time (section 13). Unless retention is 0 (below), nothing is
pruned while no configured account has such a reading, so a clock moved forward prunes nothing by
itself. A reading taken while the clock runs ahead is dated ahead too and moves the cutoff ahead
by as much as the clock was ahead, at most 5 hours 5 minutes when its `five_hour` reset time is at
most 270 seconds before its own time and at most 7 days 5 minutes otherwise (section 13). So a
line younger than `history.retentionDays` minus 7 days 5 minutes always stays, whether this
version or an earlier one saved the reading file: with the default 35 days, every line from the
last 27 days 23 hours 55 minutes. The cost: while the newest reading of every configured account
has no such reset time, no line ages out, and a reading whose such reset times are all more than
270 seconds before its own time does not count, though the range of 6.2 allows one up to 300
seconds before it. With 0 no history line is written, and the next prune drops every one without
waiting for such a reading, because it counts back from no time; `history` then answers with
empty lists, and the events record keeps only each label's newest line.

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
  - *Token panel:* sign-in state and "Sign in again" (runs `agent-balancer login <label>`, or
    shows that command on its own line with a Copy button), the estimated token expiry with a tip
    that says the token file is a private file under `~/.agent-balancer`, Ends, Remove.
  - *Folder panel:* sign-in state and "Sign in again" (runs `login <label> --browser`, which runs
    the documented `claude auth login --email <expected email>` in that folder and then checks the
    email with `auth status`; a folder `auth status` finds signed in already is refused, and that
    answer is recorded as a sign-in check before the command exits, unless a probe's
    `login_rejected` stands, when it signs the folder in again), the folder path with Copy,
    shared-settings state, Ends, Remove. The email line adds the plan tier when the status has
    one.
  - The `login` account shows its sign-in state and role and has nothing to change here.
  - **Consent:** the window runs six command shapes only: `add`, `add --kind folder`, `remove`,
    `config set <label> ends|ending-soon`, `login <label>` (a token account) and
    `login <label> --browser` (a folder account). Remove asks for the label typed into its sheet.
    `link`, `unlink`, `config set-main`, `config clear-main`, a change of email or label, and
    removing a main account are not in the window: it shows the command with a Copy button, so
    everything that shares hooks or moves protection keeps its typed consent in a terminal (5.1).
    The app has no scripting surface, and it turns management off, with a one-line reason, when
    its own environment carries the chat-shell variable (5.1).
  - **Checked again when it runs:** the role can change while a sheet is open (`config set-main`
    in Terminal, or a rewritten status file), so Remove reads `status.json` again when it is
    confirmed and runs `remove <label>` only when the account is still listed, its role is
    exactly `pool`, its kind is `token` or `folder`, and its kind and email are the ones the
    sheet was opened for (its consent text names what that kind loses). Otherwise it runs nothing,
    closes the sheet, and shows the Terminal command with a Copy button for a main account, or
    says the account is no longer listed or is another account now. A `remove` that runs and
    fails, such as one another `remove` got to first, also closes the sheet, and the bar shows
    the CLI's text. Every other change reads the
    status again before it runs: the
    end choice runs only for an account still listed whose kind is not `login`, Sign in and the
    Add sheet's step buttons check the kind, the link and the sign-in state, and `add` and `login`
    leave the label and kind checks to the CLI. The CLI is the enforcement point: `remove` of a main
    account refuses with no terminal (5.1), which is how the app runs it.
  - **No file writes:** every change is one CLI command, run with an argument array; a bar at the
    bottom of the window shows the last command and its result or error text: the first line of
    its error output (of its output when it failed with none, or when it worked), with tokens
    scrubbed and through the display-safe pass. For `login <label> --browser`, which prints
    its one-account-per-folder advice first, the bar shows the first line that starts with
    "Error " when the command failed, or the "Signed in." line when it worked, and the first line
    when there is no such line. For a token account's `login <label>`, which prints its opening
    line first, the bar shows the line that says the token was saved and the last first-check
    line, or, when it failed before those, the first line of its error output, then of its
    output, that starts with "Error", and the first line when there is no such line.
  - **The same account, never another:** "Sign in again" appears only on a folder that is logged
    out, names the expected email and passes it as the pre-fill; the window has no field that
    changes an account's email.
  - **End date:** no end date (`ends none`); "Ending soon, date unknown" (`ending-soon true`); or
    "Ends on" with a date picker that takes today or later (`ends <date>`), with a ? tip to set
    only a date you know, because launches stop after that day. Each change runs one command from
    any state: the tool keeps one end marker per account, so that one save sets the new marker and
    clears the other (7.1). A failed change leaves the markers as they were; the window reads the
    status again and the bar names the command that failed. The steps the date picker reports
    while its date is edited run nothing, and the panel shows the date being edited; the edit
    runs one `config set <label> ends <date>`, for the date it ended on, when it ends: the picker
    loses focus or goes away, the window closes or stops being key, or another account is
    selected. So a date part way through an edit, today included, is never saved. An edit that
    ends while another command runs waits for the next end, and an end choice clicked during an
    edit replaces it.
  - **Sign-in state:** a folder account counts as signed in only with evidence: it is linked, and
    its status row carries the plan tier. The tool records the tier only from a sign-in check
    (`auth status`) that placed the expected account's sign-in in the folder itself, and a check
    counts only for the account and email it was made for: after `config set <label> email`, an
    edit of `config.json`, or `remove` and `add` of the same label, the row has no tier and no
    `signed_in` until a check of the new email (10.1), so the window shows no "Signed in" and no
    finished Add step 3 for such a folder, which `run <label>` refuses until a check of the new
    email places it. These commands record a check: `status` (not `--cached`), `pick`, `run`
    (once it has written its launch file), `verify`, `refresh` (for each `login` and `folder`
    account whose reading did not fail, every time it runs), `init`, `login <label>` and
    `login <label> --browser` for a folder (after the sign-in, or when they find the folder
    already signed in), `link <label>` (once its links are made, so
    the window reads what the folder holds before it offers Sign in) and
    `config set <label> email`. Any other result of a check (another account, logged out, signed
    in from another folder, no folder reported, or no answer) clears the tier, so another
    account's plan tier never shows on this account's line. The row leaves the tier out while the
    account's last check or probe says `login_rejected`, `check_failed` or `wrong_account`, so a
    doubt that the row's own code hides (under `account_ended`, or under a code ranked above it)
    still counts. A probe's `login_rejected` stays until the status sees a stored reading newer
    than the time the rejection is dated to (section 4) or, with no stored reading it can read,
    records a probe that works with a newer reading, which `refresh` keeps trying even while the
    reading is fresh (6.2), or, for a token account, until `login` saves a new token whose first
    check works and whose rebuild saves `state/current.json` (4A.5), or until `login`
    completes a new sign-in (the folder was signed out before the run, or `claude auth login`
    exited 0); a check that sees only the old sign-in, such as the one a refused
    `login <label> --browser` records, leaves it, so the folder does not read "Signed in" in
    between, and while it stands `login <label>` and `login <label> --browser` sign the folder in
    again instead of refusing it as signed in already. The row's one code can also hide what the
    last check saw, so the window reads a folder row's `signInCheck` (10.1) first:
    `other_account` shows "Signed in as another account" with a red dot in the list and the panel
    alike, whatever code the row shows, with the `wrong_account` problem and its step ("Sign the
    expected account back in to this folder. Do not relabel the folder.") instead of Sign in;
    `not_confirmed`, or a value the window does not know, shows "Sign-in not confirmed" with no
    Sign in, since `auth status` lists a sign-in there and `login --browser` would refuse it
    unless a probe's `login_rejected` stands.
    Otherwise the window counts the tier only on a row that is `ok`, `limited` or `ended`, or an
    error that says nothing against the sign-in (`settings_changed`, `duplicate_login`,
    `plan_changed`), and never when `signInCheck` is `signed_out`. A linked folder the last check
    placed whose tier a probe or check has doubted since (a visible `login_rejected` aside) shows
    "Sign-in not confirmed" with no Sign in, for the same reason, except an ended folder, whose
    hidden doubt may be a probe's rejection (below). A folder with no evidence (a new
    folder after `add --kind folder` or `link`, one the last check saw logged out, or one whose
    checks could not run) shows "Not signed in", or "Signed out" while its row shows
    `login_rejected`, with a red dot, and offers Sign in once it is linked, unless its expected
    email fails the plain-email rule `login --browser` applies (one rule, in
    `ConfigValidator.isPlainEmail`): then the panel shows that refusal's text in the button's
    place, with the command that changes the email,
    `agent-balancer config set <label> email <address>`, and a Copy button. A row whose
    `signInCheck` is null (a folder no check has read yet) reads by the tier rule alone. A linked
    row with no `signInCheck` key (the window reads a value that is not a string the same way)
    comes from a writer that kept the tier through a doubt, so it reads by the tier rule only
    while it shows no code that can hide one: with `check_failed`, or with `account_ended`,
    `settings_changed`, `not_linked`, `duplicate_login` or `plan_changed` (each can stand over
    `check_failed`), it reads "Sign-in not confirmed" with no Sign in. Such a row that is not
    linked reads "Not signed in" with its link step and Sign in off. A plan tier that is not the
    plain shape counts as none. An ended folder keeps its sign-in line, and its list row says it
    has ended ("Signed in · ended Nov 1" once its end date has passed, "ended" with no date
    before then, as for a plan that dropped, and ", ended" for VoiceOver). A token account has no
    such evidence (its row carries no tier), and any code on its row could hide one that says it
    is signed out or unconfirmed: `account_ended` hides every other code, and every other code
    the tool writes ranks above `check_failed`. A token account therefore counts as signed in
    only while its row is `ok` or `limited` with no code. A login account counts only by its
    plan tier, as a folder row does, while its row is `ok` or `limited` with no code or shows
    `plan_changed` or `duplicate_login`, which say nothing against the sign-in; that tier follows
    the email rule above, so after its email changes, by `config set` or by a hand edit of
    `config.json`, a login row never reads as signed in until a check places the new email's
    sign-in. Such a login row with no tier reads "Sign-in not confirmed" in the list and the
    panel, and its panel shows no problem when the row has no code. Otherwise the panel reads
    "Account ended" for an ended row, whose list row reads
    "Ended Nov 1" once its end date has passed and "Ended" before then, and the list and the
    panel read "Signed out" for `login_rejected` or `token_missing`, "Signed in as another
    account" for `wrong_account`, and "Sign-in not confirmed" for any other code, `check_failed`
    and any code the window does not know included, each with a red dot. A signed-in token with
    no end set reads "N days left", "1 day left" or "Less than a day left" in the list until its
    estimated end, and "Signed in" after it, never "Expired": a token whose probe still works is
    signed in whatever the estimate says. On every "Sign-in not confirmed" and "Account ended"
    panel, the row's own error, through the display-safe pass, is the problem that says why,
    with no steps, except an ended folder its last check placed (below) and a folder whose
    `signInCheck` is `not_confirmed`: the latter's problem is "Check failed" with "The last
    sign-in check could not confirm the sign-in in this folder.", whatever
    code the row shows, or the row's own error when that is the one for a sign-in that reported
    no email. An ended folder that reads as signed in or not signed in shows its own
    `account_ended` error as the problem; one that reads as another account's, or as not
    confirmed because its last check could not place the sign-in, shows that problem followed by
    its own `account_ended` text, and its list row still says it has ended. An ended folder its
    last check placed, with a doubt since that the end hides, gives its own `account_ended` text
    followed by "Its sign-in has not been confirmed since the last check and may have been
    rejected. If so, sign in again.", with the steps "Open Terminal." and "Run the command below
    and sign in." and `agent-balancer login <label> --browser`. The `wrong_account` problem lists
    the menu's steps for that code less "Choose Refresh now.", which only the menu has. A login
    account signs in in the default folder, and `agent-balancer login` refuses it, so its
    `wrong_account` step in the menu and the window is "Run claude and sign the expected account
    back in.", its `login_rejected` steps in the menu say to run `claude` and sign in again, and
    its menu row has no Open Manage accounts action. The token panel offers Sign in again in
    every state, and the Add sheet's token sign-in step reads done only while the account counts
    as signed in.
  - **Add sheet:** the folder steps follow the status: Share settings reads done once the folder
    is linked, and Sign in stays off until then, while the folder reads as another account's or
    as not confirmed, and while its expected email fails the plain-email rule, when the step gives
    the panel's reason, and reads done only while the window counts the folder as signed in. The
    sheet shows why Add is off once management is off, in place of an earlier run's error, as
    when the CLI goes missing while the sheet is open.
    Cancel and Esc are off on both sheets while their command runs, and the view model refuses to
    close a sheet then; a sheet replaced while a command runs keeps the new form and starts no
    sign-in.
  - **Renders and the design frame:** the render scenes draw the window as design/render.html
    does, with these forms kept. The login account's list row reads "Your login" in every frame,
    as the token frame has it, where the folder frame reads "Signed in". Once an account is
    added, the Add sheet dims its Kind and Ends choices and draws its Label and Email fields off,
    as the live sheet disables all four, where the frame draws them on. Every scene row is one
    the status writer can produce, so the folder frame's signed-out folder shows no plan tier on
    its email line, where the frame adds "Ultra": the writer keeps no tier while a check or probe
    says the sign-in is gone. The shared-settings tip reads as the frame's.
  - **Display-safe text:** every string from `status.json` that the menu or the window shows
    (labels, emails, end dates, error and warning codes and texts, the banner, the next-launch
    labels and reasons) passes the display-safe pass, so a control or bidi character shows as an
    escape and an over-long value is cut, and so does the tool's output in the bar. The window
    lists only accounts whose label is a plain label, shows a plan tier only in the plain tier
    shape, and shows and copies a folder path it makes from the label and the data folder, never
    the status file's `configDir`. A signed-out account shows when the tool first saw it signed
    out (`stateSince`), as "Signed out at 12:40 PM" or "Signed out since today, 12:40 PM".
- **Look:** system font, vibrancy material, macOS menu spacing, light and dark from the system,
  hover highlight on rows, full keyboard navigation, VoiceOver labels on meters.
- **Data:** reads `~/.agent-balancer/state/status.json` and checks whether `config.json` exists.
  The menu reads `status.json` every 5 seconds. While the Manage accounts window is open it reads
  the file on the same beat, when the window or one of its sheets becomes key, and after every
  command it runs, so a sheet follows a `link` run in Terminal. The timed reads stand in for a file
  watcher because the safety scan lets no source outside `Paths/` open a file. It writes
  no file and never runs `claude` itself. Open usage page goes through the SwiftUI `openURL`
  action, and Open at login through `SMAppService`; the app keeps no preference store.

## 12. Install, update, uninstall

- **Install:** the CLI with Homebrew from the project's tap. The app ships as a zip attached to
  the GitHub release; the README gives the unzip, drag to Applications and Open Anyway steps.
- **Skill file:** the formula installs the skill folder, `skill/agent-balancer/` with its
  `SKILL.md`, at `$(brew --prefix)/share/agent-balancer/skill/agent-balancer`. The README gives
  the one line the user runs to link that folder into `~/.claude/skills/`; the tool never writes
  inside `~/.claude`.
- **First run, in this order:**
  1. `agent-balancer init [--label <label>]` creates `~/.agent-balancer/` (0700), reads the
     default folder with `auth status`, asks for that account's label (`--label` is required when
     not interactive), records the email `auth status` shows as its expected email, and writes
     `config.json` with that account as a `login` account with role `pool`, deleting a reading
     another account left under that label (6.3). It also always writes the hook record (5.7).
  2. `agent-balancer refresh`, then open the app: the first account shows at once.
  3. `agent-balancer add <label> [--email <address>] [--ends <date> | --ending-soon]` writes the
     registry entry of a `token` account, deletes a reading another account left under the
     label and creates no folder (4A.4).
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
  changes one field with a dated backup. On a `login` or `folder` account, an email that differs
  from the stored one, compared without letter case as the sign-in check compares them, also
  forgets the recorded plan (`expectedPlanTier`, 7.1) in the same write that saves the new email,
  and deletes the label's stored reading just before that write (6.3), under the pick lock and the
  label's probe lock. A change refused before that delete, such as one whose value is not an email
  address or one that cannot have the probe lock, and the same email again keep both. A change
  that the registry save refuses, such as while another folder account's folder is wider than
  0700, keeps the email and the plan but has deleted the reading, and it runs no status rebuild,
  so the next probe reads the account anew and the next rebuild can record `limit_cleared` (6.3).
  Once the new email is saved, the
  old reading and plan are gone whatever the sign-in check that follows reports, and when that
  check places the new sign-in it records the new plan. A rename of a `login` account moves its
  reading and its open leases to the new label once the registry is saved, so a rename that the
  save refuses moves nothing (4A.4). The tool never logs in for the user.
- **One account per folder, for good.** A folder is signed into one account and stays on it,
  because saved thinking from a model works only in the account that produced it, and a chat that
  meets a second sign-in loses it. `login <label>` runs only while the folder is logged out, or
  while a probe's `login_rejected` stands, and checks the email afterwards. It exits 1,
  and says so, when `auth status` cannot be read, when the folder is not signed in, when the
  check fails at error level (`check_failed`, such as when the folder cannot be confirmed as its
  own or the sign-in reports no email for an account with an expected one), when the folder
  holds a different account (`wrong_account`, a wrong email), or, over a sign-in the probe found
  rejected, when the run cannot show a new sign-in (a run without `--browser`, or a
  `claude auth login` that did not exit 0): the probe's `login_rejected` then stands. A plan
  other than the expected one is reported as `plan_changed` and leaves the exit status at 0.
  `add`, `login` and the README print "Never sign a different account
  into a folder that already has chats. Add a new folder for the new account instead." A folder
  found on another account shows `wrong_account`, drops out of `pick`, and its fix text says to
  sign the expected account back in, not to relabel the folder.
- **Unsigned app:** the README shows the unzip, drag and System Settings, Privacy & Security, Open
  Anyway steps. The app needs Open Anyway after the first install and again after each upgrade
  until it is signed.
- **Update:** `brew upgrade` for the CLI; the app is replaced from the new zip. Config carries
  `schemaVersion`; the CLI migrates forward and keeps a dated backup.
- **Run:** `agent-balancer run <label> [--print-command] [-- <claude arguments>]` starts Claude Code
  on the named account, for a person. It runs the kind's checks of 4A.5 without the reading check
  (a new account starts before its first reading), refuses when they fail even for an explicit
  label (`token_missing` for a missing or widened token file, `login_rejected` for a logged-out
  login or a token whose probe's `login_rejected` stands), takes a lease and writes one launch
  file under the pick lock as `pick` does, and starts
  `claude` with the terminal attached and the environment of 6.2 for a person: the user's own minus
  the protected group. The settings checks come from the verdict a reader saved, and `run` refuses
  when it is missing or older than the file (4A.5); it opens no settings file. The argument array is
  `--settings <launch file>`, then the person's arguments (4A.2), which refuses a `--settings` of
  their own and a first argument that is a `claude` command name. It writes one `state/picks.log`
  line, and drops the launch file and lease when `claude` cannot be started. The exit status of
  `claude` is the exit status of `run`. `--print-command` is a typing caller (4A.2): it applies the
  ambient rule, the inherited credential rule and the two typed refusals (4A.3 rules 5 and 6),
  prints the literal line (`claude`, `launchArgs`,
  then the person's arguments quoted) and starts nothing; the line names the launch file and never
  holds a token. In a chat shell `run`, with or without `--print-command`, prints the line to type in
  your own terminal, `agent-balancer run <label> -- <arguments>` (arguments display-safe and shell
  quoted), on standard output and the refusal on standard error, writes nothing (no launch file, no
  lease, no token read), never starts `claude` and exits 1 (5.1). `run` never picks an account, and
  an orchestrator never uses it.
- **Uninstall, in this order:** quit the menu bar app, then run `agent-balancer uninstall`, then
  delete the app from Applications, then `brew uninstall agent-balancer`. The app runs `refresh`
  and `status` on timers, and a refresh that saves during or after `uninstall` can make the data
  folder again. `agent-balancer uninstall` lists what the tool created as
  counts, never names or paths: the launch files and how many of them a session record still names
  ("N or more" when the session records cannot all be read), the token files, the writer's temporary
  files that may hold a token, state (`state/events.jsonl` and `state/history/` included), logs,
  backups, probe files, the links and `links.json`, the config, the writer's temporary files of the
  config and `links.json`, and the lock files (and the LaunchAgent with its `launchctl bootout` line
  once one exists). The state, log, backup, probe and lock counts are of the files the removal
  deletes, by the name rules of step 4; the removal also deletes the pick lock it takes and the
  links lock that clearing `links.json` or deleting a temporary file of it takes, each of which it
  makes when it is missing, so it can delete one or two more files than it listed, and a temporary
  file in `state/` that turned a minute old while the list was on screen (step 4). It says so when
  the session records or the lease file cannot be read, since every launch file is then kept. It
  says how many temporary files in `state/` a save may still be using (step 4), so a data folder
  that holds only such a file is not reported as having nothing to remove. It also says how many
  entries in `tokens/` or `launch/` have the name of a token file or of a label's folder only in
  other letter case, such as `Pool-a.json`: on a volume that ignores case a save writes into such
  an entry and keeps its spelling, so each may hold a token. A name that differs only by
  characters Unicode marks as default ignorable, such as a zero-width joiner, counts too, since a
  Mac OS Extended volume ignores some of them in a name. `uninstall` never opens or deletes one;
  the closing text gives the count again and says to rename each to the tool's spelling or move it
  out of the data folder, then run `agent-balancer uninstall` again.
  It also says how many entries in `launch/` sit where a label's folder belongs but are a link, a
  file or another user's folder: a launch file with a token may be behind one, such as a label's
  folder moved elsewhere and linked back. `uninstall` skips and counts each and never follows it;
  the closing text gives the count again and says to move the folder each link points to back in
  place of the link, delete a link that points nowhere and move any other entry out of the data
  folder, then run `agent-balancer uninstall` again.
  On a line of its own it says how many entries in `launch/` where a label's folder belongs `lstat`
  cannot check, such as a label's folder whose access list denies its owner `readattr`: the run
  cannot tell what such an entry is, so it does not refuse it, and a launch file with a token may
  be in it. `uninstall` counts each with the entries it does not follow and never opens it; the
  closing text gives that count on its own and says to run `chmod -h -N` on each entry there, or
  `chmod -N` where that says Permission denied, then run `agent-balancer uninstall` again. Such an
  entry may be a link with an access list of its own, and `-h` makes `chmod` act on the link
  itself, not on the folder it points to. `chmod -h -N` opens the entry, so it says Permission
  denied where the access list also denies its owner `read` (`list` on a folder); plain
  `chmod -N` does not open the entry and clears that list.
  Before it lists anything, and again before the removal starts, it refuses, removes nothing,
  follows nothing and exits 1 when the data folder, `tokens/` or `launch/` is there but is not a
  real folder of the user's that passes the folder checks (a link, a file, another user's folder,
  an entry `lstat` cannot check, or a folder wider than 0700 or one the user cannot open or search,
  such as one at 0600 or one whose access list denies its owner `list` or `search`), or when a
  label's folder in `launch/` is a folder of the user's that is wider than 0700 or cannot be
  opened or searched, since a token file in it could be neither counted nor deleted. The message
  names the folder, the problem and what to do, such as moving the folder a link points to back in
  place of the link, `chmod 700` on a folder wider than 0700, `chmod -N` and then `chmod 700` on
  one that cannot be opened or searched, or, on an entry `lstat` cannot check, such as one whose
  access list denies its owner `readattr`, `chmod -h -N`, or `chmod -N` if that says Permission
  denied, and then `chmod -h 700`. `chmod -N` removes an access list, which `chmod 700` leaves in
  place. A folder wider than 0700 or one that cannot be opened or searched is one `lstat` showed as
  a real folder, never a link, so its commands need no `-h`, and plain `chmod -N` clears its list
  without opening it. An entry `lstat` cannot check may be a link, so `-h` makes each command act
  on the link itself; `-N` comes first because `chmod -h 700` fails as long as `lstat` cannot
  check the entry, and `chmod -h -N` opens the entry, so where the access list also denies its
  owner `read` it says Permission denied and plain `chmod -N` clears the list. Neither clears the
  access list of a link whose own list denies its owner `read`: `chmod -h -N` cannot open it, and
  `chmod -N` acts on what it points to, so the rerun stops again. Only a `chmod -h +a` on the link
  itself makes such a link, since a new link takes no entry from its folder. A data folder in a
  home the user cannot search cannot be checked either, and no command on the data folder reaches
  it until the home can be searched again. A missing data folder has nothing to remove. It then
  removes its own files only after the typed word
  `uninstall` in the user's own terminal (refused in a chat shell, 5.1). Once it holds the pick
  lock, the removal reads the session records and the config's `picker.leaseMinutes` again, so a
  session that started while the list was on screen keeps its launch file; the list may still show
  the earlier count, and the lease window is never shorter than the one the list named. Account
  folders and their logins belong to the user and are never deleted. `uninstall` says the tokens
  themselves may keep working until their year ends, because no way to cancel one is documented, and
  that kept launch files hold no token and go on a rerun once nothing names them and the lease
  window a rerun starts from has passed since that run. A rerun reads `picker.leaseMinutes` from the
  config as the first run does; a run that finishes has deleted the config, so a rerun starts from
  the default of 10 minutes, and the closing text names the minutes a rerun will use (each run
  overwrites a kept file again, so a rerun inside the window keeps it). `uninstall` exits 0 once the
  removal is done or when there is nothing to remove, and 1 when it refuses (in a chat shell, or a
  folder it cannot check), when the typed word is not `uninstall`, when it stops before the token
  files (such as at the read-back of step 1, or on a pick lock it cannot take), or when a token file
  or a temporary file that may hold a token could not be checked or deleted, or it left an entry
  that may hold one unopened (one named like a token file or a label's folder in other letter case,
  or a link, a file, another user's folder or an entry `lstat` cannot check where a label's folder
  belongs in `launch/`), after the closing text says so. Entries it did not make, kept
  tombstones, temporary files in `state/` it keeps (step 4) and other files it could not delete
  do not change the exit status; a `state/` link does not either, since no token is ever written
  there. The steps, in this order:
  1. Under the pick lock, every launch file of every label is deleted, except a file that a
     session record still names, that an open lease holds, or that is younger than
     `picker.leaseMinutes`, and except every file when the session records cannot be read
     cleanly or the lease file is there and cannot be read or decoded. Each such file is
     overwritten with a token-free tombstone and kept, with its folders, exactly as `remove`
     keeps one (4A.4). A read-back then proves that no launch file holds a token. When one does,
     or a launch file cannot be overwritten with a tombstone, `uninstall` stops with exit 1 and
     deletes no token file and nothing after it, and its text says, on each label's folder in
     `launch/` that is not a link, to run `chmod -h -N` and `chmod -h 700`, and `chmod -h -N` on
     each file directly in it, or `chmod -N` where that says Permission denied, with
     `chflags -h nouchg` first on any of them that is locked. That clears a folder that is not
     writable, a lock, and an access list that denies the owner, set on a file or a folder or
     inherited from the folder, so a rerun gets past this step; a temporary file that a failed
     tombstone write could not delete is counted in step 3 with its own text, and a label's
     folder that cannot be searched is refused on the rerun with its own text, as above. Those
     label folders passed the folder checks, so `chmod -h -N` opens them, and a link where a
     label's folder belongs is counted on its own, so no command the text names acts on the
     folder a link points to or on the files in it. A launch file's name that `lstat` cannot
     check, such as a file whose access list denies its owner `readattr` or one in a label's
     folder that stopped being searchable after the check, counts as one that does. A link, a
     file, another user's folder or an entry `lstat` cannot check where a label's folder belongs,
     and a folder named like a label only in other letter case, are never followed or opened:
     each is counted on its own, the run goes on, and it exits 1 at the end.
  2. Every token file goes: a regular file owned by the user named `<label>.json` directly in
     `tokens/`. A token file that cannot be deleted, such as in a `tokens/` folder that is not
     writable or whose access list denies its owner `delete_child`, or one that is locked, still
     holds its token, and a token file's name that `lstat` cannot check, such as a file whose
     access list denies its owner `readattr`, may hold one: each is counted on its own, the
     closing text says to run `chmod -h -N` and `chmod -h 700` on `tokens/`, and `chmod -h -N` on
     each token file in it, or `chmod -N` where that says Permission denied, with
     `chflags -h nouchg` first on any of them that is locked, then run `agent-balancer uninstall`
     again, the run exits 1, and the rerun lists it. An entry named
     like one only in other letter case, and a folder in `launch/`
     named like a label only in other letter case (step 1), stay unopened and are counted on
     their own.
  3. The writer's leftover temporary files (`.tmp-<16 hex>`) in `tokens/`, in the launch folders
     and directly in the data folder go, then each token or launch folder that is left empty. One
     in `tokens/` or a launch folder may hold a token: when it cannot be deleted, such as in a
     folder whose access list denies its owner `delete_child`, or `lstat` cannot check it, such
     as one whose access list denies its owner `readattr`, it is counted on its own, the closing
     text says, on each folder that holds one, `tokens/` or a label's folder in `launch/` that is
     not a link, to run `chmod -h -N` and `chmod -h 700`, and `chmod -h -N` on each temporary file
     in it, or `chmod -N` where that says Permission denied, with `chflags -h nouchg` first on any
     of them that is locked, the run exits 1, and a rerun lists it. One directly in the data
     folder comes from a save of `config.json`, which holds the pick lock, or of `links.json`,
     which holds the links lock, so those go only while the links lock is held too; when it
     cannot be had within 30 seconds they stay and are counted.
  4. State, logs, backups and probe leftovers go, by these name rules, each taken from the code
     that writes the file:
     - `state/`: `status.json` and `current.json` (the status rebuild), `events.jsonl` and the
       damaged records it sets aside, `events-damaged-<seconds>-<4 hex>.jsonl`, `leases.json`,
       `picks.log`, `settings-seen.json`, `readings/<label>.json` and `history/<label>.jsonl`, and
       the writer's temporary files in `state/`, `readings/` and `history/` once they are a minute
       old. Their writers (the status rebuild, a reading save, the settings verdict save) hold
       another lock than the pick lock, or none, so a younger one, or one dated ahead of the
       clock, may belong to a save that is still running. It stays, the listing and the closing
       text count it on their own, and a run once it is a minute old deletes it: for one dated
       ahead of the clock, a run a minute or more after that date. While such files are all that
       is left, `uninstall` lists them and does not say there is nothing to remove; the closing
       text says to quit the menu bar app and run `agent-balancer uninstall` again in a minute.
     - `logs/`: `agent-balancer.log`.
     - `backups/`: `config-<yyyy-MM-dd>.json` and `config-<yyyy-MM-dd>-<n>.json`, and the writer's
       temporary files.
     - `probe/`: each `p-<16 hex>` folder a probe made, with every regular file in it and in its
       folders.
     - `locks/`, in step 7: `pick.lock`, `links.lock`, `history.lock` and `probe-<label>.lock`.

     `<label>` is a label the tool accepts (5.2), and `<16 hex>` and `<4 hex>` are 16 and 4 of the
     ASCII characters `0-9a-f`. `<yyyy-MM-dd>` is a real date of the Gregorian calendar with a
     four-digit year, `<n>` a number from 2 up and `<seconds>` a whole number, each written the
     way its writer writes it, with no leading zero, no `+` and no `-0`. Those two rules take a
     name apart and build it again with the writer's own code, and only the same name passes, so
     `config-2026-11-13-1.json`, `config-2026-11-13-02.json`, `config-2026-02-31.json` and
     `events-damaged-007-abcd.jsonl` are not the tool's. Every name is matched against the ASCII
     characters its writer uses, so a name spelled with a look-alike character, such as a
     fullwidth digit, or in other letter case, is not the tool's. In these
     folders only a regular file owned by the user with one of these names goes, and only a folder
     named here is opened. Every other entry, a file you put there included, stays where it is and
     is counted.
  5. Each link listed in `links.json` goes only while `lstat` shows a symlink directly inside
     `accounts/<label>/.claude/` with the recorded target. A path that is now a regular file, a
     folder or a link to somewhere else stays. The links and linked labels in `links.json` are
     then cleared, so a file that stays lists none; a `links.json` that cannot be saved, such as
     one of another schema version, is not cleared and does not stop the run.
  6. `links.json` goes, then `config.json`, the last file deleted under the pick lock.
  7. The pick lock is let go, and the lock files go.
  8. The data folder goes when nothing is left in it, through one `rmdir` that never follows a
     link and never removes a folder that holds anything. `accounts/`, a kept tombstone or any
     entry the tool did not make keeps it, and each entry directly in it whose name the tool
     never writes there is counted. One the volume takes for one of the tool's names, such as a
     file `Logs` where `logs/` belongs on a volume that ignores case, is counted once, by the
     step for that name.

  Only the steps before the token files can stop `uninstall`; once it deletes them it never
  stops. Nothing is followed: a link, a file or another user's folder where `tokens/` or
  `launch/` belongs is refused before the listing, as above; one where a label's folder in
  `launch/`, `state/`, `logs/`, `backups/` or `probe/` belongs, and any entry inside the tool's
  folders that the tool did not make, stays where it is and is counted. One where a label's
  folder belongs also makes the run exit 1 once every step is done, since a launch file with a
  token may be behind it. A folder of the tool's that is not private (wider than 0700) is never
  opened either:
  `tokens/`, `launch/` or a label's folder in it that is one, or that cannot be opened or searched,
  is refused before the listing and again before the removal starts, as above, since it may hold a
  token that cannot be checked; any other stays and is counted, unless it is empty, when it goes
  like the tool's other empty folders and is not counted. A folder nested more than eight levels
  deep is counted and not opened. A `locks/` folder that is a link stops `uninstall` before
  anything goes, because the pick lock cannot be taken.

  Why a named file is kept as a tombstone and not deleted: a session record that names a
  launch file may belong to a session that still reads the file, so the record keeps naming a path
  that must stay in place, as for `remove` (4A.4). A tombstone holds the token variable set to
  `invalid` and the account label, so a session that reads it fails to sign in instead of falling
  back to the stored login of the default folder, which is another account. After `uninstall` no
  launch file it can reach holds a token, whether or not a session record names it. It never
  follows a link, opens a file, enters another user's folder or opens an entry `lstat` cannot
  check where a label's folder belongs in `launch/`, and never opens a folder there named like a
  label only in other letter case; a launch file with a token may be behind any of them, so it
  counts each, says what to do and exits 1. Only `agent-balancer uninstall` and `remove` delete
  token files in bulk, after the typed word.

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
  links.json                       0600   link manifest: `links` (each a `path` and the `target` it
                                          points to), `linkedLabels` (the folder accounts a `link`
                                          run finished for, an empty list of links included) and
                                          the hook fingerprint at link time. Every change takes
                                          `locks/links.lock` for the whole read and write, and a
                                          change refuses, writing nothing, when the schema
                                          version is not 1 or the link list or the linked labels
                                          do not decode (and, for a links change, when the hook
                                          record does not decode or holds a hash that is not 64
                                          lowercase hex digits). `link --accept-source-change`
                                          replaces a damaged hook record and keeps the links.
                                          A `link`, `link --repair` or `unlink` also writes
                                          only while the account's entries are still the ones
                                          the person was shown
  state/status.json                0600   last merged status (what the menu reads)
  state/readings/<label>.json      0600   last reading saved under the label, with source and time
  state/picks.log                  0600   one line per pick: time, model, label or none, lease id
                                          or `-`, reason; no line for a dry run
  state/history/<label>.jsonl      0600   readings history, one JSON line per changed reading (10.4)
  state/events.jsonl               0600   a header line with the record id, then state changes, one
                                          numbered JSON line each (10.3)
  state/current.json               0600   each label's current state, error code and since times, the
                                          last sign-in and probe errors, what the last sign-in check
                                          saw and the digest of the account and email it was made
                                          for (SHA-256 of the account key, a NUL and the lowercased
                                          email; never the email), the label the last duplicate
                                          check matched (4A.4), and what the settings file last showed
                                          (10.1; labels, codes, times, scrubbed text and that digest
                                          only)
  state/settings-seen.json         0600   the verdict a reader saved for `run`: hook entries,
                                          `disableAllHooks`, a key flag and the settings file's
                                          stamp (4A.5); no env name and no value
  state/leases.json                0600   open leases (internal id, label, model, time), pruned
  probe/                           0700   one fresh temporary folder per probe, removed afterwards
  locks/probe-<label>.lock        0600   one probe at a time per label, also held while an email
                                          change, a token save, a rename, `add` or `init` moves
                                          or deletes the label's reading (6.3)
  locks/pick.lock                  0600   one pick decision at a time (section 7.2 rule 7)
  locks/history.lock               0600   one writer at a time for the history and events files
  locks/links.lock                 0600   one writer at a time for links.json
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

Token and launch files are an exception to "never remove a regular file": the tool made them,
so `remove`, a token replace, the upkeep rule and `uninstall` delete them, and only them: a path
directly under `tokens/` named `<label>.json` or directly under `launch/<label>/` named
`l-<8 hex>.json`, opened through the same folder handles, that `lstat` shows as a regular file
owned by the user, the writer's own leftover temporary files there included. The other exception
is `uninstall`, which also deletes the tool's own files in `state/`, `logs/`, `backups/`, `probe/`
and `locks/`, by the name rules of section 12, `links.json`, `config.json` and the writer's
temporary files of those two, and nothing else. `remove` also deletes the label's stored reading and its empty launch folder through the
same writer, and a token save, an email change on a `login` or `folder` account, `add` and
`init` delete a label's stored reading, and a rename moves one, the same way (6.3).
A token file is written whole to a random temporary name in `tokens/` and renamed into
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
When the events step fails, the rebuild keeps the old `current.json`, so the next rebuild finds
the same changes again (a change only a probe or a sign-in check saw, only when a later probe or
sign-in check of that account sees it; 10.3); the history step still runs, and because an append
that matches the file's last line writes nothing (10.4), the rerun writes no history line twice.
If `current.json` cannot be written after the events were saved, the next rebuild writes those
events again (with the same exception). If the state has gone back by the time a rebuild could
find a change again, it writes nothing: the history, and the events record unless its own step
failed, keep a change the state no longer shows until the label's next change (10.3).
A last line that does not parse is cut off under the lock and logged. An events line in the middle
that does not parse, or whose `seq` does not rise above the previous one, marks the file damaged:
it is written aside under a new name, a new record with a new `recordId` starts, and `seq`
restarts at 1. An events line with a value the tool never writes (a label that does not match the
label pattern of 5.2, `\A[a-z0-9][a-z0-9-]{0,31}\z`; a type, code or window outside its list; or a
`seq` below 1 or at or above 10^12) counts as a line that does not parse, and an events
header whose `recordId` is not `r-` and six lowercase hex digits counts as a missing header. A
history line in the middle that does not parse, or whose state or source the tool never writes,
is skipped by readers. A rewrite of a history file (to cut its last line, or to prune it) drops
every such line and logs how many it dropped, never their text: such a line has no time that
retention could age out, and its content is unknown. A prune of the events record that drops a
last line that does not parse logs it the same way. A `state/current.json` that does not parse,
or holds a label, state, code, window, plan tier, date, sign-in check result or digest the tool
never writes, is logged and started over. Lines older than `history.retentionDays` (default 35)
are dropped by rewriting the
file through the same no-follow writer, at most once a day; the newest events line of each label
is always kept. Retention counts back from the earlier of the clock and the newest stored reading
of a configured account that has a `five_hour` or `seven_day` reset time at most 270 seconds
before the reading's own time, and every history file and the events record count back from that
one time. It never counts back from the clock alone or from any other reading: with a retention
above 0, while no configured account has a stored reading that loads and has such a reset time,
nothing is pruned, and a prune that falls due waits for the first rebuild that has one. With
`history.retentionDays` 0 a prune counts back from no time (every history line goes, and the
events record keeps each label's newest line), so it does not wait. So the history of a removed or
renamed label, or of an account whose probes keep failing, ages out once both the clock and the
newest such reading of a configured account are more than `history.retentionDays` past its last
line; while no configured account gets a newer one, the time retention counts back from never
passes that reading. The cost: while the newest reading of every configured account has no such
reset time, no line ages out, a removed label's included. A clock moved forward prunes nothing by
itself. A reading taken while the clock runs ahead is dated ahead too and moves the cutoff ahead
by as much as the clock was ahead, until the clock is set right. The reset times bound that. The
service puts a window's reset time at most one window length after the real time, a reading
keeps only reset times that probe replies gave, and a reading file stores each rounded to the
nearest minute, so at most 30 seconds after the time the service gave; this version and every
earlier one round the same way. A reading that counts is dated at most 270 seconds after such a
stored time, so at most 300 seconds after the time the service gave: at most 5 hours 5 minutes
ahead when its `five_hour` reset time is at most 270 seconds before its own time, and at most 7
days 5 minutes ahead otherwise. So for every reading file this version or an earlier version
saved, a line younger than `history.retentionDays` minus 7 days 5 minutes always stays: with the
default 35 days, every line from the last 27 days 23 hours 55 minutes. An edited reading file is
bounded only by what the edit wrote: the history and events files are information, never
authority (section 14, T18). The 270 seconds are the 300 of the range of 6.2 less the 30 that
rounding can add, because an earlier version checked only the minute it stored, so its file can
hold a reading dated 300 seconds after that minute and 330 seconds after the time the service
gave. The cost: a reading this version records keeps no `five_hour` or `seven_day` reset time
more than 300 seconds before its own time (the range refuses an earlier one in a reply, and the
merge, which judges a stored reset time at the new reading's own time, the clock read when its
probe ended and never a later one, keeps a stored one over the reply's only while it is still
ahead of that time or not earlier than the reply's), yet one whose such reset times are all more
than 270 seconds before its own time does not count, so retention counts back from another
reading that does or waits for one, which never prunes more. A clock moved back prunes only lines
older than its own cutoff, and a prune time saved more than 60 seconds ahead of the
clock counts as due, so pruning does not stop until the clock catches up. The files hold labels,
percentages, times, states and scrubbed texts only: no email, no organization id, no session
name, no path. With five accounts and the 15 minute floor of 10.4 they stay under about 5 MB.
The rebuild after `remove <label>` writes an `account_removed` event and leaves that label's
history to age out. `uninstall` removes the files with the rest of `state/`.

## 14. Threat model

**Assets:** (1) Claude logins (Keychain entries and fallback files), which the tool never reads,
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
| T16 | A same-user process, a chat included, edits files under `~/.agent-balancer/` to skip consent, pass `verify`, move the main role, drop the reserve, forge a reading, or make the tool run a program of its choosing | No executable path is read from any file in the data folder; the `verify` cache lives in process memory only; config changes that move protection (`set-main`, `set`, `remove`) refuse in a chat shell. Against code that runs as the user this is advisory, and these bounds are left: the probe starts `claude` in its probe folder by path, so a process that swaps that folder for a link in between chooses where it starts; a render that a change of a home's tool folder stops leaves the output folder it made, empty when the change came before the first file; and `remove` takes a label only, so an account removed and added again with the same label, kind and email between the window's read and the run is the one removed |
| T17 | A planted symlink redirects one of the tool's writes or deletes | No-follow, handle-relative writes and symlink-only removal (section 13) |
| T18 | The history and events files expose usage patterns, or a same-user process forges or deletes lines to mislead a caller | 0600 files that hold labels, percentages, times and scrubbed texts only; a retention cap; the leak test reads both files. The files are information, never authority: `pick` and `verify` decide from live checks (for a token account, `pick` also from the probe rejection `state/current.json` records) and never read the history |
| T19 | A chat uses the Manage accounts window to add, remove, re-date or sign in an account: it starts the app itself, or drives the window by scripting the screen | The window runs six command shapes only and none that shares hooks or moves protection; it turns management off when its environment carries the chat-shell variable; the app has no scripting surface |
| T20 | A stored token is read by another process that runs as the user, by a backup or by a sync tool, and stays usable for up to a year | 0600 files in 0700 folders; `tokens/` and `launch/` are marked as excluded from backups; `doctor` warns when the data folder sits inside a synced folder. Against code that runs as the user this is advisory, and it is the same exposure as Claude Code's own fallback credential file |
| T21 | A token reaches output: `pick`'s JSON, an error text, a log line, the history, the app, a crash report | Only the `Tokens` and `Launch` modules read a token, and they return paths, never values. `pick` prints the launch file's path only. The scrubber runs on every captured buffer; `TokenCapture` reads the `claude setup-token` child's raw output first |
| T22 | A caller's settings JSON carries a key that switches hooks off, changes permissions or chooses another account, into a launch file not visible in the typed line | `pick` accepts only allowlisted top-level keys (`env` by default) and only `env` names listed in `launch.envNames` (empty by default), never the protected names such as `CLAUDE_CONFIG_DIR`, the login locations, any `CLAUDE_CODE_*` name, `PATH`, `NODE_OPTIONS`, loader, proxy and certificate variables, and refuses without writing anything (4A.2). The config lists may hold only those keys and names, checked when the config loads and at pick time |
| T23 | Launch files pile up, each with a token, or one outlives its account | The upkeep rule in 4A.6; `remove` deletes every file of the label; a token replace rewrites them; `uninstall` removes both folders, or says what it left that may hold a token and exits 1; `doctor` prints the count and the oldest age, never a file's content |
| T24 | Something in the caller's environment beats the recipe: a worker bills another account, or lands in a folder with no hooks | The ambient rule (4A.3): folder-only picks under an inherited `CLAUDE_CONFIG_DIR`, `backgroundOnly` under an inherited credential name, a refused typed line under a stored-login name or a hooks-off name, `unsetEnv` for launchers, and a person launch without the protected group. The post-launch check in section 16 item 4 catches a launch that landed in the wrong folder. The profile base folders `HOME` and `XDG_CONFIG_HOME` stay (6.2) |
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
  name, a `/Users/<name>` path, and a second OAuth-shaped token in the shape recorded for a real
  one: 108 characters with dashes) in every input a later slice adds (fake `claude`
  stdout and stderr, an extra `auth status` field, the probe `result` error text, a `settings.json` `env`
  value, the parent environment, a token file's value, fake `setup-token` output, a pasted token,
  a caller's settings JSON). It runs every command against every scenario, collects stdout,
  stderr, logs and written files, and fails on any canary outside a token file and that label's
  launch files, on any token-like match, and on any email outside `example.com`. A canary split
  across two 4 KB reads is still caught. A positive control proves the detector fires. Planted
  tokens and planted safety violations are assembled at runtime from split strings, never stored
  whole in a file. The same file runs the leak shapes as patterns (a token or token-like run, an
  org id or org field, an address other than a made-up account's at example.com (one leading
  hyphen allowed, as in the README check), a path the
  fixture does not own, a named session) over every chunk of the README pictures but their pixel
  data, compressed text inflated, and over the scene sources the pictures are drawn from.
- **Safety script tests:** `scripts/check-safety.sh` is tested with planted violations for each
  rule, assembled at runtime in a temporary tree. The script passes on the real tree. Its address
  and org id scans also read the Markdown files at the top of the repository, and its attribution
  scan reads them all, `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md` included.
- **Fixtures:** probe and auth fixtures are recorded from real runs, then scrubbed and relabeled
  to `example.com`; unit normalization (0 to 1 versus 0 to 100) has its own tests.
- **Golden JSON:** `status --json`, `pick --json`, `events --json` and `history --json` outputs for
  fixed scenarios, so schema changes show up in the diff.
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
   `status --json` may run `auth status` and never probes (only `refresh`, `pick` and a token
   account's `login` probe). Never parse the menu or logs.
8. **What changed:** `agent-balancer events --json --after <cursor>`. Keep the `cursor` from each
   call and pass it back, and call again while `more` is true. A `recordId` you have not seen
   means the record was started over: treat it as a gap. On `gap: true`, read `status --json`
   once and carry on from the new `cursor`. An event can come more than once, with a new `seq`
   (10.3): read each event as the state it reports for its label, never as a count, so a repeat
   changes nothing. After a failed save an event can also be missing, and a label's last event
   and `status --json` can disagree; either can be behind until the label's next event, and
   `pick` decides from live checks and, for a token account, from the probe rejection
   `state/current.json` records. `status --json` carries `stateSince` and `limited`
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

13. **Commands for people, not callers:** `run`, `uninstall`, `remove`, `login` and `link` are for a
    person in their own terminal. `docs/CONTRACT.md` says so, and the skill file tells a user's
    Claude never to run them. In a chat shell `run` prints the command to type in a terminal and
    writes nothing.

Notes for the caller's side: the caller's own policy must allow `--settings <launch file>` in a
typed line; its launch check must ask the supervisor the recipe points at, not the default one;
its messaging features must work with workers that can report only through a file when they sit in
a folder account; and a caller that itself runs on a token account gets `backgroundOnly: true` on
every pick, while one inside a folder account is offered only folder accounts by a typed pick
(4A.3).

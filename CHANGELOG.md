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
- Add folder accounts: `add --kind folder`, `link <label>` (a dry run, then typed approval),
  `link --repair`, `unlink`, `link --accept-source-change [--all]`, `verify <label> [--no-reading]`,
  `login <label>` and `login <label> --browser` for a folder, and the folder recipe
  (`CLAUDE_CONFIG_DIR` in `env` and `launchPrefix`). A folder must be linked, or `pick` skips it
  with the reason `not linked` and `status` shows `not_linked`. `pick` and `run` verify a folder
  before every recipe, `status` fills `linked` and `configDir`, in-use counts the sessions in a
  folder's own `sessions/`, and a typed `pick` offers a prefix-less account only where the
  caller's own folder is shown to be the default one.
- Fail closed for folder accounts: a sign-in that does not report its own folder, or reports
  one that cannot be matched, is refused by `pick`, `run`, `login` and `verify`; a `[redacted]`
  marker stands only for text inside one path segment. The config validator refuses a folder
  that is a link, is wider than 0700 or is not owned by the user. `verify` fails on a shared
  source that appeared after `link`, and `link --repair` adds it. Changes to `links.json` take a
  lock and refuse, writing nothing, when part of the file cannot be decoded, including a hook
  record with a malformed hash; `link --accept-source-change` replaces that record and keeps the
  links. A `[redacted]` marker in the label segment of a reported folder matches only a label of
  7 or more characters. `uninstall` clears
  the links listed in `links.json`.
- Require an interactive terminal to apply `link`, `link --repair`, `link --accept-source-change`
  and `unlink`: standard input that is a pipe is refused before the prompt, nothing changes, and
  `--dry-run` needs no terminal. These commands now refuse, writing nothing, when the account's
  links changed after the list was shown, and `link --accept-source-change` does the same for the
  hook record. Repair refusals and the broken-link text name the item to fix, the save-time error
  for an unusable folder names the fix, the links record refusal lists every step, and `login`
  for a folder exits 1 on a different account or when the folder cannot be confirmed as its own.
- Add the menu bar app `AgentBalancerBar` (window-style `MenuBarExtra`, no Dock icon): header with
  the next launch and next Fable choice, one row per account with two meters and the reset time,
  error and warning rows with Show steps and Copy, one banner for `settings_changed`, empty and
  first-run states, Refresh now, Open usage page and Open at login. It reads `state/status.json`,
  runs `agent-balancer refresh` at launch when the file is missing or old and then on a timer, runs
  `status --cached` every 60 seconds, and writes no file. Add `scripts/build-app.sh` (bundle, icon
  and ad hoc signature without Xcode) and `scripts/render-views.sh` (light and dark pictures of each
  view in `build/renders/`).
- Add the Manage accounts window to `AgentBalancerBar` (menu item with Command-comma, and the fix
  action on a `login_rejected`, `token_missing` or `not_linked` row). It lists every account with
  its sign-in and end state, shows a token panel, a folder panel and a read-only login panel, and
  has an Add sheet and a Remove sheet that asks for the label typed back. Every change is one
  `agent-balancer` command from six shapes (`add`, `add --kind folder`, `remove`,
  `config set <label> ends|ending-soon`, `login <label>`, `login <label> --browser`); the window
  never runs `link`, `unlink`, `config set-main`, `config clear-main` or `--paste`, and shows the
  command with a Copy button where one of those is needed. A token account's Sign in shows the
  command to copy because `claude setup-token` does not finish without a terminal. The window
  turns itself off, with a one-line reason, when the app's environment carries the chat-shell
  variable, and shows the Dock icon only while it is open. `status.json` is read for `kind`,
  `fullLogin`, `linked`, `stateSince`, `planTier` and the token expiry. `scripts/render-views.sh`
  also draws the window and both sheets.
- Keep removing the main account as typed consent in a terminal: `remove <label>` of a main
  account exits 1 and changes nothing when standard input is not a terminal, and checks the role
  again under the pick lock before it deletes anything; it stops, keeping the entry, when the label
  now names another account than the one it checked. Every command that saves `config.json` now
  saves it under the pick lock: `config set` (every field), `config set-main`,
  `config clear-main` and `init` join `add`, `login`, `remove` and `refresh`. The Manage accounts
  window reads `status.json` again before each change and runs `remove` only for an account still
  listed as a pool account; otherwise it shows the Terminal command.
- An account keeps one end marker: `config set <label> ends <date>` clears the ending-soon flag,
  `ending-soon true` clears the date, and `ends none` clears both, each in one save. `add` refuses
  `--ends` with `--ending-soon`. So every end change from the window is one command, and a failed
  one leaves the markers as they were.
- In the Manage accounts window, a folder account counts as signed in only on evidence: it is linked
  and its row carries the plan tier, which `status.json` holds only from a check that placed the
  expected account's sign-in in the folder (never from one that found another account or could not
  place it) and not while the last check or probe says `login_rejected`, `check_failed` or
  `wrong_account`. Each folder row carries `signInCheck`, what its last sign-in check saw
  (`signed_in`, `signed_out`, `other_account`, `not_confirmed`), because the row's one error code
  can hide it. A folder another account is signed in to reads "Signed in as another account" with a
  red dot in the list and the panel alike, whatever code the row shows, with the tool's own step and
  no Sign in. A folder signed in where the check could not place it, or a linked one placed and
  doubted since while its row does not show `login_rejected`, reads "Sign-in not confirmed" with no
  Sign in, which `login --browser` would refuse. The panel of the first says the last sign-in check
  could not confirm the sign-in in this folder, whatever code the row shows. A new folder after
  `add --kind folder` or `link`, or one last seen logged out, shows "Not signed in" (or "Signed
  out") and offers Sign in once it is linked and its expected email passes the plain-email rule
  `login --browser` applies (one rule for both; otherwise the panel says why), and the Add sheet's
  steps follow. A folder row with no `signInCheck` key, from a status written before the field,
  reads "Sign-in not confirmed" with no Sign in while it shows a code that can hide a doubt. An
  ended folder keeps its sign-in line, its list row says "ended" (with the date when it has one),
  and its panel shows the row's `account_ended` error unless a sign-in problem takes that place. A
  token or login account counts as signed in only while its row has no code: an ended one reads
  "Account ended" and one with any other code but `login_rejected`, `token_missing` or
  `wrong_account` reads "Sign-in not confirmed", each with a red dot and the row's own error as the
  panel's reason. `login <label> --browser` on a folder that
  is already signed in records that sign-in before it refuses, and the window's bar shows its error
  or "Signed in." line rather than its advice. Remove runs only for the kind and email its sheet
  named.
  The window reads `status.json` again when it becomes key and every 5 seconds while it is open.
  Both sheets keep Cancel and Esc off while their command runs. The token panel shows its sign-in
  command on its own line and says the token file is under `~/.agent-balancer`; the folder panel
  shows the plan tier and copies a folder path made from the label; "On" has a tip to set only a
  date you know; list rows keep the end state when signed out; each Copy button names what it
  copies. The window shows when a signed-out account was first seen signed out, labels its fields,
  choices and date picker for VoiceOver, and shows the account's own end date.
- The menu and the window pass every text from `status.json` through the display-safe pass. The
  render flags `--render` and `--iconset` write only into a folder under the current folder's
  `build/`, written without `..`, with no link and no `.claude` or `.agent-balancer` folder (in any
  case) on its path below the current folder, and outside the home's `.claude` and `.agent-balancer`
  however HOME spells it; any other folder exits 1 and writes nothing. The home must be a folder and
  its `.claude` and `.agent-balancer` missing or a folder: a link to nothing (or a loop, a file, or
  a link to a file) there exits 1 before anything is made. The folder is opened once and every file
  is written relative to it after the home's tool folders are read again, so a folder swapped for a
  link, or a tool folder that comes to name it, part way stops the run.
  `scripts/build-app.sh` refuses a written Info.plist that declares a scripting, URL, service,
  document or extension key.
- Write the final README: the pitch, the three pictures, requirements (with where Claude Code must
  be installed for the tool to find it), install (with the four steps that open the unsigned app on
  macOS 14), first five minutes, how it picks, how it works, what it does not do, privacy, where
  tokens live, limits and uninstall. Add `CONTRIBUTING.md` (tools, build and check, the safety
  rules the scan enforces, issue first, landing, license). Add the README pictures in
  `docs/media/`, which `scripts/render-views.sh` draws from three status documents of made-up
  accounts in states the status writer can produce; the script builds the app and the CLI and
  copies only the pictures its own run drew. Add `scripts/check-readme.sh`, run by
  `scripts/check.sh` and `scripts/render-views.sh`. It fails on any character in the README other
  than printable ASCII and tabs. It reads every inline code span of the README and every line of a
  fenced code block except a `json` block, with a leading `$ ` or `% ` prompt dropped. A fence must
  close before the list item that holds it ends: a line that is not blank and is indented less than
  the opening fence ends it, and the check fails on a fence that ends there or at the end of the
  file without closing. A `json` block must parse as JSON, and each string in it, key or value, is
  read as a later part of a chain. It cuts each span or line into parts at `&&`, `||`, `;`, `&` and
  `|` (a `|` before a flag is a choice in a usage line) and reads each `$(...)` or backtick
  substitution as a part of its own. The first part must start with `agent-balancer`, `claude`,
  `brew`, `gh` or `mkdir`, or be one word naming a path, file or key. In every part but a `claude`,
  `brew`, `gh` or `mkdir` line, each word `agent-balancer`, and a path to it that starts the part,
  begins a command whose subcommand and flags must be in its `--help`. No code span may run across
  a line break, no `code`, `pre`, `kbd`, `samp` or `tt` HTML tag may be used, and no flag may sit
  in plain text, where `agent-balancer` followed by spaces or tabs and a word fails unless that
  word is on the check's word list. Each local file that an inline link or picture, or a `src` or
  `srcset` attribute, names must exist. The pictures may carry no compressed chunk, and their
  metadata chunks must hold no absolute path of two or more parts (also right after a URL's scheme
  and host), home path (`~/`, `~user/` or `$HOME/`), address outside example.com, org id or token.
  The scene sources the pictures are drawn from must name accounts only by the labels `main`,
  `personal`, `lab`, `spare-a` and `spare-b`, every word with a letter in their strings and
  comments, lowercased and ISO times aside, must be a label or on the check's word list, and they
  must hold only those labels' example.com addresses and the fixture's paths. When the local
  banned-string list is present, the check also fails on a banned string in the pictures' metadata
  or the scene sources. The leak test now also runs its shapes over every chunk of the README
  pictures but their pixel data, compressed text inflated, and over those scene sources. The safety
  scan now also reads the Markdown files at the top of the repository for addresses, org ids and
  attribution phrases. The other render scenes now use the five labels too, and the Manage window
  scenes date the link check by the status file's time, as the window does.

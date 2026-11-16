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
  with a lock per account, a fresh probe folder per probe and a Fable probe once a day.
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
- `config set <label> label <new>` refuses on a token account, and on a folder account, whose
  folder is named for the label, and writes nothing.
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
  links. A `[redacted]` marker in the label segment of a reported folder matches only when the
  scrubber turns the account's own label into exactly that segment: a label of 32 or more
  characters that the entropy rule redacts, or one that holds the token prefix. `uninstall` clears
  the links listed in `links.json`.
- Require an interactive terminal to apply `link`, `link --repair`, `link --accept-source-change`
  and `unlink`: standard input that is a pipe is refused before the prompt, nothing changes, and
  `--dry-run` needs no interactive terminal, though it still refuses inside a Claude Code chat
  shell. These commands now refuse, writing nothing, when the account's
  links changed after the list was shown, and `link --accept-source-change` does the same for the
  hook record. Repair refusals and the broken-link text name the item to fix, the save-time error
  for an unusable folder names the fix, the links record refusal lists every step, and `login`
  for a folder exits 1 on a different account, when the folder cannot be confirmed as its own, or
  when the sign-in reports no email for an account with an expected one.
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
  could not confirm the sign-in in this folder, whatever code the row shows, or gives the row's own
  error when that says the sign-in reported no email. A new folder after
  `add --kind folder` or `link`, or one last seen logged out, shows "Not signed in" (or "Signed
  out") and offers Sign in once it is linked and its expected email passes the plain-email rule
  `login --browser` applies (one rule for both; otherwise the panel says why), and the Add sheet's
  steps follow. A folder row with no `signInCheck` key, from a status written before the field,
  that shows `check_failed` or a code that can hide a doubt reads "Sign-in not confirmed" with no
  Sign in when it is linked, and "Not signed in" with its link step when it is not. An ended
  folder keeps its sign-in line, its list row's line ends with "ended Nov 1" once its end date has
  passed and with "ended" otherwise, and its panel shows the row's `account_ended` error along
  with any sign-in problem it reads as. A token account counts as signed in only while its
  row has no code, and a login account only by the plan tier its row carries from a check of its
  current email, with no code or under `plan_changed` or `duplicate_login`: an ended one reads "Ended Nov 1" in the list, or "Ended" when no end date has
  passed, and one with any other code but `login_rejected`, `token_missing` or `wrong_account`
  reads "Sign-in not confirmed", each with a red dot and the row's own error as the panel's
  reason. `login <label> --browser` on a folder that
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
  case) on its path below the current folder, and outside the home's `.claude` and
  `.agent-balancer`; any other folder exits 1 and writes nothing. A HOME that is set but empty,
  is not an absolute path, or has a `..` segment stops every render. The home must be a folder and
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
  file without closing. A `json` block must parse as JSON, and each key and each string of the
  parsed value is read as a later part of a chain, so a key that appears twice is read with its
  last value only. It cuts each span or line into parts at `&&`, `||`, `;`, `&` and
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
  must hold only those labels' example.com addresses, each with at most one leading hyphen, and
  the fixture's paths. When the local banned-string list is present, the check also fails on a
  banned string in the pictures' metadata or the scene sources. The leak test now also runs its
  shapes over every chunk of the README pictures but their pixel data, compressed text inflated,
  and over those scene sources. The safety scan now also reads the Markdown files at the top of
  the repository for addresses, org ids and attribution phrases. The other render scenes now use
  the five labels too, and the Manage window scenes date the link check by the status file's time,
  as the window does.
- Refuse every save to `links.json`, writing nothing, when its `schemaVersion` is not 1, such as a
  file a newer version wrote: the message says to move `links.json` aside, record the hooks again
  with `agent-balancer link --accept-source-change` and run `agent-balancer link <label>` again for
  each folder account. `uninstall` still deletes such a file, and removes none of the links it
  lists, since it cannot read them.
- A sign-in check counts only for the account and email it was made for. `state/current.json`
  keeps a digest of the account key and the lowercased email of each check, never the email.
  After the email changes, by `config set <label> email`, by an edit of `config.json` or by
  `remove` and `add` of the label, the row has no plan tier, no expiry from a check and no
  `signed_in` until a check of the new email, so the Manage accounts window shows no "Signed in"
  and no finished Add step 3 for such a folder. `link <label>`, once its links are made, and
  `config set <label> email <new>` check the folder or login account as `status` does, so
  the window reads what the folder holds. Only a check that placed the expected account's
  sign-in in its own folder, for its current email, records the expected plan (in `refresh`,
  folder `login` and, after a new email, `config set <label> email`), the expiry and the
  ending-soon plan drop. A probe's `login_rejected`, a Fable
  probe's too, stays until a probe works with a reading newer than the latest one the status had
  seen, or until `login` completes a new sign-in, and a check that sees only the old sign-in
  leaves it: while it stands, `login <label>` and
  `login <label> --browser` sign the folder in again instead of refusing it as already signed
  in, and a run that cannot show a new sign-in exits 1 with `login_rejected`. While a probe's
  `login_rejected` stands for a token account and the status has seen its latest reading (only
  a probe that works stores a newer one), `pick` skips it as `login rejected` and `run <label>`
  refuses it, even on a fresh reading. A `signInCheck` of another type in `status.json` reads as
  no check, and the menu and the window still load the rest of the status.
- In the Manage accounts window, ended token and login rows read "Ended Nov 1" in the list,
  or "Ended" when no end date has passed, and an ended folder's line ends with "ended Nov 1"
  once its end date has passed and with "ended" before then. A signed-in token with no end set
  reads "N days left", "1 day left" or "Less than a day left" until its estimated end, then
  "Signed in", never "Expired". An ended folder that its last check placed, with a doubt since,
  says its sign-in may have been rejected and gives
  `agent-balancer login <label> --browser`; one that reads as another account's, or that its
  last check could not place, shows that problem and then that it has ended. A linked folder
  row with no `signInCheck` key, as an earlier version wrote it, reads "Sign-in not
  confirmed" under `check_failed` too, and one that is not linked, under `check_failed` or a
  code that can hide a doubt, reads "Not signed in" with its link step and Sign in off. A login
  row with `plan_changed` or `duplicate_login` counts its plan tier as sign-in evidence, as a
  folder row does. A login account's `wrong_account` step,
  in the menu and the window, and its `login_rejected` steps in the menu say to run `claude` and
  sign in again, never to relabel a folder or to run `agent-balancer login`, which refuses a
  login account, and its menu row has no Open Manage accounts action. A folder whose expected
  email fails the
  plain-email rule shows `agent-balancer config set <label> email <address>` with Copy, and
  Add step 3 gives the same reason.
- In the Manage accounts window, editing the end date runs one
  `config set <label> ends <date>` when the edit ends (the date picker loses focus or goes away,
  the window closes or stops being key, or another account is selected), for the date it ended
  on, so a date part way through an edit, today included, is never saved. After a token
  account's `login`, the bar shows how it ended (the saved token and its first check, or the
  tool's `Error` line), not its opening line. The Remove sheet closes when `remove` fails,
  such as when another `remove` got there first, and the bar shows the tool's text. Once
  management is off, as when the CLI goes missing while the Add sheet is open, the sheet says
  why Add is off in place of an earlier run's error. The shared-settings tip reads "Approve
  linking in Terminal: agent-balancer link <label>".
- The Manage window renders draw a finished folder Add sheet with its Label and Email fields
  off, as the live sheet does, show no plan tier on the folder render's signed-out folder, and
  add `manage-email-note`, the panel's note for an email `login --browser` will not pass to
  `claude`. The README check lets a scene source hold a made-up account's address with one
  leading hyphen, for that render. `scripts/build-app.sh` and `scripts/render-views.sh` take
  the checkout's real path, so both run from a checkout opened through a link.
- Every `refresh` checks the sign-in of each login and folder account whose probe did not fail
  (the check spends no usage), and probes again an account whose sign-in a probe found
  rejected, as the status records it, even when its reading is fresh; every other fresh
  reading is kept without a plain probe unless you pass `--force`. So after you sign back in,
  the next refresh, such as Refresh now in the menu or its timer, clears "Login rejected"
  without waiting for the reading to age, unless its probe fails or another command records the
  account's rejection after that probe. A plan already recorded for an account stays as it is,
  and a check that sees another plan shows `plan_changed`, as `status` does.
- Security audit (2026-11-15). The pre-release security audit fixed these. The email scrubber
  reads text in one pass, so a long line can no longer stall a command. The environment that
  `run`, `login` and a launcher give `claude` now leaves out every Claude Code variable but the
  chat marker, and every name the installed `claude` reads to find a stored login, a credential
  store, a token file or a sign-in endpoint, such as `CLAUDE_SECURESTORAGE_CONFIG_DIR`. A typed
  `pick` or `run --print-command` refuses while a variable that chooses the stored login, switches
  hooks off or points `claude` at another settings source (`CLAUDE_CODE_MANAGED_SETTINGS_PATH`,
  `CLAUDE_CODE_REMOTE_SETTINGS_PATH`) is set, and answers background only under any credential
  variable, not just the three key names. The default folder's settings are checked for
  credential names only, so a harmless name such as `CLAUDE_CODE_SUBAGENT_MODEL` skips no
  account, while a key helper, a credential name or `CLAUDE_CONFIG_DIR` there skips every account,
  and a name there that switches hooks off refuses every account as hooks off. Caller settings take
  only `env` and `crossSessionInbound`, never a key that runs a command or switches hooks off, and
  the config's two launch lists are checked when the config loads and again at pick time; names
  of your own such as `CLAUDE_ROLE` and `CLAUDE_CLIENT` are allowed. Every launch file sets
  `disableAllHooks` to false. An unreadable lease file stops a pick instead of reading as no
  picks. A login or folder account with no recorded email fails its checks, a pool account that
  shares another account's email is skipped, and a sign-in is checked again before and after each
  probe and under the pick lock. A token's rejection survives a damaged status file. `run`
  refuses the options that switch hooks off or start the session somewhere else, and `init`,
  `uninstall` and `login --paste` need an interactive terminal. A token account whose reset times
  match the main account's gets a `possible_duplicate` warning and is still offered.
- `pick` skips the main account while its stored reading has no 5-hour window; when nothing
  earlier refuses it, the reason is `No 5-hour reading, which the main account needs.` A pool
  account without one is still judged on its weekly use but ranks after every account that has
  one, and when it is eligible, its reason ends with `5-hour use unknown.`
- `config set <label> email <new>` on a `login` or `folder` account deletes the label's stored
  reading when the new email differs from the stored one in more than letter case, and every
  token save of `login` deletes it before the first check, a first save included, such as after a
  restore from a backup that brought the reading back without the token file. So a main account is
  not judged on the old subscription's use or weekly reset. The email change, the token save, the
  rename, `add` and `init` hold the label's probe lock while they move or delete its reading: a
  probe already under way saves its reading first and the command deletes or moves that one too.
  After an email change, a rename, `add` or `init`, a probe that a `pick` or `refresh` began from
  the registry as it was before the change runs no probe; after a token save, a waiting probe reads
  the new token. `remove` takes only the pick lock, so a probe under way can still save a reading
  under the removed label, which `add`, `init` or a rerun of `remove` deletes. The same email again
  keeps the reading. The command's own rebuild records no `limit_cleared` for the reading it
  deletes, as `remove` records none; another rebuild that runs during the command's sign-in check
  or first probe can still record one, and so can the next rebuild after a change that stopped
  once it had deleted the reading, such as an email change that the registry save refuses, which
  keeps the email and the plan.
- The email change also forgets the recorded plan in the same write. Its own check, or else the
  next `refresh` or folder `login`, records the new sign-in's plan once it places that sign-in, so
  no check reports `plan_changed` against the old plan. An ending-soon plan drop that a check of
  the old email marked goes with that email, so `status` no longer shows such an account as ended
  while `pick` uses it. The same email again records no plan.
- After a login account's email changes, by `config set` or by a hand edit of `config.json`, the
  Manage window no longer reads it as "Signed in" until a check places the new email's sign-in. A
  check made for the old email whose command saves its result after the change records nothing, so
  it no longer clears the new email's `wrong_account`.
- `config set <label> label <new>` on a `login` account moves the account's stored reading and
  its open leases to the new label once the registry is saved, and leaves no reading under the old
  one, so the account is judged by its own newest reading or by none, a rename back included, and
  a pick made before the rename counts for it. A rename that the registry save refuses moves
  nothing. A launch file such a pick wrote stays under the old label while its lease is open: a
  token saved later under that label is never written into it, and `remove` of that label keeps it
  as a tombstone while the lease is open, unless the account removed there is a `folder` account,
  whose remove deletes it unless a session record names it or the session records cannot be read
  cleanly. `pick` and `run` read the registry again under the pick lock and skip or refuse an
  account that it no longer holds under its label, so a pick that began before a rename never
  judges the renamed account by a reading of the account added under its old label.
  `history --json` lists an account's lines by its key, so they follow a rename and another
  account's lines under the same label never show; a history file that the reader refuses stops
  only the listings whose lines it may hold, those of the account under its label and of the
  login account, and every other listing goes on. `add` and `init` delete a reading another
  account left under the label, so an account added under a label starts with no reading.
- A token save writes the new token only into the label's launch files that already carry a token,
  so a launch file with no token, such as a renamed login account's, never gains one.
- CI's check job stops after 20 minutes.
- A probe reply whose usage value for a window is above 1, as the client reports once use runs
  past a window's cap, counts as full use of that window (100 percent) instead of failing as
  `check_failed`, so its other windows are read. A full `five_hour` or `seven_day` window shows the
  account as `limited` until that window resets; a full Fable window, read while `fable.probe` is
  on, gives the `fable_limited` warning, so only Fable picks skip the account; any other window
  changes no state. A negative or non-number value, minus infinity included, still fails the
  whole reading, with the text `Check failed: the probe gave a usage value that is negative or not
  a number.`; a number too large to read, such as `1e999`, leaves its reply line unread, as any
  line that does not parse.
- A Fable probe still running when its `pick` rebuilds the status, or when its command's process
  ends, no longer counts as tried, so it stays due for the next Fable pick, and for the next
  `refresh` once a day has passed since the last one counted, instead of waiting a day. A probe of a
  pick that is still running at the deadline and ends with an auth error before the pick's status
  rebuild is recorded as the account's `login_rejected`, also when the pick ends `pick busy`, and
  when it ends so before the pick decides, the pick skips the account as `login rejected`: the pick
  reads its own probes' results and other commands' recorded rejections after its sign-in checks
  under the pick lock. `refresh` records what each account's probes found in the status as that
  account's refresh ends, before it lets that account's probe lock go, so a refresh that the menu
  ends after its 300 second timeout keeps what its finished probes found, except a result whose own
  rebuild was skipped, saved no `state/current.json` or failed, which only the refresh's last
  rebuild would record, and one whose own rebuild had not finished when the menu ended the
  refresh. The menu's end stops the last rebuild, so both are lost from the status, though a
  reading a working probe stored shows at the next rebuild and a token account's rejection that
  its own rebuild recorded still keeps the token out; any other error waits for the account's
  next probe.
- A probe's rejection of a sign-in is dated no earlier than the latest reading the status had
  seen, also when its rebuild reads an older reading or none, and while it stands no status
  rebuild moves that time back. A working probe ends it through a stored reading newer than that
  time, and through its own reading time only when the rebuild cannot read the stored reading. So
  an older working probe whose rebuild lands late after a clock step, an older reading after the
  clock was set back before a rejection recorded with no usable reading, and a reading file put
  back in an older form no longer end a newer rejection, and `pick` and `run` keep the token out
  until a probe that works stores a reading newer than the rejection. A `login` that saves a new
  token ends a probe's rejection recorded before its first check once that check works, also when
  the rejection is dated ahead of the clock, in the status rebuild that records the check; when
  that rebuild is skipped at its 30 second wait for the history lock, saves no
  `state/current.json` or fails, a rejection dated ahead of the clock stands until another such
  `login` or a stored reading newer than it. The architecture document names the routes that
  remain.
- A login account's "Login rejected" text, and `login`'s refusal of a login account, say to run
  `agent-balancer refresh` after you sign in again, not `agent-balancer doctor`, which records no
  sign-in check and so left the error in place. `refresh` records the check and probes again an
  account whose sign-in a probe found rejected.
- `uninstall`'s refusal of a folder that cannot be opened or searched names `chmod -N <folder>`
  and then `chmod 700 <folder>`, since `chmod 700` leaves an access list in place, and its
  refusal of a folder that `lstat` cannot check, which may be a link, names `chmod -h -N <folder>`,
  or `chmod -N <folder>` if that says Permission denied, and then `chmod -h 700 <folder>`. The
  texts for token files and temporary files that could not be checked or deleted name
  `chmod -h -N` and `chmod -h 700` on the folders that hold them and `chmod -h -N` on each file,
  or `chmod -N` where that says Permission denied, with `chflags -h nouchg` first on one that is
  locked, and a launch file that `uninstall` cannot clear, such as one whose access list denies
  its owner `delete`, stops it with a text that names the same commands on each label's launch
  folder that is not a link and on each file directly in it, instead of only a rerun. `-h` makes
  `chmod` act on a link itself, not on what it points to, and plain `chmod -N` clears a list that
  denies its owner `read`, where `chmod -h -N`, which opens the entry, cannot. Naming only the
  label folders that are not a link keeps every command off a folder that a link there points to.
  An entry where a label's launch folder belongs that `lstat` cannot check, such as a folder whose
  access list denies its owner `readattr`, gets its own line in the listing and the closing text
  instead of being called a link, a file or another user's folder.
- The Manage window's ending-soon tip gives its two rules in two sentences. A pick whose chosen
  account's weekly window has no reset time says `resets an unknown time` instead of a made-up
  date. `docs/CONTRACT.md` names a token account's `login` among the commands that probe, and
  section 10.1 of the architecture doc says that the status document's `next` keeps the main
  account's probe-source rule.

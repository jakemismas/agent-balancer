# The agent-balancer contract

This page is what a caller can rely on without reading the source. A caller is a person who types
a launch line, a skill that tells Claude what to type, or a program that starts `claude` itself.
Fields and rules named here do not change within schema version 1. New fields may appear, so a
caller ignores fields it does not know.

## Pick before every launch

```
agent-balancer pick --json [--model <model>] [--settings '<your settings JSON>']
                    [--full-login] [--caller typed|launcher] [--exclude <label>] [--dry-run]
```

Use a command timeout of at least 90 seconds. `pick` can refresh stale readings for up to 45
seconds and wait up to 30 seconds for the pick lock.

### Exit codes

| Exit | Meaning | What the caller does |
|---|---|---|
| 0 | A recipe | Apply it |
| 2 | Nothing fits | Do not launch. Leave the item waiting and show `reason` |
| 1 | No pick: a refused flag, refused settings, a busy lock or another error | Report the error text. No lease or launch file was written |

### Fields stable in schema version 1

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | number | `1` |
| `label` | string or null | The chosen account, null when nothing fits |
| `reason` | string | In every answer. The text is informational |
| `env` | object of strings or null | Exit 0: an object, possibly empty. Exit 2: null |
| `args` | list of strings or null | Exit 0: always `--settings` and a path. Exit 2: null |
| `launchPrefix` | string or null | Typed form. A literal, possibly empty. Null under `--caller launcher` |
| `launchArgs` | string or null | Typed form. A literal. Null under `--caller launcher` |
| `unsetEnv` | list of strings or null | A list under `--caller launcher`, null otherwise |
| `backgroundOnly` | boolean | When true, a typed line must be a `claude --bg` launch |
| `candidates` | list | Each entry has `label` and `eligible` (stable) and `reason` (informational) |

A recipe is returned only for an account that passed its checks at pick time.

A typed pick offers a `login` or `token` account only where your own session is shown to run in
the default folder; from inside another folder it offers folder accounts, each with its own
`launchPrefix`, or exits 2.

A folder account is offered only when its folder is shown to be its own: the sign-in must report
an absolute `configDirectory` that is that folder, and a missing or unclear report refuses the
account. A shared source that appeared after `link` also refuses it until `link --repair`. If repair
refuses, its message names the item to fix and the command to run again.
A damaged `links.json` (including a hook record with a malformed hash) stops `link` and `unlink`, which write nothing and name the command that clears it.

`configDir` is not a contract field. A caller never builds an account folder path from anything it
reads.
`status --json` shows `configDir` for people to read, not for a caller to use.

### Flags

- `--settings '<json>'`: your own settings for the session, as one JSON object. The tool checks
  them against an allowlist, merges them into the launch file and exits 1 with the offending key
  name, never its value, when they do not pass. A caller never passes `--settings` to `claude`.
- `--full-login`: offer only accounts with a full login, for a session that needs claude.ai
  connectors, Remote Control or claude.ai skills.
- `--caller typed|launcher`: how the recipe is applied. The default is `typed`.
- `--exclude <label>`: leave that account out of this pick. Repeat the flag for more labels. Use
  it for a label your own check refused, or one whose worker just hit a limit.
- `--dry-run`: decide only. It writes no lease and no launch file and returns no recipe.
- `--model <name>`: the model the launch is for.

## Apply the recipe

The caller applies the recipe the same way for every account and never branches on the account
kind.

**A typing caller** types this as one literal line:

```
<launchPrefix>claude <your own flags> <launchArgs> '<prompt>'
```

Copy `launchPrefix` and `launchArgs` exactly. Never rebuild them, wrap the line in a script or use
a substitution.

**A launcher** is a program that starts `claude` itself. Ask for `--caller launcher`. Start
`claude` with your own environment, minus every name in `unsetEnv`, plus every entry of `env`, and
with `args` after your own flags, as an argument array. Never paste any of it into a shell string.

## Never

- Pass your own `--settings` to `claude`. Give it to `pick`.
- Branch on the account kind.
- Open, copy, print or keep a launch file, or read anything else under `~/.agent-balancer/`.
- Build a folder or file path yourself.
- Reuse a recipe. One pick is one launch, within the lease window. A pick you did not launch needs
  no action: the lease lapses by itself, and you pick again.

## Check the launch

List the sessions with the environment the recipe gave you and find the new one by its session
id. A short worker may have finished before the check. If the session is missing, the launch did
not land where the recipe pointed: stop launching onto that account and report it.

## Read state

`agent-balancer status --json --cached` reads saved readings only. It starts no child process and
spends no model call, so it is the form for every periodic read. Plain `status --json` may check
sign-in state. Only `refresh`, `pick` and a token account's `login` probe. The fields of
`status --json` that its schema documents are stable in version 1.

A `folder` account's row also carries `signInCheck`: what the last sign-in check of that folder that
got an answer saw. `signed_in` is the expected account (any account when no email is set) signed in
in its own folder, `signed_out` is no account, `other_account` is another account in that folder,
and `not_confirmed` is an account signed in that the check could not place in that folder, or
could not confirm as the expected account because the sign-in reported no email. It is
null before the first such check and stays as it was after a check that got no answer; `login` and
`token` rows have no such key. The row shows one `error` code, and a higher one can hide
`wrong_account`, so read `signInCheck` for the folder's sign-in. `planTier` is null after any check
that did not place the expected account's sign-in. A check counts only for the account and email
it was made for: after an account's email changes, by `config set <label> email`, by an edit of
`config.json`, or by `remove` and `add` of the same label, its row has a null `planTier`, and a
null `signInCheck` where the last check saw `signed_in`, until a check of the new email. A `login`
account's `planTier` follows the same rule. These commands record a check: `status` (not
`status --cached`), `pick`, `run` (once it has written its launch file), `verify`, `refresh` (for
each `login` and `folder` account whose reading did not fail, every time it runs), `init`,
`login` for a folder account, `link <label>` (once its links are made) and
`config set <label> email`. `refresh` also probes again an account whose sign-in a probe found
rejected, as the status records it, even when its reading is fresh. When a row's `login_rejected`
error names an `agent-balancer` command, it is one of these, to run once the account is signed in
again: `refresh`, or `login <label>` for a `folder` account, which signs the folder in itself.
`doctor` shows each sign-in but records no check.

## What changed

```
agent-balancer events --json [--after <cursor>] [--since <time>] [--label <label>]
                      [--type <type>] [--limit <n>]
agent-balancer history --json [--label <label>] [--since <time>] [--limit <n>]
```

`events` is the record of state changes. Keep the `cursor` of each answer and pass it back as
`--after`. Call again at once while `more` is true. Treat `gap: true`, or a `recordId` you have not
seen, as a gap: read `status --json` once and carry on from the new `cursor`. A caller skips event
types it does not know. An event can come more than once, with a new `seq` and the same `label`,
`type`, `code`, `window`, `resetsAt` and `notBefore`: read each event as the state it reports for
its label, never as a count, so a repeat changes nothing. After a failed save an event can also
be missing, and a label's last event and `status --json` can disagree; either can be behind until
the label's next event, and `pick` decides from live checks and, for a token account, from the
probe rejection `state/current.json` records. `history` gives the readings over time, for a chart
or a burn-rate estimate. The fields of each answer that the schema documents are stable in
version 1.

## Information is not authority

Decide a launch from `pick`, never from `events`, `history` or an old `status`. A reading or an
event can be stale, and only `pick` applies the checks that gate a launch.

## Separate callers

Separate callers are serialized only by the pick lock and the lease. Launch within the lease
window or pick again.

## Commands for people

`run`, `uninstall`, `remove`, `login` and `link` are for a person in their own terminal. Inside a
Claude Code chat shell each of them refuses before it starts a session or changes anything,
and so does a form that changes nothing, such as `link --dry-run`. A caller
applies the recipe from `pick` and does not use them. In a chat shell `run`
writes nothing, starts nothing and prints the line to type in your own terminal,
`agent-balancer run <label> -- <arguments>`, then exits 1. `uninstall` exits 0 once the removal
is done or when there is nothing to remove, and 1 when it refuses, stops, is not confirmed, could
not check or delete a token file or a temporary file that may hold a token, or leaves unopened an
entry that may hold one: one named like a token file or a launch folder in other letter case, or a
link, a file, another user's folder or an entry it cannot check where a label's launch folder
belongs.

Applying a link change (`link`, `link --repair`, `link --accept-source-change`, `unlink`) also needs a
person at an interactive terminal who types the label (or `accept`) back. Input from a pipe is
refused before the prompt and nothing changes; `link --dry-run` needs no interactive terminal, but
it still refuses inside a chat shell.

`remove <label>` of the main account also needs a person at an interactive terminal: with
standard input from a pipe it exits 1, changes nothing, and says to run
`agent-balancer remove <label>` in Terminal. Removing a pool account needs no interactive terminal,
but `remove` still refuses inside a chat shell. Every
command that saves `config.json` (`init`, `add`, `login`, `refresh`, `config set`,
`config set-main`, `config clear-main`, `remove`) saves it under the pick lock, so two at once
never save over each other, and a role change or a rename is seen by a `remove` that runs at the
same time. `remove` deletes the entry only while it is still the account it checked, and when
the label names another account by then it exits 1 and keeps it. A `remove` that waited while
another `remove` of the same label finished exits 0, as a rerun of a remove that stopped part
way does.

An account keeps one end marker. `config set <label> ends <date>` also clears its ending-soon
flag, `config set <label> ending-soon true` also clears its date, `config set <label> ends none`
clears both, and `ending-soon false` clears only the flag; each is one save. `add` refuses
`--ends` together with `--ending-soon` and writes nothing. A config saved earlier with both keeps
working, the date first, until the next change clears one.

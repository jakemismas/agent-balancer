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
| 1 | No pick: a refused flag, refused settings, a busy lock or another error | Report the error text. Nothing was written |

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
sign-in state. Only `refresh` and `pick` probe. The fields of `status --json` that its schema
documents are stable in version 1.

## What changed

```
agent-balancer events --json [--after <cursor>] [--since <time>] [--label <label>]
                      [--type <type>] [--limit <n>]
agent-balancer history --json [--label <label>] [--since <time>] [--limit <n>]
```

`events` is the record of state changes. Keep the `cursor` of each answer and pass it back as
`--after`. Call again at once while `more` is true. Treat `gap: true`, or a `recordId` you have not
seen, as a gap: read `status --json` once and carry on from the new `cursor`. A caller skips event
types it does not know. `history` gives the readings over time, for a chart or a burn-rate
estimate. The fields of each answer that the schema documents are stable in version 1.

## Information is not authority

Decide a launch from `pick`, never from `events`, `history` or an old `status`. A reading or an
event can be stale, and only `pick` applies the checks that gate a launch.

## Separate callers

Separate callers are serialized only by the pick lock and the lease. Launch within the lease
window or pick again.

## Commands for people

`run`, `uninstall`, `remove`, `login` and `link` are for a person in their own terminal. They
refuse to start a session or change anything inside a Claude Code chat shell. A caller applies the
recipe from `pick` and does not use them. In a chat shell `run`
writes nothing, starts nothing and prints the line to type in your own terminal,
`agent-balancer run <label> -- <arguments>`, then exits 1.

# Scripts and orchestrators

This page shows how a program that starts Claude Code sessions, such as a script, a scheduler or
an orchestrator that runs many workers, gets an account from agent-balancer before each launch.
[CONTRACT.md](CONTRACT.md) is the full contract.

The loop is short: ask `agent-balancer pick --json` for an account, read the exit code, and start
`claude` with the recipe in the answer. One pick is for one launch.

## Before you start

- A person sets up the accounts once, in their own terminal: `agent-balancer init`,
  `agent-balancer add`, `agent-balancer login` and, for a folder account, `agent-balancer link`.
  See the [guide](GUIDE.md#first-five-minutes).
- Your program never runs `run`, `uninstall`, `remove`, `login` or `link`. They are for a person,
  and inside a Claude Code chat shell they refuse.

## Pick an account

A program that starts `claude` itself is a launcher. Ask for the launcher form:

```
agent-balancer pick --json --caller launcher --model <model>
```

Give the command a timeout of at least 90 seconds: `pick` can refresh stale readings for up to 45
seconds and wait up to 30 seconds for the pick lock.

| Flag | Use it to |
|---|---|
| `--caller launcher` | Say that your program starts `claude` itself, so the answer carries `unsetEnv`. The default, `typed`, is for a caller that types a command line. |
| `--model <model>` | Name the model the launch is for, and start `claude` with the same model. A name with `fable` in it also needs room in the Fable allowance. Without it, or with a name the tool cannot place, such as default or best, the pick leaves out every account set to refuse Fable launches. |
| `--full-login` | Get only accounts with a full login, for a session that needs claude.ai connectors, Remote Control or claude.ai skills. |
| `--exclude <label>` | Leave out an account your own check refused, or one whose worker just hit a limit. Repeat it for more labels. |
| `--settings '<json>'` | Pass your own settings for the session, as one JSON object. Never pass `--settings` to `claude` yourself. |
| `--dry-run` | Decide only. It writes no lease and no launch file and returns no recipe. |

## Read the exit code

| Exit | Meaning | What your program does |
|---|---|---|
| 0 | A recipe | Launch with it |
| 2 | Nothing fits | Do not launch. Leave the work waiting, show `reason` and pick again later |
| 1 | No pick: a refused flag, refused settings, a busy lock or another error | Report the error text. No lease was written, and a launch file stays only when the error names it: never use that file; the commands the error names are for a person in their own terminal |

Treat any other exit code as a failed call, like exit 1. At exit 0 and 2 the answer is JSON on
standard output; at exit 1 the error text is on standard error.

## Read the answer

A made-up answer for a folder account labeled `lab`:

```json
{
  "args" : [
    "--settings",
    "/Users/example/.agent-balancer/launch/lab/l-1a2b3c4d.json"
  ],
  "backgroundOnly" : false,
  "candidates" : [
    { "eligible" : false, "label" : "work", "reason" : "Limited until Thu 2:00 PM." },
    { "eligible" : true, "label" : "lab", "reason" : "Resets Wed 6:00 PM." }
  ],
  "env" : {
    "CLAUDE_CONFIG_DIR" : "/Users/example/.agent-balancer/accounts/lab/.claude"
  },
  "label" : "lab",
  "launchArgs" : null,
  "launchPrefix" : null,
  "model" : "opus",
  "pickedAt" : "2026-11-09T21:13:00Z",
  "reason" : "Soonest weekly reset: resets Wed 6:00 PM.",
  "schemaVersion" : 1,
  "unsetEnv" : [
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_MANTLE",
    "CLAUDE_SECURESTORAGE_CONFIG_DIR",
    "CLAUDE_CODE_CUSTOM_OAUTH_URL",
    "CLAUDE_CODE_SIMPLE",
    "CLAUDE_CODE_SAFE_MODE",
    "CLAUDE_CODE_PERSONAL_HOOKS_OFF",
    "CLAUDE_CODE_RESTRICTED",
    "CLAUDE_CODE_RESTRICT_PERSONAL_CONFIG",
    "CLAUDE_CODE_MANAGED_SETTINGS_PATH",
    "CLAUDE_CODE_REMOTE_SETTINGS_PATH",
    "CLAUDE_CODE_MOCK_REMOTE_SETTINGS",
    "CLAUDE_JOB_DIR",
    "CLAUDE_PID"
  ]
}
```

The fields a launcher relies on, stable in schema version 1:

| Field | What it holds |
|---|---|
| `schemaVersion` | `1` |
| `label` | The chosen account, or null when nothing fits |
| `reason` | Why, in every answer. Show it; do not parse it |
| `env` | Names and values to add to the environment of `claude`. Null at exit 2 and with `--dry-run` |
| `args` | Arguments to put after your own flags: always `--settings` and a path. Null at exit 2 and with `--dry-run` |
| `unsetEnv` | Names to remove from the environment of `claude`: a fixed list plus each protected name your own environment holds, less any name `env` sets. A list under `--caller launcher`; null at exit 2 and with `--dry-run` |
| `candidates` | One entry per account, with `label` and `eligible`, and a `reason` to show |

`launchPrefix`, `launchArgs` and `backgroundOnly` belong to the typed form below. Ignore fields you
do not know: new ones may appear within schema version 1.

## Launch Claude Code

Start `claude` with your own environment, minus every name in `unsetEnv`, plus every entry of
`env`, and with `args` after your own flags, as an argument array. Never paste any of it into a
shell string, and never branch on the account kind: the recipe is the same for every account. Your
own flags carry the same `--model` you gave `pick`.

A sketch in Python:

```python
import json
import os
import subprocess


def pick(model):
    done = subprocess.run(
        ["agent-balancer", "pick", "--json", "--caller", "launcher", "--model", model],
        capture_output=True, text=True, timeout=120)
    if done.returncode not in (0, 2):
        raise RuntimeError(done.stderr.strip())
    return json.loads(done.stdout)


def launch(answer, own_flags, prompt):
    env = {name: value for name, value in os.environ.items() if name not in answer["unsetEnv"]}
    env.update(answer["env"])
    return subprocess.Popen(["claude", *own_flags, *answer["args"], prompt], env=env)


model = "opus"
answer = pick(model)
if answer["label"] is None:
    print("No account has room:", answer["reason"])
else:
    launch(answer, ["-p", "--model", model], "Summarize the open issues")
```

Launch within the lease window, `picker.leaseMinutes` (10 minutes by default). A pick you did not
launch needs nothing: its lease lapses by itself. Never reuse a recipe; pick again for the next
launch.

After each launch, check that it landed, as [CONTRACT.md](CONTRACT.md#check-the-launch) says: if
its session is missing, stop launching onto that account and report it.

## When no account is free

Exit 2 means no account fits right now, and each entry of `candidates` says why. Do not launch,
and do not choose a label yourself:

1. Keep the work waiting and show `reason`.
2. Pick again later. `agent-balancer events --json --after <cursor>` tells you what changed since
   your last read, and `agent-balancer status --json --cached` shows each account's state and reset
   times.
3. When a worker hits a limit during a run, pick again with `--exclude` and that worker's label.

Decide a launch from `pick` only, never from `events`, `history` or an old `status`: only `pick`
applies the checks that gate a launch.

## Read state between launches

`agent-balancer status --json --cached` reads saved readings only. It starts no child process and
spends no model call, so use it for every periodic read. Plain `agent-balancer status --json` may
check sign-in state. For changes, keep the `cursor` of each `agent-balancer events --json` answer
and pass it back with `--after`. [CONTRACT.md](CONTRACT.md#what-changed) has the rules.

## A typed launch

A caller that types a command line, such as a Claude Code session that starts workers in a
terminal, uses the default `--caller typed` and types one literal line:

```
<launchPrefix>claude <your own flags> <launchArgs> '<prompt>'
```

Copy `launchPrefix` and `launchArgs` exactly; never rebuild them, wrap the line in a script or use
a substitution. When `backgroundOnly` is true, the line must be a `claude --bg` launch.

## Install the skill

The skill tells a Claude Code session how to read state, pick and launch by these rules. Homebrew
installs it with the tool. Link it into your skills folder yourself; the tool never writes inside
`~/.claude`:

```
mkdir -p ~/.claude/skills && ln -s "$(brew --prefix)/share/agent-balancer/skill/agent-balancer" ~/.claude/skills/agent-balancer
```

Once `agent-balancer link` has made its links, a folder account shares that skills folder. If
`~/.claude/skills` did not exist when you ran `agent-balancer link`, run
`agent-balancer link --repair <label>` for each folder account; until then `pick` skips it.

## Never

- Pass your own `--settings` to `claude`. Give it to `pick`.
- Branch on the account kind.
- Open, copy, print or keep a launch file, or read anything else under `~/.agent-balancer/`.
- Build a folder or file path yourself.
- Reuse a recipe.

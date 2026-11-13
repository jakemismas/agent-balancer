---
name: agent-balancer
description: Use when you launch Claude Code sessions and want them spread across the user's subscription accounts; it reads account usage with agent-balancer and applies the launch recipe that agent-balancer pick returns.
---

# Launching on the right account

`agent-balancer` keeps one reading of each subscription account's usage and picks the account for
the next launch. You read from it and you apply what it returns. You never choose an account, and
you never open its files.

## Read state

Use `agent-balancer status --json --cached` for every read. It reads saved readings only, starts
no child process and spends no model call. Plain `agent-balancer status --json` may check sign-in
state and is slower. Never parse the menu bar app or the log files.

## Before every launch

1. Run `agent-balancer pick --json --model <model>` with a command timeout of at least 90 seconds.
2. Read the exit code.
   - Exit 0: a recipe. Apply it.
   - Exit 2: nothing fits. Do not launch. Leave the work waiting and show `reason` to the user.
   - Exit 1: no pick. Report the error text and stop.
3. Apply `env` and `args` (or the typed strings) the same way for every account.
   - Typing a line: type `<launchPrefix>claude <your own flags> <launchArgs> '<prompt>'` as one
     literal line. Copy `launchPrefix` and `launchArgs` exactly. Never rebuild them, never wrap
     the line in a script, never use a substitution. When `backgroundOnly` is true, the line must
     be a `claude --bg` launch.
   - Starting `claude` from a program: run `pick --json --caller launcher`. Start `claude` with
     your own environment minus every name in `unsetEnv`, plus every entry of `env`, and put
     `args` after your own flags, as an argument array.
4. One pick is for one launch, within a few minutes. If you did not launch, do nothing about it
   and pick again. Use `--exclude <label>` for a label your own check refused or one that just
   hit a limit.

## Rules

- Pass your own settings to `pick --settings '<json>'`. Never pass `--settings` to `claude`
  yourself. The recipe already adds the one `--settings` the session needs.
- Never branch on the account `kind`. The recipe is the same for every account.
- Never open, copy, print or keep a launch file, and never read anything under
  `~/.agent-balancer/`.
- Never build a folder or file path yourself.
- When a session needs claude.ai connectors, Remote Control or claude.ai skills, run
  `agent-balancer pick --json --full-login --model <model>`. Accounts without a full login cannot
  give those.
- Information is not authority: decide a launch from `pick`, never from `status`, `events` or
  `history`.
- Run `agent-balancer events --json --after <cursor>` to learn what changed. Keep the `cursor`
  from each answer. If `gap` is true or `recordId` is new, read `status --json --cached` once and
  carry on from the new cursor. An event can come more than once: read each one as the state it
  reports, never as a count. After a failed save an event can also be missing, and a label's last
  event and `status --json --cached` can disagree; either can be behind, and only `pick` decides.
- Never run `agent-balancer run`, `uninstall`, `remove`, `login` or `link`. They are for the user's
  own terminal. In a chat shell `run` only prints the line for the user to type.

The full contract is in `docs/CONTRACT.md` of the agent-balancer repository.

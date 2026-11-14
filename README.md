# agent-balancer

A macOS tool that reads how much of each Claude Code subscription is used and picks the account
with the most room for the next launch.

> agent-balancer is an independent project. It has no affiliation with Anthropic, and Anthropic
> does not endorse it. Claude and Claude Code are products of Anthropic.

## Status

This repository holds the package skeleton: the build, the checks and the design. The features
arrive slice by slice. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Privacy

- No telemetry.
- No network calls of its own. The only program that talks to the network is `claude`.
- It never reads the Claude login, the Keychain or the credential files.
- The only credential it keeps is a setup-token that you make yourself.
- Its files are mode 0600 and its folders are mode 0700.

## Token accounts

A token account uses a setup-token that you make yourself with `claude setup-token`.

1. `agent-balancer add <label> [--ends YYYY-MM-DD | --ending-soon]` writes the registry entry. The
   `--ends` date must be a real day, today or later.
2. `agent-balancer login <label>` in Terminal runs `claude setup-token`, takes the token without
   showing it, and saves it to `tokens/<label>.json` (mode 0600) in one atomic rename.
3. Running `login <label>` again replaces the token and rewrites that label's launch files.
4. `agent-balancer remove <label>` deletes the token file, the launch files and the stored reading.
   A launch file that a session still names, or that a pick returned in the last
   `picker.leaseMinutes`, is overwritten with a placeholder that is not a token and removed later.
   If a remove stops part way, run it again: it finishes, even when the account entry is already
   gone, and `agent-balancer doctor` lists a token file that has no account.

Whether a new token ends the old one has not been checked yet, so treat the old token as working
until its year ends. No way to cancel a setup-token is documented, so after every replace and every
remove the tool prints that the old token may keep working until its year ends.
The tool estimates a token's end as 365 days after it was saved and warns 14 days before.

## Build

You need macOS on Apple silicon and Swift 6.2 or later.

```
swift build -c release
.build/release/agent-balancer --version
```

## Check

`scripts/check.sh` runs the typecheck, the format lint, the tests, the safety scan and the secret
scan. It needs [gitleaks](https://github.com/gitleaks/gitleaks) on your `PATH` and fails without
it.

```
scripts/check.sh
```

## License

MIT. See [LICENSE](LICENSE).

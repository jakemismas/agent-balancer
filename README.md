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

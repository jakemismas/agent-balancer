# Contributing

Thank you for helping. This page tells you what you need, how to build and check a change, the
rules a change must keep, and how a change lands. Follow the [code of conduct](CODE_OF_CONDUCT.md).

## Tools

- macOS 14 or later on Apple silicon and the Swift toolchain, version 6.2 or later.
- swift-format, for the format lint.
- gitleaks on your `PATH` (`brew install gitleaks`).
- The GitHub CLI (`gh`) for issues and pull requests.

`scripts/check.sh` must pass before you open a pull request.

## Build and check

```
swift build -c release
.build/release/agent-balancer --version
scripts/check.sh
```

`scripts/check.sh` runs the typecheck, the format lint, the tests, the safety scan, the README
check and the secret scan, and fails on any step. It needs gitleaks on your `PATH` and fails
without it. CI runs the same script on every pull request.

`scripts/build-app.sh` builds the menu bar app into `build/`. `scripts/render-views.sh` builds the
app and the command line tool, draws the app's views into `build/renders/`, copies the README
pictures that run drew into `docs/media/` and runs the README check; the pictures show made-up
accounts only.

## Safety rules

`scripts/check.sh` runs `scripts/check-safety.sh`, a text scan of the sources, so
`scripts/check-safety.sh` fails the build when a change breaks one of these rules:

- No network code: no `URLSession`, Network framework or socket calls, and no web address but the
  usage page.
- No Keychain or Security framework calls, and no source names `.credentials.json` or
  `.claude.json`.
- No shell execution and no child processes outside the `Runner` module: no source outside it
  names `Process`, `NSTask` or `posix_spawn`, or calls `system`, `popen`, `dlopen` or a function
  whose name starts with `execv`. A test also checks that the `claude` runner builds no shell
  command.
- Tokens are read only by the `Tokens` and `Launch` modules: no other source and no test names the
  token or launch folders.
- Only the `Paths` module reads files, and only the no-follow writer writes or deletes them.
- Sources, tests, docs, the skill file and the Markdown files at the top of the repository use
  example.com email addresses only and hold no organization id.

The scan matches names in the text, so it catches only what it names. Keep these by hand as
well: pictures and tests use made-up accounts only, and never put a real token, address or home
path in an issue, a commit or a test.

## Issue first

Open an issue before a large change, and describe the change with a description, acceptance
criteria you can test and non-goals. Branch from the issue and open the pull request with
`Fixes #<number>`.

Output that callers rely on is a contract. If a change alters a field, an exit code or a rule in
[docs/CONTRACT.md](docs/CONTRACT.md), say so in the issue. A change to that page needs the
maintainer's decision. Update the page and the golden-output tests in the same change, and bump
`schemaVersion` when a stable field changes. A new optional field does not need a bump.

## Landing

Each change lands as one commit on `main`. Fold review fixes into that commit instead of adding
fix-up commits, keep the subject under 70 characters in the imperative mood, and add a line to
[CHANGELOG.md](CHANGELOG.md). The maintainer folds your pull request into one commit, keeps you as
its author and lands it by a fast-forward push to `main` after the checks pass. The merge button
is not used.

## License

By contributing you agree that your work is licensed under the MIT license in
[LICENSE](LICENSE).

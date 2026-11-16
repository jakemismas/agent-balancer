# Releasing

This page describes how to cut a release and how to test the install before the release goes
public.

## What a release holds

| File | Use |
| --- | --- |
| `agent-balancer-<version>-arm64.tar.gz` | The prebuilt command line tool and the skill folder. The Homebrew formula installs it. |
| `AgentBalancerBar.zip` | The menu bar app. It is ad hoc signed and not notarized. |
| `SHA256SUMS` | The checksums of the two files above. |
| `agent-balancer.rb` | The formula, with the release URL and checksum filled in. Copy it into the `Formula` folder of your tap. |

The formula installs the prebuilt tool. It never builds from source, because building needs Swift
tools 6.2 and the Command Line Tools of macOS 14 carry an older Swift. Its `depends_on` lines name
only the Mac itself (Apple silicon, macOS 14), and the tool links only libraries that ship with
macOS, so a Mac with no developer tools installs and runs it. `scripts/package-release.sh` fails
when the tool links anything else.

## Check the files locally

1. Run `scripts/package-release.sh --dry-run`. It builds the tool and the app, writes the files
   to `build/release/`, and checks them: the archive layout, the tool's version, the app's ad hoc
   signature and minimum system version, the formula's syntax and that it has no build step.
2. CI runs the same step in its `install` job, then installs the formula from a local tap on a
   clean runner, runs `brew test` and removes it.

## Cut a release

1. Set `Sources/Core/Version.swift` and the `CHANGELOG.md` heading to the new version, and land
   the change. The release notes are the `CHANGELOG.md` entry under `## <version>`, so the entry
   must exist and hold text. `scripts/release-notes.sh <version>` prints it.
2. Start the `release` workflow by hand. Its version input must equal the `Version.swift` value,
   or that value plus `-rcN` when the prerelease switch is on. `scripts/release-version.sh check
   <version> <true|false>` applies the same rule, and the workflow and `package-release.sh` both
   call it. A prerelease of `1.0.0` is `1.0.0-rc1`, `1.0.0-rc2` and so on; `1.0.0-rc` and
   `1.0.0-rc1abc` fail, and so does a plain version with the switch on.
3. The run checks the tree, packages the files, attests the archive and the zip, and creates the
   GitHub release with the notes.
4. Update the tap by hand (see Update the tap below).

## Update the tap

1. Open the run's log. The Package step ends with the paths of the files and the formula's URL:

   ```
   package-release: 1.0.0
     build/release/agent-balancer-1.0.0-arm64.tar.gz
     build/release/AgentBalancerBar.zip
     build/release/SHA256SUMS
     build/release/agent-balancer.rb (url https://github.com/<owner>/agent-balancer/releases/download/v1.0.0/agent-balancer-1.0.0-arm64.tar.gz)
   ```

   The same files are attached to the release.
2. Download `agent-balancer.rb` and `SHA256SUMS` from the release.
3. Check that the `sha256` line in `agent-balancer.rb` equals the line for the
   `agent-balancer-<version>-arm64.tar.gz` file in `SHA256SUMS`, and that `url` names the
   release's tag.
4. Copy `agent-balancer.rb` into the `Formula` folder of the tap repository, commit it and push.
   Do not run `brew bump-formula-pr`: it computes its own checksum from the URL.
5. Run `brew update` and `brew info <owner>/tap/agent-balancer`. It shows the new version.

## Make the repository public

Do these steps after the release smoke below passes and the release commit has landed. Each one
needs the maintainer's yes.

1. Run `gitleaks git` over the full history, and scan the history with an email pattern. Allow
   only `example.com`, the commit identity and `users.noreply.github.com`.
2. Run `git log --all -p`, every issue and pull request title, body and comment, and the release
   notes through the local banned-string list. Any hit blocks the flip.
3. Confirm that no `CLAUDE.md` or `.claude/` file ever entered history, that
   `git log --merges origin/main` prints nothing, and that `main` has 27 commits or fewer.
4. Change the visibility to public.
5. Enable secret scanning, push protection, private vulnerability reporting and the CodeQL
   default setup.
6. Add a ruleset on `main` (linear history, the CI check required, no force pushes, no deletion).
7. Add a tag ruleset that limits creating, moving and deleting `v*` tags to the release workflow
   and the maintainer.
8. Protect the tap repository's `main` the same way, and add Scorecard.

## Repository description and topics

A draft for the maintainer to set in the repository's About settings at the flip, with the other
steps above. Nothing sets them before then. The words are the ones a person uses when they search
for this problem, in plain sentences.

Description:

```
For anyone with several Claude Code accounts or subscriptions: agent-balancer reads each account's five-hour and weekly usage and picks the account for your next launch. A command line tool, a macOS menu bar app and a skill.
```

Topics: `claude-code`, `claude`, `usage-limits`, `rate-limits`, `multiple-accounts`,
`account-switcher`, `load-balancer`, `orchestration`, `macos`, `menu-bar`, `cli`, `swift`.

## After the flip

1. Publish the tap repository (`<owner>/homebrew-tap`) with a first formula, or leave the
   `Formula` folder empty until step 4.
2. Start the `release` workflow with version `1.0.0-rc1` and the prerelease switch on. It creates
   the `v1.0.0-rc1` prerelease with the files and the notes.
3. Update the tap from that run's printed checksums (see Update the tap above). In the virtual
   machine, run the real install:

   ```
   brew install <owner>/tap/agent-balancer
   agent-balancer --version
   brew test <owner>/tap/agent-balancer
   ```

   The tool reports `1.0.0`, and the formula's test accepts that for the `1.0.0-rc1` formula.
   Download `AgentBalancerBar.zip` from the prerelease, run
   `gh attestation verify AgentBalancerBar.zip --repo <owner>/agent-balancer`, and open the app
   the way the install section of `docs/GUIDE.md` says.
4. Only then start the `release` workflow with version `1.0.0` and the prerelease switch off. It
   creates the `v1.0.0` tag and the release, with the `1.0.0` entry of `CHANGELOG.md` as notes,
   the checksums and the attestations.
5. Update the tap by hand from the printed checksums, then run `brew update && brew upgrade
   agent-balancer` and check `agent-balancer --version`.

## Install smoke

Run this in a fresh macOS 14 virtual machine, or on a second Mac with its own Homebrew, with Claude
Code installed and one test account signed in. The maintainer reviews the result before the
first release goes public.

1. Put the release files in a folder with no spaces in its path, for example `~/release`.
2. Fill the formula for that folder. This makes `~/release/agent-balancer.rb` with `file://` URLs:

   ```
   scripts/package-release.sh --dry-run --out ~/release
   ```

   The script refuses a folder that holds files it did not make, so use a new or empty folder.

   On a machine without the source tree, edit the `url` line of the downloaded formula to the
   `file://` path of the archive and check that `sha256` equals the line in `SHA256SUMS`.
3. Make a local tap and install from it:

   ```
   brew tap-new --no-git local/ab
   mkdir -p "$(brew --repository local/ab)/Formula"
   cp ~/release/agent-balancer.rb "$(brew --repository local/ab)/Formula/agent-balancer.rb"
   brew install local/ab/agent-balancer
   ```

   Homebrew 7 refuses a formula from an untrusted tap until you run
   `brew trust --formula local/ab/agent-balancer`. Trust only that formula. CI runs the same
   command when `brew trust` exists.
4. Check the tool:

   ```
   which agent-balancer
   agent-balancer --version
   agent-balancer doctor
   ls "$(brew --prefix)/share/agent-balancer/skill/agent-balancer"
   brew info local/ab/agent-balancer
   ls ~/.agent-balancer
   ```

   `which` prints `$(brew --prefix)/bin/agent-balancer`. `doctor` says setup has not run. `brew
   info` shows the caveat to run `agent-balancer uninstall` before you remove the tool. The last
   command fails, because the tool writes nothing before `init`.
5. Open the app the way a download opens it. Mark the zip as downloaded, unzip it, move the app to
   Applications and follow the four steps of the install section of `docs/GUIDE.md`. Check that
   they match what macOS shows.
6. Run the smoke list of section 15 of `docs/ARCHITECTURE.md`.
7. Remove the formula with `brew uninstall local/ab/agent-balancer` and the tap with
   `brew untap local/ab`.

## Known limits of this release

- The app is ad hoc signed and not notarized, so each install and each upgrade needs the Open
  Anyway steps. The Homebrew cask waits for a signing decision.
- Release builds are arm64 only.

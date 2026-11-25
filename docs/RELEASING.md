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

1. Set `Sources/Core/Version.swift` and `release` in `Tests/CLITests/ReleaseScriptTests.swift`
   to the new version, and set `previous` there to the version before it. In `CHANGELOG.md`, add
   a `## <version>` heading above the shipped entry, and move every line added since the last
   release under the new heading, unchanged and in order: between releases each change adds its
   line at the end of the newest entry, so those lines end the shipped entry. Leave the shipped
   entry as it was at its release. Then land the change. The tests check the tool's version, the
   version rule and the newest `CHANGELOG.md` entry against `release` and `previous`, and each
   shipped entry against its pin (see step 3), so a line left in a shipped entry fails them. The
   release notes are the `CHANGELOG.md` entry under `## <version>`, so the entry must exist and
   hold text. `scripts/release-notes.sh <version>` prints it.
2. Start the `release` workflow by hand. Its version input must equal the `Version.swift` value,
   or that value plus `-rcN` when the prerelease switch is on. `scripts/release-version.sh check
   <version> <true|false>` applies the same rule, and the workflow and `package-release.sh` both
   call it. A prerelease of `1.0.0` is `1.0.0-rc1`, `1.0.0-rc2` and so on; `1.0.0-rc` and
   `1.0.0-rc1abc` fail, and so does a plain version with the switch on.
3. The run checks the tree, packages the files, attests the archive and the zip, and creates the
   GitHub release and its tag `v<version>` with the notes. `gh release create` keeps a tag that
   already exists, whatever commit it names, so the run stops before it packages anything, and
   again just before it publishes, when `v<version>` already exists on origin at another commit;
   its error names the tag. Then pin the entry it released: add its version to
   `shippedNotes` in `Tests/CLITests/ReleaseScriptTests.swift` with the byte count and the SHA-256
   of its notes at the run's tag, as `"<version>": Pin(bytes: <count>, sha256: "<SHA-256>")`, and
   land the change. After `git fetch --tags`, these commands print the count, then the SHA-256
   and a dash, where `<tag>` is the run's tag and `<version>` the entry's version (for
   `v1.0.0-rc1`, the entry is `1.0.0`). When the tag or the entry is missing, they stop with an
   error and print neither:

   ```
   notes="$(git show <tag>:CHANGELOG.md | scripts/release-notes.sh <version> /dev/stdin)" &&
     printf '%s\n' "$notes" | wc -c && printf '%s\n' "$notes" | shasum -a 256
   ```

   While `Version.swift` holds the entry's version, the tests check that the entry still starts
   with its pinned text, so new lines can go at its end until the next version change moves
   them; once the version is past it, the entry must equal its pin. After a later run of the
   same version, such as the release after its prerelease, replace the pin the same way.
4. Update the tap by hand (see Update the tap below).

## Update the tap

1. Open the run's log. The Package step prints the full path of each file it made, under the
   run's checkout, and the formula's URL, then the checksum lines. For version 1.0.0 it prints:

   ```
   package-release: 1.0.0
     /Users/runner/work/agent-balancer/agent-balancer/build/release/agent-balancer-1.0.0-arm64.tar.gz
     /Users/runner/work/agent-balancer/agent-balancer/build/release/AgentBalancerBar.zip
     /Users/runner/work/agent-balancer/agent-balancer/build/release/SHA256SUMS
     /Users/runner/work/agent-balancer/agent-balancer/build/release/agent-balancer.rb (url https://github.com/<owner>/agent-balancer/releases/download/v1.0.0/agent-balancer-1.0.0-arm64.tar.gz)
   package-release: checksums (SHA-256)
     <SHA-256>  agent-balancer-1.0.0-arm64.tar.gz
     <SHA-256>  AgentBalancerBar.zip
   package-release: formula sha256 <SHA-256>
   ```

   Each `<SHA-256>` is 64 hex digits. The same files are attached to the release.
2. Download `agent-balancer.rb` and `SHA256SUMS` from the release.
3. Check that the `sha256` line in `agent-balancer.rb` equals the line for the
   `agent-balancer-<version>-arm64.tar.gz` file in `SHA256SUMS`, and that `url` names the
   release's tag.
4. Copy `agent-balancer.rb` into the `Formula` folder of the tap repository, commit it and push.
   Do not run `brew bump-formula-pr`: it computes its own checksum from the URL.
5. Run `brew update` and `brew info <owner>/tap/agent-balancer`. It shows the new version. On a
   Mac where Homebrew 7 has not trusted the formula, `brew info` refuses it until you run
   `brew trust --formula <owner>/tap/agent-balancer`.

## Make the repository public

Do these steps after the release smoke below passes and the release commit has landed. Each one
needs the maintainer's yes.

1. Run `gitleaks git` over the full history, and scan the history with an email pattern. Allow
   only `example.com`, the commit identity and `users.noreply.github.com`.
2. Run `git log --all -p`, every issue and pull request title, body and comment, and the release
   notes through the local banned-string list. Any hit blocks the flip.
3. Confirm that no `CLAUDE.md` or `.claude/` file ever entered history, and that
   `git log --merges origin/main` prints nothing: each change lands as one commit by a
   fast-forward push, so `main` holds no merge commit. The step checks that shape, not a count
   of commits, which grows with every change.
4. Change the visibility to public.
5. Enable secret scanning, push protection, private vulnerability reporting and the CodeQL
   default setup.
6. Add a ruleset on `main` (linear history, the CI check required, no force pushes, no deletion).
   Set its enforcement status to Active. The form starts at Disabled, and a disabled ruleset
   restricts nothing.
7. Check that a tag ruleset lets only the maintainer move or delete a `v*` tag, or add one:
   - Set its enforcement status to Active. The form starts at Disabled.
   - Target `v*` tags, and select only the Restrict updates and Restrict deletions rules.
   - Add the maintainer's own account, a user and not a role, as the only entry in its Bypass list.
   - Leave Restrict creations clear. The release workflow creates the tag through
     `gh release create` with its `GITHUB_TOKEN`, a token of the GitHub Actions app, and GitHub
     refuses that app as a bypass actor whoever owns the repository ("Actor GitHub Actions
     integration must be part of the ruleset source or owner organization"). A Restrict creations
     rule would block the release workflow, so creating a `v*` tag stays with every account and
     workflow with write access. A `v*` tag made first at another commit stops the release run,
     whose error names the tag; as the ruleset's bypass, you can delete that tag.
   - Moving the repository from a personal account to an organization does not change this by
     itself. There, restricting creation takes a GitHub App that the organization owns, installed
     on this repository only, with write access to contents only. GitHub installs a private app
     only on the account that owns it, so an app of the maintainer's personal account cannot be
     installed on the organization. The app is the bypass of a second tag ruleset for `v*` tags,
     set to Active, that holds only the Restrict creations rule, with the maintainer's own account
     as its other bypass. Keep the app out of the first ruleset: a bypass covers every rule of its
     ruleset, so there the app could move and delete `v*` tags.
   - Keep the app's private key where only the release job, run from `main` with the
     maintainer's approval, can read it: a secret of a deployment environment that the release
     job names, whose only deployment branch is `main` and whose required reviewer is the
     maintainer. Not a repository secret: every account with write access can push a workflow
     that reads one, then make a `v*` tag through the second ruleset's bypass or copy the key.
   - Change the release workflow before you add the second ruleset: the workflow must create the
     tag with the app's token, made from that key, which it does not do today, and
     `scripts/check-release.sh` refuses the secret it needs. Added first and set to Active, the
     Restrict creations rule blocks the release workflow at its Publish step. Until the workflow
     changes, creation stays with write access.
   - After a move, check the first ruleset again, and the `main` ruleset of step 6: GitHub's page
     on transferring a repository does not list rulesets among what moves with it.
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
2. Start the `release` workflow with version `1.2.0-rc1` and the prerelease switch on. It creates
   the `v1.2.0-rc1` prerelease with the files and the notes. Then pin the `1.2.0` entry as step 3
   of Cut a release says.
3. Update the tap from that run's printed checksums (see Update the tap above). In the virtual
   machine, run the real install:

   ```
   brew install <owner>/tap/agent-balancer
   agent-balancer --version
   brew test <owner>/tap/agent-balancer
   ```

   The tool reports `1.2.0`, and the formula's test accepts that for the `1.2.0-rc1` formula.
   Download `AgentBalancerBar.zip` from the prerelease, run
   `gh attestation verify AgentBalancerBar.zip --repo <owner>/agent-balancer`, and open the app
   the way the install section of `docs/GUIDE.md` says.
4. Only then start the `release` workflow with version `1.2.0` and the prerelease switch off. It
   creates the `v1.2.0` tag and the release, with the `1.2.0` entry of `CHANGELOG.md` as notes,
   the checksums and the attestations. Then replace the `1.2.0` pin as step 3 of Cut a release
   says.
5. Update the tap by hand from the printed checksums, then run `brew update && brew upgrade
   agent-balancer` and check `agent-balancer --version`.

## Install smoke

Run this in a fresh macOS 14 virtual machine, or on a second Mac with its own Homebrew, with Claude
Code installed and one test account signed in. The maintainer reviews the result before the
first release goes public.

1. Put the release files in a folder with no spaces in its path, for example `~/release`.
2. Fill the formula for that folder. The dry run writes the archive, the app zip, `SHA256SUMS`
   and the formula, with a `file://` URL, to that folder and checks them:

   ```
   scripts/package-release.sh --dry-run --out ~/release
   ```

   The script refuses a folder that holds files it did not make, so use a new or empty folder.
   It ends by printing the full path of each file it made, the formula's `file://` URL and the
   checksums. For version 1.0.0 and a home folder of `/Users/example`, it prints:

   ```
   package-release: 1.0.0
     /Users/example/release/agent-balancer-1.0.0-arm64.tar.gz
     /Users/example/release/AgentBalancerBar.zip
     /Users/example/release/SHA256SUMS
     /Users/example/release/agent-balancer.rb (url file:///Users/example/release/agent-balancer-1.0.0-arm64.tar.gz)
   package-release: checksums (SHA-256)
     <SHA-256>  agent-balancer-1.0.0-arm64.tar.gz
     <SHA-256>  AgentBalancerBar.zip
   package-release: formula sha256 <SHA-256>
   package-release: dry run, nothing published
   ```

   The steps below name these files by those paths, with `~` for the home folder.

   On a machine without the source tree, put the downloaded files in `~/release` instead, edit
   the `url` line of `~/release/agent-balancer.rb` to the `file://` URL of
   `~/release/agent-balancer-<version>-arm64.tar.gz`, written with the full path as above, and
   check that the formula's `sha256` equals that file's line in `~/release/SHA256SUMS`.
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
5. Open the app the way a download opens it. Mark `~/release/AgentBalancerBar.zip` as downloaded,
   unzip it, move the app to Applications and follow the four steps of the install section of
   `docs/GUIDE.md`. Check that they match what macOS shows.
6. Run the smoke list of section 15 of `docs/ARCHITECTURE.md`.
7. Remove the formula with `brew uninstall local/ab/agent-balancer` and the tap with
   `brew untap local/ab`.

## Known limits of this release

- The app is ad hoc signed and not notarized, so each install and each upgrade needs the Open
  Anyway steps. The Homebrew cask waits for a signing decision.
- Release builds are arm64 only.

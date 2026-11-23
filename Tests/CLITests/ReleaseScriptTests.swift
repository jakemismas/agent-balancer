import Core
import Foundation
import Testing

/// The release version rules, the release notes, the output folder guard, the check that the
/// README and the release page agree with the packaging, the packaging script's checks on what it
/// made, and CI's time limits and concurrency group.
@Suite struct ReleaseScriptTests {
    static func script(_ name: String) -> URL {
        Support.root.appendingPathComponent("scripts/\(name)")
    }

    static func current() throws -> String {
        let out = try Support.run(
            script("release-version.sh"), ["current"], env: ["PATH": "/usr/bin:/bin"])
        #expect(out.status == 0)
        return String(decoding: out.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func check(_ version: String, _ pre: String) throws -> Int32 {
        try Support.run(
            script("release-version.sh"), ["check", version, pre],
            env: ["PATH": "/usr/bin:/bin"]
        ).status
    }

    @Test func currentIsTheVersionTheToolReports() throws {
        #expect(try Self.current() == Version.current)
    }

    @Test func plainVersionPassesWithPrereleaseOff() throws {
        let cur = try Self.current()
        #expect(try Self.check(cur, "false") == 0)
    }

    @Test func rcVersionPassesWithPrereleaseOn() throws {
        let cur = try Self.current()
        for n in ["1", "2", "10", "99"] {
            #expect(try Self.check("\(cur)-rc\(n)", "true") == 0, "rc\(n)")
        }
    }

    @Test func wrongPairsAndValuesFail() throws {
        let cur = try Self.current()
        let bad: [(String, String)] = [
            ("\(cur)-rc1", "false"), (cur, "true"), ("\(cur)-rcX", "true"),
            ("\(cur)-rc1abc", "true"), ("\(cur)-rc", "true"), ("\(cur)-rc0", "true"),
            ("\(cur)-rc01", "true"), ("\(cur)-rc1-x", "true"), ("\(cur)x", "false"),
            ("", "false"), ("9.9.9", "false"), ("9.9.9-rc1", "true"), (cur, "yes"),
        ]
        for (version, pre) in bad {
            #expect(try Self.check(version, pre) != 0, "\(version) \(pre)")
        }
    }

    /// The release this tree builds and the one before it. A new version changes both.
    static let release = "1.1.0"
    static let previous = "1.0.0"

    @Test func theVersionIsThisRelease() throws {
        #expect(Version.current == Self.release)
        #expect(try Self.current() == Self.release)
    }

    @Test func theChecksTakeThisReleaseAndRefuseThePreviousOne() throws {
        #expect(try Self.check(Self.release, "false") == 0)
        #expect(try Self.check("\(Self.release)-rc1", "true") == 0)
        #expect(try Self.check(Self.previous, "false") != 0)
        #expect(try Self.check("\(Self.previous)-rc2", "true") != 0)
    }

    // MARK: Release notes

    static func notes(_ version: String, changelog: String? = nil) throws -> Support.Output {
        var args = [version]
        var dir: URL?
        if let changelog {
            let d = try Support.makeTempDir()
            dir = d
            let file = d.appendingPathComponent("CHANGELOG.md")
            try changelog.write(to: file, atomically: true, encoding: .utf8)
            args.append(file.path)
        }
        defer { if let dir { try? FileManager.default.removeItem(at: dir) } }
        return try Support.run(
            script("release-notes.sh"), args, env: ["PATH": "/usr/bin:/bin"])
    }

    static let sample =
        "# Changelog\n\n## 2.0.0\n\n- New thing.\n- Other thing.\n\n## 1.0.0\n\n- Old thing.\n"

    @Test func notesAreTheEntryOfThatVersion() throws {
        let out = try Self.notes("2.0.0", changelog: Self.sample)
        #expect(out.status == 0)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "- New thing.\n- Other thing.\n")
    }

    @Test func aPrereleaseTakesTheBaseVersionsEntry() throws {
        let out = try Self.notes("1.0.0-rc2", changelog: Self.sample)
        #expect(out.status == 0)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "- Old thing.\n")
    }

    @Test func aMissingOrEmptyEntryFails() throws {
        #expect(try Self.notes("3.0.0", changelog: Self.sample).status != 0)
        #expect(try Self.notes("2.0.0", changelog: "## 2.0.0\n\n\n## 1.0.0\n- x\n").status != 0)
    }

    @Test func theRealChangelogHasAnEntryForTheCurrentVersion() throws {
        let out = try Self.notes(try Self.current())
        #expect(out.status == 0)
        #expect(!out.stdout.isEmpty)
    }

    @Test func theNewestChangelogEntryIsThisReleaseAboveThePreviousOne() throws {
        let text = try String(
            contentsOf: Support.root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let headings = text.split(separator: "\n").filter { $0.hasPrefix("## ") }.map(String.init)
        #expect(Array(headings.prefix(2)) == ["## \(Self.release)", "## \(Self.previous)"])
        let out = try Self.notes(Self.release)
        #expect(out.status == 0)
        #expect(!out.stdout.isEmpty)
    }

    /// The 1.0.0 entry is history, so its notes keep the SHA-256 they had at that build.
    static let shippedNotes = "ee18d094748a6553066cac0a0dc40829dc4324f04b64ef72ba92ee1d57f40771"

    @Test func theShippedEntryKeepsItsTextByteForByte() throws {
        let out = try Self.notes("1.0.0")
        #expect(out.status == 0)
        let sum = try Support.run(
            URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256"], env: ["PATH": "/usr/bin:/bin"],
            stdin: out.stdout)
        #expect(sum.status == 0)
        #expect(
            String(decoding: sum.stdout, as: UTF8.self).prefix(64) == Self.shippedNotes,
            "a new line goes at the end of the newest entry")
    }

    // MARK: Output folder guard

    static func package(out: URL, home: URL) throws -> Support.Output {
        try Support.run(
            script("package-release.sh"), ["--dry-run", "--owner", "owner", "--out", out.path],
            env: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": home.path])
    }

    @Test func aFolderWithOtherFilesIsRefusedAndKept() throws {
        let fm = FileManager.default
        let dir = try Support.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let keep = dir.appendingPathComponent("keep.txt")
        try "data".write(to: keep, atomically: true, encoding: .utf8)
        let out = try Self.package(out: dir, home: dir)
        #expect(out.status != 0)
        #expect(String(decoding: out.stderr, as: UTF8.self).contains("not empty"))
        #expect(fm.fileExists(atPath: keep.path))
    }

    @Test func theHomeFolderAndTheRootAreRefused() throws {
        let fm = FileManager.default
        let home = try Support.makeTempDir()
        defer { try? fm.removeItem(at: home) }
        let keep = home.appendingPathComponent("keep.txt")
        try "data".write(to: keep, atomically: true, encoding: .utf8)
        for target in [home, URL(fileURLWithPath: "/")] {
            let out = try Self.package(out: target, home: home)
            #expect(out.status != 0, "\(target.path)")
        }
        #expect(fm.fileExists(atPath: keep.path))
    }

    @Test func theFinalOutputPrintsTheChecksums() throws {
        let text = try String(contentsOf: Self.script("package-release.sh"), encoding: .utf8)
        let tail = String(
            text[
                (text.range(of: "echo \"package-release: $VERSION\"")?.lowerBound ?? text.startIndex)...
            ])
        #expect(tail.contains("SHA256SUMS\""))
        #expect(tail.contains("sed 's/^/  /' \"$OUT/SHA256SUMS\""))
        #expect(tail.contains("formula sha256 $SHA"))
    }

    // MARK: README and release page against the packaging

    static let files = [
        "scripts/package-release.sh", "scripts/check-release.sh", "packaging/agent-balancer.rb",
        ".github/workflows/release.yml", ".github/workflows/ci.yml", "README.md",
        "docs/RELEASING.md",
    ]

    static func copy(to dest: URL) throws {
        let fm = FileManager.default
        for file in files {
            let target = dest.appendingPathComponent(file)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: Support.root.appendingPathComponent(file), to: target)
        }
    }

    static func runCheck(in root: URL) throws -> Support.Output {
        try Support.run(
            root.appendingPathComponent("scripts/check-release.sh"), [root.path],
            env: ["PATH": "/usr/bin:/bin"])
    }

    @Test func theRealFilesAgree() throws {
        let out = try Self.runCheck(in: Support.root)
        #expect(out.status == 0, "\(String(decoding: out.stderr, as: UTF8.self))")
    }

    @Test(arguments: [
        ("README.md", "AgentBalancerBar.zip --repo", "AgentBalancerBar.zip --rep0"),
        (
            "README.md", "brew install jakemismas/tap/agent-balancer",
            "brew install jakemismas/tap/other"
        ),
        (
            "README.md", "brew install jakemismas/tap/agent-balancer",
            "brew install someone/tap/agent-balancer"
        ),
        (
            "README.md", "AgentBalancerBar.zip --repo jakemismas/agent-balancer",
            "AgentBalancerBar.zip --repo someone/agent-balancer"
        ),
        ("README.md", "`AgentBalancerBar.app`", "`Other.app`"),
        (".github/workflows/release.yml", "build/release/AgentBalancerBar.zip", "build/x.zip"),
        (".github/workflows/release.yml", "actions/attest-build-provenance@", "actions/other@"),
        ("docs/RELEASING.md", "SHA256SUMS", "SUMS"),
        ("docs/RELEASING.md", "gh release create", "gh release new"),
        (
            ".github/workflows/release.yml", "gh release create \"v$VERSION\"",
            "gh release upload \"v$VERSION\""
        ),
        (".github/workflows/release.yml", "if: github.ref == 'refs/heads/main'", "if: true"),
        (".github/workflows/release.yml", "git merge-base --is-ancestor", "git log"),
        (
            ".github/workflows/release.yml", "permissions:\n  contents: read",
            "permissions:\n  contents: write"
        ),
        (
            ".github/workflows/release.yml", "      contents: write\n",
            "      contents: write\n      x: ${{ secrets.TAP_TOKEN }}\n"
        ),
        (
            ".github/workflows/release.yml", "checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
            "checkout@v4"
        ),
        (
            ".github/workflows/ci.yml", "checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
            "checkout@v4"
        ),
        (
            ".github/workflows/ci.yml", "permissions:\n  contents: read",
            "permissions:\n  contents: write"
        ),
        ("packaging/agent-balancer.rb", "class AgentBalancer < Formula", "class Other < Formula"),
    ])
    func aDriftedFileFails(file: String, from: String, to: String) throws {
        let fm = FileManager.default
        let root = try Support.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Self.copy(to: root)
        let url = root.appendingPathComponent(file)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(from))
        try text.replacingOccurrences(of: from, with: to)
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(try Self.runCheck(in: root).status != 0)
    }

    // Far more than a pipe holds, so a writer into a reader that stops early is always cut off.
    static func overAMegabyte(of line: String) -> String {
        String(repeating: line, count: (1 << 20) / line.utf8.count + 1)
    }

    @Test func aQuickStartFarLargerThanAPipePasses() throws {
        let fm = FileManager.default
        let root = try Support.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Self.copy(to: root)
        let url = root.appendingPathComponent("README.md")
        var text = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(text.range(of: "\n## Quick start\n"))
        let end = try #require(text.range(of: "\n## ", range: start.upperBound..<text.endIndex))
        text.insert(
            contentsOf: Self.overAMegabyte(of: "A plain line with nothing in it to check.\n"),
            at: end.lowerBound)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let out = try Self.runCheck(in: root)
        #expect(out.status == 0, "\(String(decoding: out.stderr, as: UTF8.self))")
    }

    @Test(arguments: [
        "APP_ZIP=\"AgentBalancerBar.zip\"\n", "CLI_NAME=\"agent-balancer-$VERSION-arm64\"\n",
    ])
    func aPackagingScriptFarLargerThanAPipePasses(line: String) throws {
        let fm = FileManager.default
        let root = try Support.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Self.copy(to: root)
        let url = root.appendingPathComponent("scripts/package-release.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n" + line))
        try (text + Self.overAMegabyte(of: line)).write(to: url, atomically: true, encoding: .utf8)
        let out = try Self.runCheck(in: root)
        #expect(out.status == 0, "\(String(decoding: out.stderr, as: UTF8.self))")
    }

    @Test func anUnpinnedActionBeforeAMegabyteOfPinnedOnesFails() throws {
        let fm = FileManager.default
        let root = try Support.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Self.copy(to: root)
        let url = root.appendingPathComponent(".github/workflows/ci.yml")
        var text = try String(contentsOf: url, encoding: .utf8)
        let steps = try #require(text.range(of: "    steps:\n"))
        let pinned = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"
        text.insert(
            contentsOf: "      - uses: actions/checkout@v4\n" + Self.overAMegabyte(of: pinned),
            at: steps.upperBound)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let out = try Self.runCheck(in: root)
        let printed = String(decoding: out.stderr, as: UTF8.self)
        #expect(out.status == 1, "\(printed)")
        #expect(
            printed.contains("FAIL release: .github/workflows/ci.yml has an action not pinned"),
            "\(printed)")
    }

    // MARK: The packaging script's checks on what it made

    static func packagingText() throws -> [String] {
        try String(contentsOf: script("package-release.sh"), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// The lines of the packaging script from the first that starts with `start` through the next
    /// line that is `end`: one of its checks as the script runs it.
    static func packagingLines(from start: String, to end: String) throws -> String {
        let lines = try packagingText()
        let first = try #require(lines.firstIndex { $0.hasPrefix(start) }, "\(start)")
        let last = try #require(lines[first...].firstIndex(of: end), "\(end) after \(start)")
        return lines[first...last].joined(separator: "\n")
    }

    /// Runs `check` with the packaging script's shell options and `die` on the files in `dir`,
    /// which stands for the output folder. `otool` prints `dir/otool.txt`.
    static func runPackagingCheck(_ check: String, in dir: URL) throws -> Support.Output {
        let lines = try packagingText()
        let set = try #require(lines.first { $0.hasPrefix("set -") })
        let die = try #require(lines.first { $0.hasPrefix("die() ") })
        let harness = [
            set, die, #"otool() { cat "$OUT/otool.txt"; }"#,
            #"OUT="$1" CHECK="$1/check" CLI_NAME=agent-balancer-1.0.0-arm64"#,
            #"CLI_ARCHIVE="$CLI_NAME.tar.gz""#, check, "echo checked",
        ].joined(separator: "\n")
        return try Support.run(
            URL(fileURLWithPath: "/bin/bash"), ["-c", harness, "check", dir.path],
            env: ["PATH": "/usr/bin:/bin"])
    }

    /// The formula template with `line` added to its install step, once or as more than a
    /// megabyte, and whether the check refuses it.
    @Test(arguments: [
        ("", false, false), ("    system \"make\"\n", false, true),
        ("    system \"swift\", \"build\"\n", true, true),
        ("    # swift and xcode are not needed\n", true, false),
    ])
    func theFormulaCheckRefusesABuildStepAtAnyLength(line: String, megabyte: Bool, refuses: Bool)
        throws
    {
        let fm = FileManager.default
        let dir = try Support.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let template = try String(
            contentsOf: Support.root.appendingPathComponent("packaging/agent-balancer.rb"),
            encoding: .utf8)
        let install = "  def install\n"
        #expect(template.contains(install))
        try template.replacingOccurrences(
            of: install, with: install + (megabyte ? Self.overAMegabyte(of: line) : line)
        ).write(
            to: dir.appendingPathComponent("agent-balancer.rb"), atomically: true, encoding: .utf8)
        let out = try Self.runPackagingCheck(
            Self.packagingLines(from: "# The formula installs the prebuilt tool", to: "fi"),
            in: dir)
        let printed = String(decoding: out.stderr, as: UTF8.self)
        #expect(out.status == (refuses ? 1 : 0), "\(printed)")
        #expect(
            printed.contains("package-release: the formula builds from source") == refuses,
            "\(printed)")
    }

    /// A real archive that lists the tool, the skill file when `holdsSkill`, then more than a
    /// megabyte of other entries.
    @Test(arguments: [true, false])
    func theListingCheckPassesAnArchiveThatHoldsTheFilesAtAnyLength(holdsSkill: Bool) throws {
        let fm = FileManager.default
        let dir = try Support.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let name = "agent-balancer-1.0.0-arm64"
        let skill = "\(name)/skill/agent-balancer/SKILL.md"
        let other = "\(name)/skill/agent-balancer/" + String(repeating: "a", count: 200) + ".md"
        for file in ["\(name)/bin/agent-balancer", skill, other] {
            let url = dir.appendingPathComponent("stage/\(file)")
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let names = "\(name)/bin/agent-balancer\n" + (holdsSkill ? "\(skill)\n" : "")
        try (names + Self.overAMegabyte(of: other + "\n")).write(
            to: dir.appendingPathComponent("names.txt"), atomically: true, encoding: .utf8)
        let tar = try Support.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            [
                "-czf", dir.appendingPathComponent("\(name).tar.gz").path, "-C",
                dir.appendingPathComponent("stage").path, "-T",
                dir.appendingPathComponent("names.txt").path,
            ], env: ["PATH": "/usr/bin:/bin"])
        #expect(tar.status == 0, "\(String(decoding: tar.stderr, as: UTF8.self))")
        let out = try Self.runPackagingCheck(
            Self.packagingLines(from: "listing=", to: "done"), in: dir)
        let printed = String(decoding: out.stderr, as: UTF8.self)
        #expect(out.status == (holdsSkill ? 0 : 1), "\(printed)")
        #expect(
            printed.contains("package-release: \(name).tar.gz lacks \(skill)") == !holdsSkill,
            "\(printed)")
    }

    /// The tool's library list with `line` after its first library, once or as more than a
    /// megabyte, and whether the check refuses it.
    @Test(arguments: [
        ("\t/usr/lib/libc++.1.dylib (compatibility version 1.0.0)\n", false, false),
        ("\t/opt/homebrew/lib/libextra.dylib (compatibility version 1.0.0)\n", false, true),
        ("\t/opt/homebrew/lib/libextra.dylib (compatibility version 1.0.0)\n", true, true),
        ("\t/System/Library/Frameworks/AppKit.framework/AppKit (current 1)\n", true, false),
    ])
    func theLibraryCheckRefusesALibraryOutsideTheSystemAtAnyLength(
        line: String, megabyte: Bool, refuses: Bool
    ) throws {
        let fm = FileManager.default
        let dir = try Support.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let first =
            "bin/agent-balancer:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
        try (first + (megabyte ? Self.overAMegabyte(of: line) : line)).write(
            to: dir.appendingPathComponent("otool.txt"), atomically: true, encoding: .utf8)
        let out = try Self.runPackagingCheck(
            Self.packagingLines(from: "# The tool links only system libraries", to: "fi"),
            in: dir)
        let printed = String(decoding: out.stderr, as: UTF8.self)
        let refusal = "package-release: the packaged tool links a library outside"
        #expect(out.status == (refuses ? 1 : 0), "\(printed)")
        #expect(printed.contains(refusal) == refuses, "\(printed)")
    }

    // MARK: CI's time limits and concurrency

    static let ciGroup =
        "${{ github.workflow }}-${{ github.event_name }}-"
        + "${{ github.event.pull_request.number || github.run_id }}"
    static let ciCancel = "${{ github.run_attempt == '1' }}"
    static let ciConcurrency =
        "concurrency:\n  group: \(ciGroup)\n  cancel-in-progress: \(ciCancel)\n"
    static let ciConcurrencyInTheCheckJob =
        "jobs:\n  check:\n    concurrency:\n      group: \(ciGroup)\n"
        + "      cancel-in-progress: \(ciCancel)\n"
    static let ciCheckJobGroup =
        "    timeout-minutes: 20\n    concurrency:\n      group: ci-check\n"
        + "      cancel-in-progress: false\n"
    static let ciLastLine = "        run: brew uninstall local/ab/agent-balancer\n"
    static let ciLastLineAndAThirdJob =
        ciLastLine + "\n  lint:\n      runs-on: macos-26\n      concurrency: lint\n"
        + "      steps:\n        - run: true\n"
    static let lacksCheckLimit =
        "must give its check job the line timeout-minutes: 20, unquoted with no comment"
    static let lacksInstallLimit =
        "must give its install job a line timeout-minutes: N, N from 1 to 359,"
        + " unquoted with no comment"
    static let lacksGroup = "must have the top-level concurrency line group: \(ciGroup)"
    static let lacksCancel =
        "must have the top-level concurrency line cancel-in-progress: \(ciCancel)"

    @Test func theRealCIPassesWithItsGroupBeforeItsJobs() throws {
        let ci = try String(
            contentsOf: Support.root.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8)
        #expect(ci.contains("\n\(Self.ciConcurrency)\njobs:\n  check:\n"))
        let out = try Self.runCheck(in: Support.root)
        #expect(out.status == 0, "\(String(decoding: out.stderr, as: UTF8.self))")
        #expect(String(decoding: out.stdout, as: UTF8.self) == "check-release: ok\n")
    }

    @Test(arguments: [
        ("    timeout-minutes: 20\n", "", ReleaseScriptTests.lacksCheckLimit),
        (
            "    timeout-minutes: 20\n", "    timeout-minutes: 19\n",
            ReleaseScriptTests.lacksCheckLimit
        ),
        (
            "    timeout-minutes: 20\n", "    timeout-minutes: 21\n",
            ReleaseScriptTests.lacksCheckLimit
        ),
        (
            "    timeout-minutes: 20\n", "    timeout-minutes: 0\n",
            ReleaseScriptTests.lacksCheckLimit
        ),
        (
            "    timeout-minutes: 20\n", "    timeout-minutes: 360\n",
            ReleaseScriptTests.lacksCheckLimit
        ),
        (
            "    timeout-minutes: 20\n", "    timeout-minutes: \"20\"\n",
            ReleaseScriptTests.lacksCheckLimit
        ),
        (
            "    timeout-minutes: 20\n    steps:\n",
            "    steps:\n      - name: Limit\n        timeout-minutes: 20\n        run: true\n",
            ReleaseScriptTests.lacksCheckLimit
        ),
        ("    timeout-minutes: 30\n", "", ReleaseScriptTests.lacksInstallLimit),
        (
            "    timeout-minutes: 30\n", "    timeout-minutes: 0\n",
            ReleaseScriptTests.lacksInstallLimit
        ),
        (
            "    timeout-minutes: 30\n", "    timeout-minutes: 360\n",
            ReleaseScriptTests.lacksInstallLimit
        ),
        (
            "    timeout-minutes: 30\n", "    timeout-minutes: 1000\n",
            ReleaseScriptTests.lacksInstallLimit
        ),
        (
            "    timeout-minutes: 30\n    steps:\n",
            "    steps:\n      - name: Limit\n        timeout-minutes: 30\n        run: true\n",
            ReleaseScriptTests.lacksInstallLimit
        ),
        (ReleaseScriptTests.ciConcurrency, "", ReleaseScriptTests.lacksGroup),
        ("  group: \(ReleaseScriptTests.ciGroup)\n", "", ReleaseScriptTests.lacksGroup),
        ("|| github.run_id }}\n", "|| github.ref }}\n", ReleaseScriptTests.lacksGroup),
        (
            "|| github.run_id }}\n", "|| github.run_id }}-${{ github.sha }}\n",
            ReleaseScriptTests.lacksGroup
        ),
        ("\nconcurrency:\n", "\nenv:\n", ReleaseScriptTests.lacksGroup),
        (
            "\(ReleaseScriptTests.ciConcurrency)\njobs:\n  check:\n",
            ReleaseScriptTests.ciConcurrencyInTheCheckJob, ReleaseScriptTests.lacksGroup
        ),
        (
            "  cancel-in-progress: \(ReleaseScriptTests.ciCancel)\n", "",
            ReleaseScriptTests.lacksCancel
        ),
        (
            "  cancel-in-progress: \(ReleaseScriptTests.ciCancel)\n",
            "  cancel-in-progress: true\n",
            ReleaseScriptTests.lacksCancel
        ),
        (
            "  cancel-in-progress: \(ReleaseScriptTests.ciCancel)\n",
            "  cancel-in-progress: false\n",
            ReleaseScriptTests.lacksCancel
        ),
        (
            "    timeout-minutes: 20\n", ReleaseScriptTests.ciCheckJobGroup,
            "must not set concurrency in its check job"
        ),
        (
            "    timeout-minutes: 30\n", "    timeout-minutes: 30\n    concurrency: ci-install\n",
            "must not set concurrency in its install job"
        ),
        (
            ReleaseScriptTests.ciLastLine, ReleaseScriptTests.ciLastLineAndAThirdJob,
            "must not set concurrency in its lint job"
        ),
        ("name: ci\n", "name: checks\n", "must have the top-level line name: ci"),
    ])
    func aCIWithoutItsLimitsOrConcurrencyFails(from: String, to: String, names: String) throws {
        let fm = FileManager.default
        let root = try Support.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Self.copy(to: root)
        let url = root.appendingPathComponent(".github/workflows/ci.yml")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: from).count == 2, "once in ci.yml: \(from)")
        try text.replacingOccurrences(of: from, with: to)
            .write(to: url, atomically: true, encoding: .utf8)
        let out = try Self.runCheck(in: root)
        let printed = String(decoding: out.stderr, as: UTF8.self)
        #expect(out.status == 1, "\(printed)")
        #expect(printed.contains("FAIL release: .github/workflows/ci.yml \(names)"), "\(printed)")
    }

    // Group names ignore case, so a copy of CI under any case of its name would share CI's groups.
    @Test(arguments: [
        ("lint.yml", "name: ci\n", true), ("lint.yaml", "name: CI\n", true),
        ("lint.yml", "name: \"ci\"\n", true), ("lint.yml", "name: 'Ci' # same group\n", true),
        ("lint.yml", "name: lint\n", false), ("lint.yml", "name: ci-lint\n", false),
    ])
    func aSecondWorkflowNamedCIIsRefused(file: String, nameLine: String, refused: Bool) throws {
        let fm = FileManager.default
        let root = try Support.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Self.copy(to: root)
        let workflows = root.appendingPathComponent(".github/workflows")
        let ci = try String(contentsOf: workflows.appendingPathComponent("ci.yml"), encoding: .utf8)
        #expect(ci.hasPrefix("name: ci\n"))
        try ci.replacingOccurrences(of: "name: ci\n", with: nameLine)
            .write(to: workflows.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let out = try Self.runCheck(in: root)
        let printed = String(decoding: out.stderr, as: UTF8.self)
        let refusal = "FAIL release: .github/workflows/\(file) must not be named ci"
        #expect(out.status == (refused ? 1 : 0), "\(printed)")
        #expect(printed.contains(refusal) == refused, "\(printed)")
    }
}

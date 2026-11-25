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
    static let release = "1.2.0"
    static let previous = "1.1.0"

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

    /// A shipped entry's notes at its release: their length in bytes and their SHA-256.
    struct Pin {
        let bytes: Int
        let sha256: String
    }

    /// Each shipped entry's notes at its release; only the newest may grow, and only at its end.
    static let shippedNotes = [
        "1.0.0": Pin(
            bytes: 40519,
            sha256: "ee18d094748a6553066cac0a0dc40829dc4324f04b64ef72ba92ee1d57f40771"),
        "1.1.0": Pin(
            bytes: 7615,
            sha256: "5fa489f8df83d14a5bf2bfc9da39a686d1d494cb3cd474038dd38052b8b96600"),
    ]

    /// What a pin step prints when it read no notes.
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { part in
            part.allSatisfy { "0123456789".contains($0) } ? Int(part) : nil
        }
        return parts.count == 3 && values.count == 3 ? values : nil
    }

    static func sha256(_ data: Data) throws -> String {
        let sum = try Support.run(
            URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256"], env: ["PATH": "/usr/bin:/bin"],
            stdin: data)
        #expect(sum.status == 0)
        return String(String(decoding: sum.stdout, as: UTF8.self).prefix(64))
    }

    /// An entry below the version must equal its pin; the entry at the version must start with it.
    static func pinProblems(
        _ changelog: String? = nil, current: String, pins: [String: Pin]
    ) throws -> [String] {
        guard let now = numbers(current) else { return ["\(current) is not a version"] }
        let text =
            try changelog
            ?? String(
                contentsOf: Support.root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        var problems: [String] = []
        var seen: Set<String> = []
        for line in text.split(separator: "\n") where line.hasPrefix("## ") {
            let version = String(line.dropFirst(3))
            guard seen.insert(version).inserted else {
                problems.append("\(line) is there twice")
                continue
            }
            guard let entry = numbers(version) else {
                problems.append("\(line) is not a version")
                continue
            }
            if entry.lexicographicallyPrecedes(now) && pins[version] == nil {
                problems.append("\(line) shipped and has no pin")
            }
        }
        for (version, pin) in pins.sorted(by: { $0.key < $1.key }) {
            guard let entry = numbers(version) else {
                problems.append("the pin \(version) is not a version")
                continue
            }
            guard pin.bytes > 0 && pin.sha256 != emptySHA256 else {
                problems.append("the pin of \(version) holds no notes")
                continue
            }
            guard pin.sha256.count == 64, pin.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
            else {
                problems.append("the pin of \(version) is not a SHA-256")
                continue
            }
            guard !now.lexicographicallyPrecedes(entry) else {
                problems.append("the pin \(version) is past \(current)")
                continue
            }
            let out = try notes(version, changelog: changelog)
            guard out.status == 0 else {
                problems.append("## \(version) is gone")
                continue
            }
            let sum = try sha256(out.stdout.prefix(pin.bytes))
            if entry.lexicographicallyPrecedes(now) {
                if out.stdout.count != pin.bytes || sum != pin.sha256 {
                    problems.append("## \(version) differs from its pin")
                }
            } else if out.stdout.count < pin.bytes || sum != pin.sha256 {
                problems.append("## \(version) no longer starts with its pin")
            }
        }
        return problems
    }

    @Test func everyShippedEntryKeepsItsTextByteForByte() throws {
        let problems = try Self.pinProblems(current: Version.current, pins: Self.shippedNotes)
        #expect(problems.isEmpty, "\(problems): see Cut a release in docs/RELEASING.md")
    }

    // Fixture entries, so the rule's tests pin text of their own and never the real file's.
    static let entry110 = "## 1.1.0\n\n- Fix one.\n- Fix two.\n"
    static let entry100 = "## 1.0.0\n\n- First.\n"

    static func log(_ entries: String...) -> String {
        "# Changelog\n\n" + entries.joined(separator: "\n")
    }

    static func pin(_ version: String, in changelog: String) throws -> Pin {
        let out = try notes(version, changelog: changelog)
        #expect(out.status == 0)
        let sum = try sha256(out.stdout)
        return Pin(bytes: out.stdout.count, sha256: sum)
    }

    static func shippedPins() throws -> [String: Pin] {
        let shipped = log(entry110, entry100)
        return try ["1.0.0": pin("1.0.0", in: shipped), "1.1.0": pin("1.1.0", in: shipped)]
    }

    @Test func theNewestEntryTakesNewLinesWhileTheVersionIsItsOwn() throws {
        let grown = Self.log(Self.entry110 + "- Fix three.\n", Self.entry100)
        let pins = try Self.shippedPins()
        #expect(try Self.pinProblems(grown, current: "1.1.0", pins: pins) == [])
    }

    @Test func theNewestEntryKeepsItsShippedTextWhileItGrows() throws {
        let pins = try Self.shippedPins()
        var other = pins
        other["1.1.0"] = pins["1.0.0"]
        let cases: [(String, [String: Pin])] = [
            (Self.log("## 1.1.0\n\n- Fix 1.\n- Fix two.\n- Fix three.\n", Self.entry100), pins),
            (Self.log("## 1.1.0\n\n- Fix one.\n- Fix three.\n- Fix two.\n", Self.entry100), pins),
            (Self.log("## 1.1.0\n\n- Fix one.\n", Self.entry100), pins),
            (Self.log(Self.entry110, Self.entry100), other),
        ]
        for (changelog, given) in cases {
            let problems = try Self.pinProblems(changelog, current: "1.1.0", pins: given)
            #expect(problems == ["## 1.1.0 no longer starts with its pin"], "\(changelog)")
        }
    }

    @Test func aLineLeftInAShippedEntryFailsOnceTheVersionIsPastIt() throws {
        let pins = try Self.shippedPins()
        let left = Self.log(
            "## 1.2.0\n\n- Fix four.\n", Self.entry110 + "- Fix three.\n", Self.entry100)
        #expect(
            try Self.pinProblems(left, current: "1.2.0", pins: pins) == [
                "## 1.1.0 differs from its pin"
            ])
        let moved = Self.log(
            "## 1.2.0\n\n- Fix three.\n- Fix four.\n", Self.entry110, Self.entry100)
        #expect(try Self.pinProblems(moved, current: "1.2.0", pins: pins) == [])
    }

    @Test func everyOtherBreakOfThePinRuleFails() throws {
        let pins = try Self.shippedPins()
        let shipped = Self.log(Self.entry110, Self.entry100)
        let moved = Self.log("## 1.2.0\n\n- Fix three.\n", Self.entry110, Self.entry100)
        let pin110 = pins["1.1.0"] ?? Pin(bytes: 0, sha256: "")
        func with(_ version: String, _ pin: Pin?) -> [String: Pin] {
            var changed = pins
            changed[version] = pin
            return changed
        }
        let entry190 = "## 1.9.0\n\n- Nine.\n"
        let entry1100 = "## 1.10.0\n\n- Ten.\n"
        let pin190 = try Self.pin("1.9.0", in: Self.log(entry190))
        let cases: [(String, String, [String: Pin], [String])] = [
            (
                Self.log(Self.entry110, Self.entry100 + "- Late.\n"), "1.1.0", pins,
                ["## 1.0.0 differs from its pin"]
            ),
            (moved, "1.2.0", with("1.1.0", nil), ["## 1.1.0 shipped and has no pin"]),
            (shipped, "1.1.0", with("1.2.0", pin110), ["the pin 1.2.0 is past 1.1.0"]),
            (
                shipped, "1.1.0",
                with("1.1.0", Pin(bytes: pin110.bytes, sha256: pin110.sha256 + "  -")),
                ["the pin of 1.1.0 is not a SHA-256"]
            ),
            (
                shipped, "1.1.0",
                with("1.1.0", Pin(bytes: pin110.bytes, sha256: String(pin110.sha256.dropLast()))),
                ["the pin of 1.1.0 is not a SHA-256"]
            ),
            (
                shipped, "1.1.0",
                with("1.1.0", Pin(bytes: pin110.bytes, sha256: pin110.sha256.uppercased())),
                ["the pin of 1.1.0 is not a SHA-256"]
            ),
            (
                shipped, "1.1.0", with("1.1.0", Pin(bytes: pin110.bytes, sha256: Self.emptySHA256)),
                ["the pin of 1.1.0 holds no notes"]
            ),
            (
                shipped, "1.1.0", with("1.1.0", Pin(bytes: 0, sha256: pin110.sha256)),
                ["the pin of 1.1.0 holds no notes"]
            ),
            (shipped, "1.1.0", with("v1.0.0", pins["1.0.0"]), ["the pin v1.0.0 is not a version"]),
            (Self.log(Self.entry110), "1.1.0", pins, ["## 1.0.0 is gone"]),
            (
                Self.log(Self.entry110, Self.entry100, "## 1.0.0\n\n- Late.\n"), "1.1.0", pins,
                ["## 1.0.0 is there twice", "## 1.0.0 differs from its pin"]
            ),
            (
                Self.log("## Next\n\n- Fix three.\n", Self.entry110, Self.entry100), "1.1.0", pins,
                ["## Next is not a version"]
            ),
            (
                Self.log("## 1.1.0.x\n\n- Fix three.\n", Self.entry110, Self.entry100), "1.1.0",
                pins, ["## 1.1.0.x is not a version"]
            ),
            (
                Self.log("## +1.1.0\n\n- Fix three.\n", Self.entry110, Self.entry100), "1.1.0",
                pins, ["## +1.1.0 is not a version"]
            ),
            (
                Self.log("## 1..1.0\n\n- Fix three.\n", Self.entry110, Self.entry100), "1.1.0",
                pins, ["## 1..1.0 is not a version"]
            ),
            (shipped, "1.1", pins, ["1.1 is not a version"]),
            (Self.log(entry1100, entry190), "1.10.0", [:], ["## 1.9.0 shipped and has no pin"]),
            (
                Self.log(entry1100, entry190 + "- Late.\n"), "1.10.0", ["1.9.0": pin190],
                ["## 1.9.0 differs from its pin"]
            ),
            (Self.log(entry190), "1.9.0", ["1.10.0": pin190], ["the pin 1.10.0 is past 1.9.0"]),
        ]
        for (changelog, current, given, want) in cases {
            let problems = try Self.pinProblems(changelog, current: current, pins: given)
            #expect(problems == want, "\(want)")
        }
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

    // MARK: The release guide

    static func releasingGuide() throws -> String {
        try String(
            contentsOf: Support.root.appendingPathComponent("docs/RELEASING.md"), encoding: .utf8)
    }

    /// What the packaging script's closing lines print for the folder `out`, run in bash on a
    /// SHA256SUMS whose checksums are `<SHA-256>`, with the temporary folder named as `out`.
    static func printedLines(out: String, version: String, baseURL: String, dryRun: Bool)
        throws -> [String]
    {
        let lines = try packagingText()
        let first = try #require(
            lines.firstIndex { $0.hasPrefix("echo \"package-release: $VERSION\"") })
        let dir = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "<SHA-256>  agent-balancer-\(version)-arm64.tar.gz\n<SHA-256>  AgentBalancerBar.zip\n"
            .write(to: dir.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
        let harness =
            [
                #"OUT="$1" VERSION="$2" BASE_URL="$3" DRY="$4" SHA="<SHA-256>""#,
                #"CLI_ARCHIVE="agent-balancer-$VERSION-arm64.tar.gz" APP_ZIP="AgentBalancerBar.zip""#,
            ] + lines[first...]
        let run = try Support.run(
            URL(fileURLWithPath: "/bin/bash"),
            [
                "-c", harness.joined(separator: "\n"), "print", dir.path, version,
                baseURL.replacingOccurrences(of: out, with: dir.path), dryRun ? "1" : "0",
            ], env: ["PATH": "/usr/bin:/bin"])
        #expect(run.status == 0, "\(String(decoding: run.stderr, as: UTF8.self))")
        return String(decoding: run.stdout, as: UTF8.self)
            .replacingOccurrences(of: dir.path, with: out).split(separator: "\n").map(String.init)
    }

    /// The lines of the fenced block of `section` in docs/RELEASING.md whose first line is
    /// `first`, with the block's indent taken off.
    static func guideBlock(_ section: String, startingWith first: String) throws -> [String] {
        let text = try ReadmeTests.section(section, of: releasingGuide())
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try #require(
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == first }, "\(section)")
        let indent = lines[start].prefix { $0 == " " }.count
        return lines[start...].prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { String($0.dropFirst(indent)) }
    }

    /// The install smoke shows what the dry run prints for its folder, the Update the tap example
    /// what the Package step of a release run prints: full paths, then the checksum lines.
    @Test func theReleaseGuideShowsWhatThePackagingScriptPrints() throws {
        let home = "/Users/example/release"
        let smoke = try Self.guideBlock("Install smoke", startingWith: "package-release: 1.0.0")
        let dryRun = try Self.printedLines(
            out: home, version: "1.0.0", baseURL: "file://\(home)", dryRun: true)
        #expect(smoke == dryRun, "\(smoke)\n\(dryRun)")
        let checkout = "/Users/runner/work/agent-balancer/agent-balancer/build/release"
        let tap = try Self.guideBlock("Update the tap", startingWith: "package-release: 1.0.0")
        let run = try Self.printedLines(
            out: checkout, version: "1.0.0",
            baseURL: "https://github.com/<owner>/agent-balancer/releases/download/v1.0.0",
            dryRun: false)
        #expect(tap == run, "\(tap)\n\(run)")
    }

    /// The steps of the install smoke after the dry run name each file they use by its path.
    @Test func theInstallSmokeNamesEachFileByItsPath() throws {
        let smoke = ReadmeTests.flat(
            try ReadmeTests.section("Install smoke", of: Self.releasingGuide()))
        let order = [
            "scripts/package-release.sh --dry-run --out ~/release",
            "edit the `url` line of `~/release/agent-balancer.rb`",
            "`~/release/agent-balancer-<version>-arm64.tar.gz`", "`~/release/SHA256SUMS`",
            "cp ~/release/agent-balancer.rb", "Mark `~/release/AgentBalancerBar.zip` as downloaded",
        ]
        let miss = ReadmeTests.outOfOrder(order, in: smoke)
        #expect(miss == nil, "\(miss ?? "")")
    }

    /// A release run stops on a tag that already names another commit, and the guide says so.
    @Test func theGuideSaysTheRunStopsOnATagAtAnotherCommit() throws {
        let cut = ReadmeTests.flat(
            try ReadmeTests.section("Cut a release", of: Self.releasingGuide()))
        #expect(
            cut.contains(
                "the run stops before it packages anything, and again just before it publishes, when `v<version>` already exists on origin at another commit; its error names the tag."
            ))
    }

    /// The make-public steps name no commit count, set the `main` ruleset Active, and give the
    /// organization path for restricting tag creation: an app the organization owns, its key in
    /// an environment only the release job reads, the workflow changed first, and the rulesets
    /// checked again after a move.
    @Test func theMakePublicStepsGiveTheOrganizationPathAndNoCommitCount() throws {
        let steps = ReadmeTests.flat(
            try ReadmeTests.section("Make the repository public", of: Self.releasingGuide()))
        #expect(steps.firstMatch(of: /[0-9]+ commits/) == nil, "\(steps)")
        let order = [
            "`git log --merges origin/main` prints nothing", "6. Add a ruleset on `main`",
            "Set its enforcement status to Active. The form starts at Disabled, and a disabled ruleset restricts nothing.",
            "7. Check that a tag ruleset",
            "a GitHub App that the organization owns, installed on this repository only, with write access to contents only.",
            "GitHub installs a private app only on the account that owns it",
            "Keep the app's private key where only the release job, run from `main` with the maintainer's approval, can read it: a secret of a deployment environment that the release job names, whose only deployment branch is `main` and whose required reviewer is the maintainer.",
            "Change the release workflow before you add the second ruleset",
            "Added first and set to Active, the Restrict creations rule blocks the release workflow at its Publish step.",
            "After a move, check the first ruleset again",
            "does not list rulesets among what moves with it", "8. Protect the tap repository",
        ]
        let miss = ReadmeTests.outOfOrder(order, in: steps)
        #expect(miss == nil, "\(miss ?? "")")
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

    /// One change to a copy of the files, and the text that the check's error must name: what the
    /// change took out of a line the check requires, or what it put in that the check refuses.
    struct Drift: Sendable, CustomTestStringConvertible {
        let file: String
        let from: String
        let to: String
        let names: String
        var testDescription: String { "\(file): \(names)" }
    }

    static func drifts() -> [Drift] {
        let readme = "README.md"
        let guide = "docs/RELEASING.md"
        let workflow = ".github/workflows/release.yml"
        let ci = ".github/workflows/ci.yml"
        let install = "brew install jakemismas/tap/agent-balancer"
        let trust = "brew trust --formula jakemismas/tap/agent-balancer"
        let attest = "AgentBalancerBar.zip --repo jakemismas/agent-balancer"
        let create = "gh release create \"v$VERSION\""
        let publish = "      - name: Publish\n"
        let pushStep =
            "      - name: Push the tag\n"
            + "        run: git tag \"v$VERSION\" \"$SHA\" && git push origin \"v$VERSION\"\n"
        let notes = "          scripts/release-notes.sh \"$VERSION\" >/dev/null\n"
        let lsRemote =
            "          git ls-remote --exit-code origin \"refs/tags/v$VERSION\" >/dev/null\n"
        let revParse = "          git rev-parse --verify \"v$VERSION\"\n"
        let reuse = "          [ -n \"$tag_commit\" ] || exit 1\n"
        let inputsCheck =
            "          # gh release create keeps a tag that already exists, whatever commit it"
            + " names.\n          if ! tag_refs="
        let publishCheck =
            "          # A tag made at another commit while the run built stops it here, before it"
            + " publishes.\n          if ! tag_refs="
        let tagLine = "the tag check line: if ! tag_refs="
        let pinned = "checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
        let read = "permissions:\n  contents: read"
        let write = "permissions:\n  contents: write"
        func drift(_ file: String, _ from: String, _ to: String, _ names: String) -> Drift {
            Drift(file: file, from: from, to: to, names: names)
        }
        return [
            drift(
                readme, "AgentBalancerBar.zip --repo", "AgentBalancerBar.zip --rep0",
                "AgentBalancerBar.zip --repo"),
            drift(readme, install, "brew install jakemismas/tap/other", install),
            drift(readme, install, "brew install someone/tap/agent-balancer", install),
            drift(readme, attest, "AgentBalancerBar.zip --repo someone/agent-balancer", attest),
            drift(readme, "`AgentBalancerBar.app`", "`Other.app`", "`AgentBalancerBar.app`"),
            drift(readme, "   brew tap jakemismas/tap\n", "", "brew tap jakemismas/tap"),
            drift(readme, trust, "brew trust jakemismas/tap", trust),
            drift(
                workflow, "build/release/AgentBalancerBar.zip", "build/x.zip",
                "build/release/AgentBalancerBar.zip"),
            drift(
                workflow, "actions/attest-build-provenance@", "actions/other@",
                "actions/attest-build-provenance@"),
            drift(guide, "SHA256SUMS", "SUMS", "SHA256SUMS"),
            drift(guide, "gh release create", "gh release new", "gh release create"),
            drift(workflow, create, "gh release upload \"v$VERSION\"", create),
            drift(workflow, create, "gh release create \"$VERSION\"", create),
            drift(workflow, "--target \"$SHA\"", "--verify-tag --target \"$SHA\"", "--verify-tag"),
            drift(workflow, publish, publish + "        if: false\n", "if: false"),
            drift(workflow, publish, pushStep + publish, "git push"),
            drift(workflow, notes, notes + lsRemote, "ls-remote"),
            drift(workflow, notes, notes + revParse, "v$VERSION"),
            drift(workflow, notes, notes + reuse, "tag_commit"),
            drift(
                workflow, "[ \"$tag_commit\" != \"$SHA\" ]", "[ \"$tag_commit\" = \"$SHA\" ]",
                "[ \"$tag_commit\" != \"$SHA\" ]"),
            drift(workflow, inputsCheck, inputsCheck + "x", "lacks " + tagLine),
            drift(
                workflow, publishCheck, publishCheck + "x",
                "lacks, before gh release create, " + tagLine),
            drift(
                workflow, "if: github.ref == 'refs/heads/main'", "if: true",
                "if: github.ref == 'refs/heads/main'"),
            drift(
                workflow, "git merge-base --is-ancestor", "git log",
                "git merge-base --is-ancestor"),
            drift(workflow, read, write, "permissions: contents: read"),
            drift(
                workflow, "      contents: write\n",
                "      contents: write\n      x: ${{ secrets.TAP_TOKEN }}\n", "TAP_TOKEN"),
            drift(workflow, pinned, "checkout@v4", "actions/checkout@v4"),
            drift(ci, pinned, "checkout@v4", "actions/checkout@v4"),
            drift(ci, read, write, "contents: write"),
            drift(
                "packaging/agent-balancer.rb", "class AgentBalancer < Formula",
                "class Other < Formula", "class AgentBalancer < Formula"),
        ]
    }

    @Test(arguments: drifts())
    func aDriftedFileFails(drift: Drift) throws {
        let fm = FileManager.default
        let root = try Support.makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try Self.copy(to: root)
        let url = root.appendingPathComponent(drift.file)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(drift.from))
        try text.replacingOccurrences(of: drift.from, with: drift.to)
            .write(to: url, atomically: true, encoding: .utf8)
        let out = try Self.runCheck(in: root)
        let printed = String(decoding: out.stderr, as: UTF8.self)
        #expect(out.status == 1, "\(printed)")
        #expect(printed.contains("FAIL release: ") && printed.contains(drift.names), "\(printed)")
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

import Core
import Foundation
import Testing

/// The release version rules, the release notes, the output folder guard and the check that the
/// README and the release page agree with the packaging.
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
        ("README.md", "brew install <user>/tap/agent-balancer", "brew install <user>/tap/other"),
        ("README.md", "`AgentBalancerBar.app`", "`Other.app`"),
        (".github/workflows/release.yml", "build/release/AgentBalancerBar.zip", "build/x.zip"),
        (".github/workflows/release.yml", "actions/attest-build-provenance@", "actions/other@"),
        ("docs/RELEASING.md", "SHA256SUMS", "SUMS"),
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
}

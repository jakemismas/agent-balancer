import Foundation
import Testing

/// Plants one violation per rule in a temporary tree and runs the safety script against it.
/// Every planted string that a rule scans this file for is assembled here at runtime from halves.
@Suite struct SafetyScriptTests {
    struct Plant: Sendable {
        let rule: String
        let path: String
        let body: String
    }

    static let script = Support.root.appendingPathComponent("scripts/check-safety.sh")

    static func plants() -> [Plant] {
        let cl = "Clau" + "de"
        let verb = "gener" + "ated"
        return [
            Plant(rule: "keychain", path: "Sources/Core/A/A.swift", body: "import " + "Security\n"),
            Plant(
                rule: "keychain", path: "Sources/Core/A/A.swift",
                body: "let k = " + "Key" + "chain()\n"),
            Plant(
                rule: "network", path: "Sources/Core/A/A.swift",
                body: "let s = " + "URL" + "Session.shared\n"),
            Plant(
                rule: "network", path: "Sources/Core/A/A.swift", body: "import " + "Net" + "work\n"),
            Plant(
                rule: "http", path: "Sources/Core/A/A.swift",
                body: "let u = \"ht" + "tps://other.test/x\"\n"),
            Plant(
                rule: "http", path: "Sources/AgentBalancerBar/UsagePage.swift",
                body: "let a = \"ht" + "tps://claude.ai/x\"\nlet b = \"ht" + "tps://claude.ai/y\"\n"
            ),
            Plant(
                rule: "credfile", path: "Sources/Core/A/A.swift",
                body: "let n = \".creden" + "tials.json\"\n"),
            Plant(
                rule: "credfile", path: "Sources/Core/A/A.swift",
                body: "let n = \".clau" + "de.json\"\n"),
            Plant(
                rule: "process", path: "Sources/Core/A/A.swift", body: "let p = Pro" + "cess()\n"),
            Plant(
                rule: "process", path: "Sources/Core/A/A.swift",
                body: "let p = pop" + "en(\"x\", \"r\")\n"),
            Plant(
                rule: "process", path: "Sources/Core/A/A.swift", body: "let p = posix" + "_spawn\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift",
                body: "let d = try Data(contents" + "Of: u)\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift",
                body: "let h = File" + "Handle.standardInput\n"),
            Plant(
                rule: "envread", path: "Sources/Core/A/A.swift",
                body: "let e = Process" + "Info.processInfo\n"),
            Plant(
                rule: "secstr", path: "Sources/Core/A/A.swift", body: "let c = \"cu" + "rl http\"\n"
            ),
            Plant(
                rule: "secstr", path: "Sources/Core/A/A.swift",
                body: "let c = \"secu" + "rity find\"\n"),
            Plant(rule: "email", path: "docs/x.md", body: "write to pat@" + "contoso" + ".test\n"),
            Plant(rule: "email", path: "Tests/x.txt", body: "pat@" + "mail." + "contoso.test\n"),
            Plant(
                rule: "orgid", path: "docs/x.md",
                body: "org " + "123e4567" + "-e89b-" + "12d3-a456-" + "426614174000\n"),
            Plant(
                rule: "attribution", path: "docs/x.md",
                body: "Text " + verb + " by " + cl + " Code.\n"),
            // The Markdown files at the top of the repository are read as well.
            Plant(rule: "email", path: "README.md", body: "write to pat@" + "contoso" + ".test\n"),
            Plant(
                rule: "email", path: "CONTRIBUTING.md",
                body: "write to pat@" + "contoso" + ".test\n"),
            Plant(
                rule: "email", path: "SECURITY.md", body: "write to pat@" + "contoso" + ".test\n"),
            Plant(
                rule: "orgid", path: "CHANGELOG.md",
                body: "org " + "123e4567" + "-e89b-" + "12d3-a456-" + "426614174000\n"),
            Plant(
                rule: "attribution", path: "CONTRIBUTING.md",
                body: "Text " + verb + " by " + cl + " Code.\n"),
            Plant(
                rule: "attribution", path: "CODE_OF_CONDUCT.md",
                body: "Text " + verb + " by " + cl + " Code.\n"),
            Plant(
                rule: "tokenstring", path: "Sources/Core/A/A.swift",
                body: "let n = \"CLAUDE_CODE" + "_OAUTH_TOKEN\"\n"),
            Plant(
                rule: "tokenstring", path: "Sources/Core/A/A.swift",
                body: "let n = \"tok" + "ens/x.json\"\n"),
            Plant(
                rule: "tokenstring", path: "Sources/Core/A/A.swift",
                body: "let n = \"lau" + "nch/x/y.json\"\n"),
            Plant(
                rule: "delete", path: "Sources/Core/A/A.swift",
                body: "try fm.remove" + "Item(at: u)\n"),
            Plant(rule: "delete", path: "Sources/Core/A/A.swift", body: "unlink" + "(path)\n"),
            Plant(rule: "process", path: "Sources/Core/A/A.swift", body: "let p = NS" + "Task()\n"),
            Plant(
                rule: "process", path: "Sources/Core/A/A.swift",
                body: "let p = sys" + "tem(\"x\")\n"),
            Plant(
                rule: "process", path: "Sources/Core/A/A.swift", body: "let p = exe" + "cv(a, b)\n"),
            Plant(
                rule: "process", path: "Sources/Core/A/A.swift", body: "let p = dl" + "open(a, 1)\n"
            ),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift",
                body: "let f = fo" + "pen(a, \"r\")\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift", body: "let f = op" + "en(a, 0)\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift", body: "let d = conte" + "ntsOf\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift",
                body: "let d = fm.conte" + "nts(atPath: p)\n"),
            Plant(
                rule: "delete", path: "Sources/Core/A/A.swift",
                body: "try fm.trash" + "Item(at: u, resultingItemURL: nil)\n"),
            Plant(
                rule: "delete", path: "Sources/Core/A/A.swift", body: "unlink" + "at(fd, p, 0)\n"),
            Plant(rule: "delete", path: "Sources/Core/A/A.swift", body: "rm" + "dir(p)\n"),
            Plant(
                rule: "delete", path: "Sources/Core/A/A.swift",
                body: "try fm.replace" + "Item(at: a, withItemAt: b)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "try s.wri" + "te(to: u, atomically: true, encoding: .utf8)\n"),
            Plant(rule: "write", path: "Sources/Core/A/A.swift", body: "try d.wri" + "te(to: u)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "fm.create" + "File(atPath: p, contents: nil)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "try fm.create" + "Directory(at: u, withIntermediateDirectories: true)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "try fm.move" + "Item(at: a, to: b)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "try fm.copy" + "Item(at: a, to: b)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "try fm.createSym" + "bolicLink(at: a, withDestinationURL: b)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "try fm.set" + "Attributes([:], ofItemAtPath: p)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "let h = try File" + "Handle(forWri" + "tingTo: u)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "let f = fo" + "pen(p, \"w\")\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "let o = Output" + "Stream(url: u, append: true)\n"),
            Plant(rule: "write", path: "Sources/Core/A/A.swift", body: "mk" + "dir(p, 0o700)\n"),
            Plant(rule: "write", path: "Sources/Core/A/A.swift", body: "ch" + "mod(p, 0o600)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "let fd = op" + "en(p, O_WR" + "ONLY)\n"),
            Plant(rule: "write", path: "Sources/Core/A/A.swift", body: "ren" + "ame(a, b)\n"),
            Plant(rule: "write", path: "Sources/Core/A/A.swift", body: "sym" + "link(a, b)\n"),
            Plant(
                rule: "tokenstring", path: "Sources/Core/Launch/L.swift",
                body: "let t = \"tok" + "ens/\"\n"),
            Plant(
                rule: "tokenstring", path: "Sources/Core/Tokens/T.swift",
                body: "let n = \"lau" + "nch/\"\n"),
            Plant(
                rule: "tokenstring", path: "Tests/CoreTests/T.swift",
                body: "let n = \"tok" + "ens/x.json\"\n"),
            Plant(
                rule: "tokenstring", path: "Tests/CoreTests/T.swift",
                body: "let n = \"CLAUDE_CODE" + "_OAUTH_TOKEN\"\n"),
            Plant(
                rule: "delete", path: "Sources/Core/Paths/Other.swift", body: "unlink" + "(path)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "try d.wri" + "te(to: u)\n"),
            Plant(rule: "email", path: "skill/x.md", body: "pat@" + "contoso" + ".test\n"),
            Plant(
                rule: "orgid", path: "skill/x.md",
                body: "123e4567" + "-e89b-" + "12d3-a456-" + "426614174000\n"),
            Plant(
                rule: "orgid", path: "Sources/Core/A/A.swift",
                body: "let i = \"123e4567" + "-e89b-" + "12d3-a456-" + "426614174000\"\n"),
            Plant(
                rule: "orgid", path: "Tests/x.txt",
                body: "123e4567" + "-e89b-" + "12d3-a456-" + "426614174000\n"),
            Plant(
                rule: "http", path: "Sources/AgentBalancerBar/UsagePage.swift",
                body: "let a = \"ht" + "tps://other.test/usage\"\n"),
            Plant(
                rule: "http", path: "Sources/AgentBalancerBar/Other.swift",
                body: "let a = \"ht" + "tp://claude.ai/x\"\n"),
            Plant(
                rule: "secstr", path: "Sources/Core/A/A.swift",
                body: "let c = \"run \\\\(x) cu" + "rl \\\\(y)\"\n"),
            Plant(
                rule: "secstr", path: "Sources/Core/A/A.swift",
                body: "let c = [\"a\", \"secu" + "rity add-generic-password\", \"b\"]\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "fch" + "mod(fd, 0o600)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "ftru" + "ncate(fd, 0)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "fp" + "uts(s, fp)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "pwr" + "ite(fd, b, n, 0)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "copy" + "file(a, b, nil, 0)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "clon" + "efile(a, b, 0)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "fcop" + "yfile(a, b, nil, 0)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "dpr" + "intf(fd, f)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "wr" + "ite(fd, b, n)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "exchan" + "gedata(a, b, 0)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "uti" + "mes(p, nil)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "fch" + "own(fd, 0, 0)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "fpr" + "intf(fp, f)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/Other.swift",
                body: "wri" + "tev(fd, v, 1)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "let d = User" + "Defaults.standard\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "let d = NSUbiquitous" + "KeyValueStore.default\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "let f = fre" + "open(p, \"w\", f)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "let f = open" + "at(fd, p, 0)\n"),
            Plant(
                rule: "write", path: "Sources/Core/A/A.swift",
                body: "try u.setResource" + "Values(v)\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift",
                body: "let f = open" + "at(fd, p, 0)\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift",
                body: "let f = fre" + "open(p, \"r\", f)\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift",
                body: "let d = User" + "Defaults.standard\n"),
            Plant(
                rule: "fileread", path: "Sources/Core/A/A.swift",
                body: "let d = NSUbiquitous" + "KeyValueStore.default\n"),
            Plant(
                rule: "delete", path: "Sources/Core/A/A.swift",
                body: "d.remove" + "Object(forKey: k)\n"),
            Plant(
                rule: "delete", path: "Sources/Core/A/A.swift",
                body: "let d = User" + "Defaults.standard\n"),
            Plant(rule: "delete", path: "Sources/Core/A/A.swift", body: "re" + "move(p)\n"),
            Plant(
                rule: "process", path: "Sources/Core/X/a.c", body: "int r = sys" + "tem(\"x\");\n"),
            Plant(
                rule: "process", path: "Sources/Core/X/a.m", body: "int r = sys" + "tem(\"x\");\n"),
            Plant(
                rule: "write", path: "Sources/Core/X/a.cpp", body: "fp" + "uts(s, fp);\n"),
            Plant(
                rule: "process", path: "Plugins/P/P.swift", body: "let p = Pro" + "cess()\n"),
            Plant(
                rule: "write", path: "Plugins/P/P.swift", body: "try d.wri" + "te(to: u)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/NoFollowWriter.swift/A.swift",
                body: "try d.wri" + "te(to: u)\n"),
            Plant(
                rule: "delete", path: "Sources/Core/Paths/NoFollowWriter.swift/A.swift",
                body: "unlink" + "(path)\n"),
            Plant(
                rule: "write", path: "Sources/Core/Paths/NoFollowWriter.swift.c",
                body: "try d.wri" + "te(to: u)\n"),
            Plant(rule: "layout", path: "Sources/Core/X/a.c", body: "int a;\n"),
            Plant(rule: "layout", path: "Sources/Core/X/a.h", body: "int a;\n"),
            Plant(rule: "layout", path: "Plugins/P/P.swift", body: "let a = 1\n"),
            Plant(rule: "layout", path: "Tools/T.swift", body: "let a = 1\n"),
            Plant(rule: "layout", path: "Sources/Other/O.swift", body: "let a = 1\n"),
            Plant(rule: "layout", path: "Tests/OtherTests/O.swift", body: "let a = 1\n"),
            Plant(rule: "layout", path: "Tests/CoreTests/a.m", body: "int a;\n"),
            Plant(rule: "layout", path: "Tests/Fixtures/F.swift", body: "let a = 1\n"),
            Plant(
                rule: "manifest", path: "Package.swift",
                body: "import PackageDescription\nlet p = Package(targets: [.plu"
                    + "gin(name: \"P\")])\n"),
            Plant(
                rule: "manifest", path: "Package.swift",
                body: "import PackageDescription\nlet p = Package(targets: [.binary"
                    + "Target(name: \"B\")])\n"),
            Plant(
                rule: "manifest", path: "Package.swift",
                body: "import PackageDescription\nimport Found" + "ation\n"),
            Plant(
                rule: "manifest", path: "Package.swift",
                body:
                    "import PackageDescription\nlet d = [.package(url: \"https://github.com/x/y\", from: \"1.0.0\")]\n"
            ),
            Plant(
                rule: "manifest", path: "Package.swift",
                body: "import PackageDescription\nlet t = [.target(name: \"Core\", pa"
                    + "th: \"Elsewhere\")]\n"),
            Plant(
                rule: "process", path: "Package.swift",
                body: "import PackageDescription\nlet p = Pro" + "cess()\n"),
            Plant(rule: "xctest", path: "Tests/CoreTests/T.swift", body: "import XC" + "Test\n"),
            Plant(
                rule: "settingsread", path: "Sources/Core/Picker/RunService.swift",
                body: "let f = try hooks.read" + "Settings()\n"),
            Plant(
                rule: "settingsread", path: "Sources/agent-balancer/Commands/Run.swift",
                body: "let f = settings" + "State()\n"),
            Plant(
                rule: "settingsread", path: "Sources/Core/A/A.swift",
                body: "let n = \"settings" + ".json\"\n"),
            Plant(
                rule: "settingsread", path: "Sources/Core/Picker/RunService.swift",
                body: "let u = context.default" + "ClaudeFolder\n"),
        ] + pipePlants()
    }

    /// A script that sets pipefail with `set` and runs `lines`.
    static func script(_ lines: [String], set: String = "set -euo pipefail") -> String {
        (["#!/usr/bin/env bash", set] + lines).joined(separator: "\n") + "\n"
    }

    /// Pipes into a reader that can stop before it reads all its input: on one line, across a
    /// line continuation, inside `$( )`, `if`, `while`, `||` and `&&`, and each reader the rule
    /// knows.
    static func pipePlants() -> [Plant] {
        let shapes: [[String]] = [
            [#"printf '%s\n' "$a" | grep -q x"#],
            [#"printf '%s\n' "$a" | grep -m 1 x"#],
            [#"v="$(sed -n 1p f | head -n 1)""#],
            [#"if otool -L f | tail -n +2 \"#, "  | grep -qE x; then exit 1; fi"],
            [#"printf x | \"#, "  head -n 1"],
            ["printf x |", "  grep -m1 x"],
            ["x=$(printf x |", "  # the first line", "  head -n 1)"],
            [#"[ -n "$a" ] && printf x | grep -l x || exit 1"#],
            ["while printf x | grep -q x; do break; done"],
            ["printf x | LC_ALL=C /usr/bin/grep --quiet x"],
            ["printf x | sed -n '/x/{p;q;}'"],
            ["printf x | awk '{ print; exit }'"],
            ["printf x | cmp -s - f"],
            ["printf x | read -r first"],
            ["printf x | while read -r l; do", #"  [ -n "$l" ] && break"#, "done"],
        ]
        return shapes.map { Plant(rule: "pipe", path: "scripts/x.sh", body: script($0)) } + [
            Plant(
                rule: "pipe", path: "scripts/x.sh",
                body: script(["printf x | head -1"], set: "set -o pipefail"))
        ]
    }

    static func runScript(root: URL) throws -> Support.Output {
        try Support.run(
            URL(fileURLWithPath: "/bin/bash"), [script.path, root.path],
            env: ["PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path])
    }

    static func write(_ plant: Plant, into root: URL) throws {
        let url = root.appendingPathComponent(plant.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + plant.body).write(to: url, atomically: true, encoding: .utf8)
    }

    @Test(arguments: plants())
    func plantedViolationFails(plant: Plant) throws {
        let root = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(plant, into: root)
        let result = try Self.runScript(root: root)
        let text = String(decoding: result.stdout, as: UTF8.self)
        #expect(result.status == 1, "rule \(plant.rule) did not fail: \(text)")
        #expect(text.contains("FAIL \(plant.rule)"), "wrong rule for \(plant.rule): \(text)")
    }

    @Test func cleanTreePasses() throws {
        let root = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(
            Plant(rule: "none", path: "Sources/Core/A/A.swift", body: "let x = 1\n"), into: root)
        try Self.write(
            Plant(rule: "none", path: "docs/x.md", body: "mail test@example.com\n"), into: root)
        let result = try Self.runScript(root: root)
        #expect(result.status == 0, "\(String(decoding: result.stdout, as: UTF8.self))")
    }

    @Test func exemptModulesPass() throws {
        let root = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let pieces = [
            (
                "Sources/Core/Paths/NoFollowWriter.swift",
                "try d.wri" + "te(to: u)\nunlink" + "(p)\n"
            ),
            ("Sources/Core/Runner/R.swift", "let p = Pro" + "cess()\n"),
            ("Sources/Core/Env/E.swift", "let e = Process" + "Info.processInfo\n"),
            (
                "Sources/Core/Paths/P.swift",
                "let d = try Data(contents" + "Of: u)\n"
            ),
            (
                "Sources/Core/Tokens/T.swift",
                "let n = \"CLAUDE_CODE" + "_OAUTH_TOKEN\"\nlet t = \"tok" + "ens/\"\n"
            ),
            ("Sources/Core/Launch/L.swift", "let n = \"lau" + "nch/\"\n"),
            (
                "Sources/Core/Links/HookRecord.swift",
                "let f = try hooks.read" + "Settings()\nlet n = \"settings" + ".json\"\n"
            ),
            (
                "Sources/agent-balancer/Commands/Doctor.swift",
                "let f = try hooks.read" + "Settings()\n"
            ),
            (
                "Sources/AgentBalancerBar/UsagePage.swift",
                "let u = \"ht" + "tps://claude.ai/settings/usage\"\n"
            ),
        ]
        for (path, body) in pieces {
            try Self.write(Plant(rule: "none", path: path, body: body), into: root)
        }
        let result = try Self.runScript(root: root)
        #expect(result.status == 0, "\(String(decoding: result.stdout, as: UTF8.self))")
    }

    @Test func fixturesFolderPasses() throws {
        let root = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(
            Plant(rule: "none", path: "Tests/Fixtures/bin/claude", body: "#!/bin/sh\nexit 0\n"),
            into: root)
        try Self.write(
            Plant(rule: "none", path: "Tests/Fixtures/auth/a.json", body: "{\"loggedIn\":true}\n"),
            into: root)
        let result = try Self.runScript(root: root)
        #expect(result.status == 0, "\(String(decoding: result.stdout, as: UTF8.self))")
    }

    @Test func bannedStringListFailsTheTree() throws {
        let root = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let word = "zq" + "xvw" + "plumbus"
        try Self.write(
            Plant(rule: "none", path: ".claude/sprint/banned-strings.txt", body: word + "\n\n"),
            into: root)
        try Self.write(
            Plant(rule: "none", path: "notes.txt", body: "a " + word.uppercased() + " here\n"),
            into: root)
        let result = try Self.runScript(root: root)
        #expect(result.status == 1)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("FAIL banned"))
    }

    @Test func symlinkFailsLayout() throws {
        let root = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(
            Plant(rule: "none", path: "Sources/Core/A/A.swift", body: "let x = 1\n"), into: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Sources/Core/Link.swift"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let result = try Self.runScript(root: root)
        #expect(result.status == 1)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("FAIL layout"))
    }

    @Test func aPipeIntoAnEarlyReaderNamesTheFileTheLineAndTheFix() throws {
        let root = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(
            Plant(
                rule: "none", path: "scripts/one.sh",
                body: Self.script([#"printf '%s\n' "$a" | grep -q x"#])), into: root)
        try Self.write(
            Plant(
                rule: "none", path: "scripts/two.sh",
                body: Self.script([
                    #"if otool -L f | tail -n +2 \"#, "  | grep -qE x; then exit 1; fi",
                    "v=$(printf x | head -n 1)",
                ])), into: root)
        let result = try Self.runScript(root: root)
        let text = String(decoding: result.stdout, as: UTF8.self)
        let fix =
            " under pipefail; use a here-string or a reader that reads all its input"
            + " (grep ... >/dev/null, sed -n 1p)\n"
        #expect(result.status == 1, "\(text)")
        #expect(text.contains("FAIL pipe: scripts/one.sh:3 pipes into grep -q" + fix), "\(text)")
        #expect(text.contains("FAIL pipe: scripts/two.sh:4 pipes into grep -q" + fix), "\(text)")
        #expect(text.contains("FAIL pipe: scripts/two.sh:5 pipes into head" + fix), "\(text)")
    }

    /// The fixed forms pass: a here-string, readers that read all their input, an or that is not
    /// a pipe, a pipe in a comment, in quotes or in a here-document, an exit that runs after the
    /// input ends, a loop that reads every line, and a script that does not set pipefail.
    @Test func pipesIntoReadersThatReadAllTheirInputPass() throws {
        let root = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixed: [[String]] = [
            [#"grep -qx "$want" <<<"$listing" || exit 1"#],
            [#"printf '%s\n' "$a" | grep x >/dev/null"#],
            ["v=$(sed -n 's/x/y/p' f | sed -n 1p)"],
            ["if grep -nE x f | grep -v y | grep . >/dev/null; then exit 1; fi"],
            [
                #"if otool -L f | tail -n +2 | awk '{ print $1 }' \"#,
                "  | grep -vE '^/usr/lib/' | grep . >/dev/null; then exit 1; fi",
            ],
            ["printf x || grep -q x f"],
            ["# printf x | grep -q x"],
            [#"echo 'a | head -n 1' "b | grep -q c""#],
            ["cat <<'EOF'", "x | head -n 1", "EOF"],
            ["printf x | awk '/x/ { n++ } END { exit n == 0 }'"],
            [#"printf x | while read -r l; do echo "$l"; done"#],
            [#"while read -r l; do break; done <<<"$a""#],
            ["printf x | grep -c x | tail -n +1"],
        ]
        for (n, lines) in fixed.enumerated() {
            try Self.write(
                Plant(rule: "none", path: "scripts/fixed\(n).sh", body: Self.script(lines)),
                into: root)
        }
        try Self.write(
            Plant(
                rule: "none", path: "scripts/plain.sh",
                body: Self.script(["printf x | grep -q x"], set: "set -eu")), into: root)
        let result = try Self.runScript(root: root)
        #expect(result.status == 0, "\(String(decoding: result.stdout, as: UTF8.self))")
    }

    @Test func realTreePasses() throws {
        let result = try Self.runScript(root: Support.root)
        #expect(result.status == 0, "\(String(decoding: result.stdout, as: UTF8.self))")
    }
}

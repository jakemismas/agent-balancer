import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// `doctor` names a `claude` whose real target sits in a folder that another user or group can
/// change, by its mode or its access list, with that folder and the commands that clear it, and
/// exits 1, and `run` refuses with the same text; `pick` refuses every binary the runner refuses
/// before it writes a launch file, with the runner's text, and writes no lease or `picks.log`
/// line. Neither starts the binary, and the commands they name, run as printed, clear it.
@Suite struct ClaudeTargetFolderCLITests {
    let base = ClaudeAccessListCLITests()
    let versions = ".local/share/claude/versions"
    let place = "~/.local/share/claude/versions"

    func run(_ command: String) -> String {
        "Run `\(command)` in Terminal"
            + (command.contains("chmod -N") ? " to drop every entry of its access list." : ".")
    }

    var modeText: String {
        "Refused ~/.local/bin/claude: its real target's folder `\(place)` must be owned by you or root and not writable by others."
    }

    var listText: String {
        "Refused ~/.local/bin/claude: the access list of its real target's folder `\(place)` lets another user or group change it, or cannot be read."
    }

    /// Moves the fake into `versions` and links `.local/bin/claude` to it.
    func link(_ cli: CLIHome) throws {
        let real = cli.home.appendingPathComponent(versions + "/2.1.0")
        try FileManager.default.createDirectory(
            at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: cli.fakePath, to: real)
        try FileManager.default.createSymbolicLink(at: cli.fakePath, withDestinationURL: real)
    }

    @Test func doctorAndRunNameTheRealTargetsFolderAndItsCommandAndStartNothingUntilItRuns()
        throws
    {
        let me = NSUserName()
        let cases: [(change: [String], flag: String?, said: String)] = [
            (["777"], nil, modeText + " " + run("chmod go-w \(place)")),
            (["775"], nil, modeText + " " + run("chmod go-w \(place)")),
            (["1777"], nil, modeText + " " + run("chmod go-w \(place)")),
            (
                ["777"], "uchg",
                modeText + " Run `chflags nouchg \(place)`, then `chmod go-w \(place)` in Terminal."
            ),
            (["+a", "everyone allow add_file"], nil, listText + " " + run("chmod -N \(place)")),
            (
                ["+a", "group:staff allow delete_child"], nil,
                listText + " " + run("chmod -N \(place)")
            ),
            (
                ["+a", "everyone allow add_file"], "uappnd",
                listText
                    + " Run `chflags nouappnd \(place)`, then `chmod -N \(place)` in Terminal to drop every entry of its access list."
            ),
            (
                ["+a", "user:\(me) deny readsecurity"], nil,
                "Refused ~/.local/bin/claude: its real target's folder `\(place)` cannot be checked, because you cannot read the attributes of `\(place)`. "
                    + run("chmod -N \(place)")
            ),
        ]
        for item in cases {
            let name = "\(item.change) \(item.flag ?? "")"
            let cli = try base.setUp()
            defer { base.finish(cli) }
            try link(cli)
            let before = try cli.run(["doctor"])
            #expect(before.status == 0, "\(name): \(text(before.stdout))")
            let folder = cli.home.appendingPathComponent(versions).path
            #expect(try base.runTool("/bin/chmod", item.change + [folder]) == 0, "\(name)")
            if let flag = item.flag {
                #expect(try base.runTool("/usr/bin/chflags", [flag, folder]) == 0, "\(name)")
            }
            let started = cli.fakeRecord("args.log")
            let doctor = try cli.run(["doctor"])
            #expect(doctor.status == 1, "\(name)")
            let said = text(doctor.stdout)
            #expect(said.contains("Error check_failed: \(item.said)\n"), "\(name): \(said)")
            let run = try cli.run(["run", "main"])
            #expect(run.status == 1, "\(name)")
            #expect(text(run.stderr) == "Error: \(item.said)\n", "\(name)")
            #expect(cli.fakeRecord("args.log") == started, "\(name)")
            let named = base.commands(item.said, cli)
            #expect(!named.isEmpty, "\(name)")
            for command in named {
                #expect(try base.runTool(command.tool, command.words) == 0, "\(name): \(command)")
            }
            let after = try cli.run(["doctor"])
            #expect(after.status == 0, "\(name): \(text(after.stdout))")
        }
    }

    /// A home with the fake linked into `versions` and one token account, whose token file holds
    /// a value the token check takes.
    func tokenHome() throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        try link(cli)
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: [
            Account(label: "pool-a", kind: Kind.token, role: Role.pool)
        ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        let hooks = HookRecord(context: context)
        try hooks.record(.empty)
        // A reader saves the verdict that `run` relies on.
        _ = try hooks.readSettings()
        let file = try TokenPaths.fileURL(context: context, label: "pool-a")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"a-value-the-check-takes\"}}".write(
            to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return cli
    }

    func launchFiles(_ cli: CLIHome) -> [String] {
        let folder = LaunchFiles.rootURL(context: ToolContext(home: cli.home, ambient: [:]))
            .appendingPathComponent("pool-a")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    /// Each way the runner refuses the binary: the path to change, the `chmod` operands, and the
    /// runner's text.
    var refusals: [(on: String, change: [String], said: String)] {
        let target = "~/" + versions + "/2.1.0"
        return [
            (
                versions + "/2.1.0", ["775"],
                "Refused ~/.local/bin/claude: it must be an executable owned by you or root and not writable by others."
            ),
            (
                versions + "/2.1.0", ["+a", "everyone allow write"],
                "Refused ~/.local/bin/claude: its real target's access list lets another user or group change it, or cannot be read. "
                    + run("chmod -N \(target)")
            ),
            (versions, ["777"], modeText + " " + run("chmod go-w \(place)")),
            (
                versions, ["+a", "everyone allow add_file,delete_child"],
                listText + " " + run("chmod -N \(place)")
            ),
            (
                ".local/bin", ["+a", "everyone allow add_file"],
                "Refused ~/.local/bin/claude: its folder's access list lets another user or group change it, or cannot be read. "
                    + run("chmod -N ~/.local/bin")
            ),
            (
                versions, ["+a", "user:\(NSUserName()) deny search"],
                "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `\(place)`. "
                    + run("chmod -N \(place)")
            ),
        ]
    }

    /// For each refusal, in a fresh token home: `first` writes one launch file; once the binary is
    /// refused, each of `refused` exits 1 with the runner's text and writes no launch file, lease
    /// or `picks.log` line and starts nothing; once the named commands ran, `first` writes one
    /// again.
    func expectRefusedBeforeALaunchFile(first: [String], refused: [[String]]) throws {
        for item in refusals {
            let name = "\(item.change) on \(item.on)"
            let cli = try tokenHome()
            defer { base.finish(cli) }
            // When `first` picks, it also stores a fresh reading, so later picks start no probe.
            let before = try cli.run(first)
            #expect(before.status == 0, "\(name): \(text(before.stderr))")
            let files = launchFiles(cli)
            #expect(files.count == 1, "\(name)")
            let leases = cli.read("state/leases.json")
            let picks = cli.read("state/picks.log")
            let path = cli.home.appendingPathComponent(item.on).path
            #expect(try base.runTool("/bin/chmod", item.change + [path]) == 0, "\(name)")
            let started = cli.fakeRecord("args.log")
            for arguments in refused {
                let out = try cli.run(arguments)
                #expect(out.status == 1, "\(name) \(arguments)")
                #expect(text(out.stderr) == "Error: \(item.said)\n", "\(name) \(arguments)")
                #expect(out.stdout.isEmpty, "\(name) \(arguments)")
            }
            #expect(launchFiles(cli) == files, "\(name)")
            #expect(cli.read("state/leases.json") == leases, "\(name)")
            #expect(cli.read("state/picks.log") == picks, "\(name)")
            #expect(cli.fakeRecord("args.log") == started, "\(name)")
            let named = base.commands(item.said, cli)
            if named.isEmpty {
                #expect(try base.runTool("/bin/chmod", ["755", path]) == 0, "\(name)")
            }
            for command in named {
                #expect(try base.runTool(command.tool, command.words) == 0, "\(name): \(command)")
            }
            let again = try cli.run(first)
            #expect(again.status == 0, "\(name): \(text(again.stderr))")
            #expect(launchFiles(cli).count == 2, "\(name)")
        }
    }

    @Test func pickRefusesWhatTheRunnerRefusesBeforeItWritesALaunchFile() throws {
        try expectRefusedBeforeALaunchFile(
            first: ["pick"],
            refused: [
                ["pick"], ["pick", "--json"], ["pick", "--caller", "launcher", "--json"],
                ["pick", "--dry-run", "--json"],
            ])
    }

    /// `run --print-command` starts nothing but prints a line that does; plain `run` finds the
    /// binary before it writes anything.
    @Test func runAndItsPrintedLineRefuseWhatTheRunnerRefusesBeforeALaunchFile() throws {
        try expectRefusedBeforeALaunchFile(
            first: ["run", "--print-command", "pool-a"],
            refused: [["run", "--print-command", "pool-a"], ["run", "pool-a"]])
    }

    /// A login account and a folder account: `pick` and its dry run refuse a binary the runner
    /// refuses with its whole text before any sign-in check or probe starts it, and exit 1.
    @Test func pickAndItsDryRunRefuseARefusedBinaryForEveryKindBeforeItsSignInChecks() throws {
        for kind in [Kind.login, Kind.folder] {
            let cli = try base.setUp()
            defer { base.finish(cli) }
            if kind == Kind.folder {
                let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
                var config = try #require(try store.load())
                config.accounts = [Account(label: "work", kind: Kind.folder, role: Role.pool)]
                try store.save(config)
            }
            try link(cli)
            let folder = cli.home.appendingPathComponent(versions).path
            #expect(try base.runTool("/bin/chmod", ["+a", "everyone allow add_file", folder]) == 0)
            let said = listText + " " + run("chmod -N \(place)")
            #expect(said.count > 200)
            let started = cli.fakeRecord("args.log")
            let runs = [
                ["pick"], ["pick", "--json"], ["pick", "--dry-run"],
                ["pick", "--dry-run", "--json"],
            ]
            for arguments in runs {
                let out = try cli.run(arguments)
                #expect(out.status == 1, "\(kind) \(arguments)")
                #expect(text(out.stderr) == "Error: \(said)\n", "\(kind) \(arguments)")
                #expect(out.stdout.isEmpty, "\(kind) \(arguments)")
            }
            #expect(cli.fakeRecord("args.log") == started, "\(kind)")
        }
    }

    /// A system policy, here a sandbox profile that keeps the lookup from reading the real
    /// target's attributes, is not an access list or a mode, so the refusal names no `chmod -N`.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")))
    func aSystemPolicyThatStopsTheLookupNamesNoChmod() throws {
        let cli = try base.setUp()
        defer { base.finish(cli) }
        try link(cli)
        let name = cli.home.lastPathComponent
        let profile =
            "(version 1)(allow default)(deny file-read-metadata (regex #\"/\(name)/\\.local/share/claude/versions/2\\.1\\.0$\"))"
        let out = try Support.run(
            URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile, cli.exe.path, "doctor"],
            env: ["HOME": cli.home.path, "PATH": "/usr/bin:/bin"])
        let said = text(out.stdout)
        #expect(out.status == 1, "\(said)")
        #expect(
            said.contains(
                "Error check_failed: Refused ~/.local/bin/claude: it cannot be checked, because a system policy, such as a sandbox profile, keeps you from `~/\(versions)/2.1.0`, and no chmod clears that.\n"
            ), "\(said)")
        #expect(!said.contains("chmod -N"), "\(said)")
    }

    /// With no binary of the fixed list, `pick` and `run --print-command` go on for a token
    /// account, whose line starts the `claude` your shell finds, while `run` refuses; a login
    /// account still fails its sign-in check. Without the guard the test would reach the host's
    /// own `claude`.
    @Test(.enabled(if: Support.noHostClaude))
    func pickAndThePrintedLineGoOnWhenNoBinaryOfTheListExists() throws {
        func json(_ out: Support.Output) -> [String: Any] {
            ((try? JSONSerialization.jsonObject(with: out.stdout)) as? [String: Any]) ?? [:]
        }
        do {
            let cli = try tokenHome()
            defer { base.finish(cli) }
            let first = try cli.run(["pick"])
            #expect(first.status == 0, "\(text(first.stderr))")
            #expect(launchFiles(cli).count == 1)
            try FileManager.default.removeItem(at: cli.fakePath)
            let picked = try cli.run(["pick", "--json"])
            #expect(picked.status == 0, "\(text(picked.stderr))")
            #expect(json(picked)["label"] as? String == "pool-a")
            let args = json(picked)["args"] as? [String] ?? []
            #expect(args.count == 2 && args.first == "--settings", "\(args)")
            let launcher = try cli.run(["pick", "--caller", "launcher", "--json"])
            #expect(launcher.status == 0, "\(text(launcher.stderr))")
            #expect(json(launcher)["label"] as? String == "pool-a")
            let line = try cli.run(["run", "--print-command", "pool-a"])
            #expect(line.status == 0, "\(text(line.stderr))")
            #expect(text(line.stdout).hasPrefix("claude --settings '"))
            let files = launchFiles(cli)
            #expect(files.count == 4)
            let leases = cli.read("state/leases.json")
            let picks = cli.read("state/picks.log")
            let run = try cli.run(["run", "pool-a"])
            #expect(run.status == 1)
            #expect(
                text(run.stderr)
                    == "Error: The claude program was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.\n"
            )
            #expect(run.stdout.isEmpty)
            #expect(launchFiles(cli) == files)
            #expect(cli.read("state/leases.json") == leases)
            #expect(cli.read("state/picks.log") == picks)
        }
        let cli = try base.setUp()
        defer { base.finish(cli) }
        try FileManager.default.removeItem(at: cli.fakePath)
        let pick = try cli.run(["pick", "--json"])
        #expect(pick.status == 2, "\(text(pick.stderr))")
        let line = try cli.run(["run", "--print-command", "main"])
        #expect(line.status == 1)
        #expect(text(line.stderr).contains("Check failed: The claude program was not found"))
        let launch = LaunchFiles.rootURL(context: ToolContext(home: cli.home, ambient: [:]))
        let made = (try? FileManager.default.subpathsOfDirectory(atPath: launch.path)) ?? []
        #expect(made.filter { $0.hasSuffix(".json") }.isEmpty, "\(made)")
    }
}

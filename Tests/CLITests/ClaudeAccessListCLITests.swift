import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// `doctor` names a `claude` whose real target, or `~/.local/bin` when the binary sits there, has
/// an access list that lets another user or group change it or that cannot be read, or whose
/// lookup stops, with where it stops and the commands that clear it, and exits 1; `run` refuses
/// with the same text; neither starts the binary, and the commands they name, run as printed,
/// clear the refusal.
@Suite struct ClaudeAccessListCLITests {
    func setUp() throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                expectedPlanTier: "max_20x")
        ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    func runTool(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func finish(_ cli: CLIHome) {
        _ = try? runTool("/usr/bin/chflags", ["-R", "nouchg,nouappnd", cli.home.path])
        _ = try? runTool("/bin/chmod", ["-R", "-N", cli.home.path])
        cli.cleanup()
    }

    /// The `chmod` and `chflags` commands `said` names in backquotes, in order, each with its
    /// tool's path and its words, `~` as the home folder.
    func commands(_ said: String, _ cli: CLIHome) -> [(tool: String, words: [String])] {
        said.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            .compactMap { command in
                let words = command.split(separator: " ").map { word in
                    word.hasPrefix("~/") ? cli.home.path + word.dropFirst() : String(word)
                }
                switch words.first {
                case "chmod": return ("/bin/chmod", Array(words.dropFirst()))
                case "chflags": return ("/usr/bin/chflags", Array(words.dropFirst()))
                default: return nil
                }
            }
    }

    func listText(_ whose: String, _ fix: String) -> String {
        "Refused ~/.local/bin/claude: its \(whose) access list lets another user or group change it, or cannot be read. \(fix)"
    }

    @Test func doctorAndRunNameTheListAndItsCommandAndStartNothingUntilTheCommandRuns() throws {
        let me = NSUserName()
        let versions = ".local/share/claude/versions/2.1.0"
        let typed = "~/" + versions
        func run(_ command: String) -> String { "Run `\(command)` in Terminal." }
        let lock =
            "Run `chflags nouchg ~/.local/bin/claude`, then `chmod -N ~/.local/bin/claude` in Terminal."
        let cases: [(entry: String, on: String, linked: Bool, flag: String?, said: String)] = [
            (
                "everyone allow write,append", ".local/bin/claude", false, nil,
                listText("real target's", run("chmod -N ~/.local/bin/claude"))
            ),
            (
                "group:staff allow delete", ".local/bin/claude", false, nil,
                listText("real target's", run("chmod -N ~/.local/bin/claude"))
            ),
            (
                "everyone allow write", ".local/bin/claude", false, "uchg",
                listText("real target's", lock)
            ),
            (
                "everyone allow write", versions, true, nil,
                listText("real target's", run("chmod -N \(typed)"))
            ),
            (
                "user:\(me) deny readattr", versions, true, nil,
                "Refused ~/.local/bin/claude: it cannot be checked, because you cannot read the attributes of `\(typed)`. "
                    + run("chmod -N \(typed)")
            ),
            (
                "user:\(me) deny readattr", ".local/share/claude", true, nil,
                "Refused ~/.local/bin/claude: it cannot be checked, because you cannot read the attributes of `~/.local/share/claude`. "
                    + run("chmod -N ~/.local/share/claude")
            ),
            (
                "everyone allow add_file", ".local/bin", false, nil,
                listText("folder's", run("chmod -N ~/.local/bin"))
            ),
            (
                "user:\(me) deny readsecurity", ".local/bin", true, nil,
                "Refused ~/.local/bin/claude: its folder cannot be checked, because you cannot read the attributes of `~/.local/bin`. "
                    + run("chmod -N ~/.local/bin")
            ),
            (
                "user:\(me) deny search", ".local/bin", false, nil,
                "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `~/.local/bin`. "
                    + run("chmod -N ~/.local/bin")
            ),
            (
                "user:\(me) deny search", ".local/bin", false, "uchg",
                "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `~/.local/bin`. "
                    + "Run `chflags nouchg ~/.local/bin`, then `chmod -N ~/.local/bin` in Terminal."
            ),
            (
                "user:\(me) deny search", ".local/bin", false, "uappnd",
                "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `~/.local/bin`. "
                    + "Run `chflags nouappnd ~/.local/bin`, then `chmod -N ~/.local/bin` in Terminal."
            ),
        ]
        for item in cases {
            let name = "\(item.entry) on \(item.on) \(item.flag ?? "")"
            let cli = try setUp()
            defer { finish(cli) }
            if item.linked {
                let real = cli.home.appendingPathComponent(versions)
                try FileManager.default.createDirectory(
                    at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: cli.fakePath, to: real)
                try FileManager.default.createSymbolicLink(
                    at: cli.fakePath, withDestinationURL: real)
            }
            let before = try cli.run(["doctor"])
            #expect(before.status == 0, "\(name): \(text(before.stdout))")
            let target = cli.home.appendingPathComponent(item.on).path
            #expect(try runTool("/bin/chmod", ["+a", item.entry, target]) == 0, "\(name)")
            if let flag = item.flag {
                #expect(try runTool("/usr/bin/chflags", [flag, target]) == 0, "\(name)")
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
            let named = commands(said, cli)
            #expect(!named.isEmpty, "\(name)")
            for command in named {
                #expect(try runTool(command.tool, command.words) == 0, "\(name): \(command)")
            }
            let after = try cli.run(["doctor"])
            #expect(after.status == 0, "\(name): \(text(after.stdout))")
        }
    }
}

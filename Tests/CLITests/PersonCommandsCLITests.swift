import Core
import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// `run`, `uninstall` and `doctor` end to end against the fake `claude` in a temporary home.
@Suite struct PersonCommandsCLITests {
    func setUp(token: String? = nil) throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fake("default.exit", "0")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                expectedPlanTier: "max_20x"),
            Account(label: "pool-a", kind: Kind.token, role: Role.pool),
        ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        let hooks = HookRecord(context: context)
        try hooks.record(.empty)
        // A reader saves the verdict that `run` relies on.
        _ = try hooks.readSettings()
        if let token {
            _ = try TokenAccounts.install(context: context, label: "pool-a", token: token)
        }
        return cli
    }

    func launchFiles(_ cli: CLIHome) -> [URL] {
        cli.dataEntries().filter { $0.lastPathComponent.hasPrefix("l-") }
    }

    // MARK: run

    @Test func runStartsClaudeWithTheLaunchFileThenThePersonsArguments() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let out = try cli.run(["run", "main", "--", "--model", "opus"])
        #expect(out.status == 0)
        let files = launchFiles(cli)
        #expect(files.count == 1)
        let args = cli.fakeRecord("args.log").split(separator: "\n").map(String.init)
        let started = try #require(args.last { $0.contains("--settings") })
        let path = try #require(files.first).resolvingSymlinksInPath().path
        #expect(started.hasPrefix("--settings "))
        #expect(started.hasSuffix(" --model opus"))
        let named = started.dropFirst("--settings ".count).dropLast(" --model opus".count)
        #expect(URL(fileURLWithPath: String(named)).resolvingSymlinksInPath().path == path)
        #expect(cli.mode(try #require(files.first)) == 0o600)
    }

    @Test func runStartsOnAnAccountWithNoReadingYet() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        #expect(cli.read("state/readings/pool-a.json").isEmpty)
        let out = try cli.run(["run", "pool-a"])
        #expect(out.status == 0)
        #expect(cli.fakeRecord("args.log").contains("--settings"))
    }

    @Test func runRefusesATokenAccountWhoseProbesRejectionStands() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        try cli.fakeProbe("ok.jsonl")
        #expect(try cli.run(["refresh", "--label", "pool-a"]).status == 0)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "pool-a", "--force"]).status == 1)
        // The refusal gives the next step the status row gives, in the same words.
        let status = try cli.run(["status", "--cached", "--json"])
        let document = try #require(
            JSONSerialization.jsonObject(with: status.stdout) as? [String: Any])
        let rows = try #require(document["accounts"] as? [[String: Any]])
        let row = try #require(rows.first { $0["label"] as? String == "pool-a" })
        let error = try #require(row["error"] as? [String: Any])
        #expect(error["text"] as? String == Messages.probeLoginRejected)
        for args in [["run", "pool-a"], ["run", "--print-command", "pool-a"]] {
            let out = try cli.run(args)
            #expect(out.status == 1, "\(args)")
            #expect(text(out.stderr).contains("Error: \(Messages.probeLoginRejected)"), "\(args)")
        }
        #expect(launchFiles(cli).isEmpty)
    }

    @Test func runPassesTheChildsExitStatusThrough() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fake("default.exit", "3")
        let out = try cli.run(["run", "main", "--", "-c"])
        #expect(out.status == 3)
    }

    @Test func runGivesTheChildNoProtectedVariable() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let out = try cli.run(
            ["run", "main"],
            env: ["ANTHROPIC_API_KEY": "key-value", "CLAUDE_CONFIG_DIR": "/tmp/x", "TERM": "xterm"])
        #expect(out.status == 0)
        let names = cli.fakeRecord("env-names.txt")
        #expect(names.contains("TERM"))
        #expect(!names.contains("ANTHROPIC_API_KEY") && !names.contains("CLAUDE_CONFIG_DIR"))
        #expect(
            cli.fakeRecord("config-dir.txt").trimmingCharacters(in: .whitespacesAndNewlines)
                == "unset")
    }

    @Test func printCommandShowsTheLineAndNeverAToken() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        let out = try cli.run(["run", "--print-command", "pool-a", "--", "--model", "opus"])
        #expect(out.status == 0)
        let shown = text(out.stdout)
        #expect(shown.hasPrefix("claude --settings '"))
        #expect(shown.contains("/pool-a/l-"))
        #expect(shown.contains(" --model opus"))
        #expect(!shown.contains(secret))
        #expect(!text(out.stderr).contains(secret))
        #expect(!cli.fakeRecord("args.log").contains("--settings"))
        // The token sits only in its token file and the launch file the line names.
        let holders = cli.dataEntries().filter {
            (try? String(contentsOf: $0, encoding: .utf8))?.contains(secret) == true
        }
        #expect(holders.count == 2)
    }

    @Test func inAChatShellRunPrintsTheLineToTypeWritesNothingAndNeverStartsClaude() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        let chat = ["CLAUDE_CODE_CHILD_SESSION": "1"]
        let before = cli.dataEntries().map(\.path).sorted()
        func check(_ out: Support.Output, line: String) {
            #expect(out.status == 1)
            #expect(text(out.stdout) == line + "\n")
            #expect(text(out.stderr).contains(Messages.chatShellRefusal))
            #expect(!text(out.stdout).contains(secret) && !text(out.stderr).contains(secret))
            #expect(!cli.fakeRecord("args.log").contains("--settings"))
            #expect(cli.dataEntries().map(\.path).sorted() == before)
        }
        check(
            try cli.run(["run", "main", "--", "-c"], env: chat),
            line: "agent-balancer run main -- -c")
        check(try cli.run(["run", "pool-a"], env: chat), line: "agent-balancer run pool-a")
        // An empty value counts as a chat shell too.
        check(
            try cli.run(["run", "main"], env: ["CLAUDE_CODE_CHILD_SESSION": ""]),
            line: "agent-balancer run main")
        // --print-command prints the same line to type, not a launch line.
        check(
            try cli.run(["run", "--print-command", "main", "--", "it's", "$(id)"], env: chat),
            line: "agent-balancer run main -- 'it'\\''s' '$(id)'")
        // A refused argument prints no line and still writes nothing.
        let settings = try cli.run(["run", "main", "--", "--settings", "x"], env: chat)
        #expect(settings.status == 1 && text(settings.stdout).isEmpty)
        let sub = try cli.run(["run", "main", "--", "auth", "logout"], env: chat)
        #expect(sub.status == 1 && text(sub.stdout).isEmpty)
        let unknown = try cli.run(["run", "nope"], env: chat)
        #expect(unknown.status == 1 && text(unknown.stdout).isEmpty)
        let tokenArg = try cli.run(["run", "main", "--", secret], env: chat)
        #expect(tokenArg.status == 1 && text(tokenArg.stdout).isEmpty)
        #expect(!text(tokenArg.stderr).contains(secret))
        #expect(cli.dataEntries().map(\.path).sorted() == before)
        #expect(!cli.fakeRecord("args.log").contains("--settings"))
    }

    @Test func everyRunRefusalWritesNothingAndNeverStartsClaude() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        let before = cli.dataEntries().map(\.path).sorted()
        let cases: [([String], [String: String])] = [
            (["run", "main", "--", "--settings", "x"], [:]),
            (["run", "main", "--", "--settings=x"], [:]),
            (["run", "main", "--", "mcp", "list"], [:]),
            (["run", "--print-command", "main", "--", "update"], [:]),
            (["run", "--print-command", "main"], ["CLAUDE_CONFIG_DIR": "/tmp/x"]),
            (["run", "--print-command", "pool-a"], ["ANTHROPIC_API_KEY": "k"]),
            (["run", "--print-command", "pool-a"], [ProtectedEnv.tokenVariable: secret]),
            (["run", "--print-command", "main", "--", secret], [:]),
        ]
        for (args, env) in cases {
            let out = try cli.run(args, env: env)
            #expect(out.status == 1, "\(args)")
            #expect(text(out.stdout).isEmpty)
            #expect(!text(out.stdout).contains(secret) && !text(out.stderr).contains(secret))
        }
        #expect(cli.dataEntries().map(\.path).sorted() == before)
        #expect(!cli.fakeRecord("args.log").contains("--settings"))
    }

    @Test func printCommandRefusesAJobFolderThatIsNotTheDefaultOneForLoginAndToken() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        let before = cli.dataEntries().map(\.path).sorted()
        let home = cli.home.path
        let values = [
            home + "/.agent-balancer/accounts/spare/.claude/jobs/abc",
            home + "/.claude/jobs/../other", "relative/jobs/abc", home + "/.claude/jobs/a/b",
        ]
        for value in values {
            for label in ["main", "pool-a"] {
                let out = try cli.run(
                    ["run", "--print-command", label], env: ["CLAUDE_JOB_DIR": value])
                #expect(out.status == 1, "\(label) \(value)")
                #expect(text(out.stdout).isEmpty, "\(label) \(value)")
                #expect(
                    text(out.stderr).contains("ambient session folder not default"),
                    "\(label) \(value)")
                #expect(!text(out.stderr).contains(secret))
            }
        }
        #expect(cli.dataEntries().map(\.path).sorted() == before)
        #expect(!cli.fakeRecord("args.log").contains("--settings"))
    }

    @Test func printCommandPrintsTheLineInADefaultJobFolder() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let job = cli.home.path + "/.claude/jobs/abc123"
        for label in ["main", "pool-a"] {
            let out = try cli.run(
                ["run", "--print-command", label], env: ["CLAUDE_JOB_DIR": job])
            #expect(out.status == 0, "\(label) \(text(out.stderr))")
            #expect(text(out.stdout).hasPrefix("claude --settings '"), "\(label)")
            #expect(!text(out.stdout).contains("CLAUDE_CONFIG_DIR"))
        }
    }

    @Test func runRefusesAfterASettingsEditUntilAReaderRecordsItAgain() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.settings("{}")
        let stale = try cli.run(["run", "--print-command", "main"])
        #expect(stale.status == 1)
        #expect(text(stale.stderr).contains("Run `agent-balancer doctor` in Terminal."))
        #expect(launchFiles(cli).isEmpty)
        #expect(try cli.run(["doctor"]).status == 0)
        #expect(try cli.run(["run", "--print-command", "main"]).status == 0)
        // A key in the settings is learned by the reader, and a token account then refuses.
        let secret = Canary.realShapeToken()
        let tokenCli = try setUp(token: secret)
        defer { tokenCli.cleanup() }
        try tokenCli.settings("{\"apiKeyHelper\":\"x\"}")
        _ = try tokenCli.run(["doctor"])
        let refused = try tokenCli.run(["run", "pool-a"])
        #expect(refused.status == 1)
        #expect(text(refused.stderr).contains("API key or key helper"))
        #expect(!tokenCli.fakeRecord("args.log").contains("--settings"))
    }

    /// Without the guard this would start the host's own `claude`.
    @Test(.enabled(if: Support.noHostClaude))
    func runRejectsAMissingClaudeBeforeWritingAnyFile() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        try FileManager.default.removeItem(at: cli.fakePath)
        let before = cli.dataEntries().map(\.path).sorted()
        let out = try cli.run(["run", "pool-a"])
        #expect(out.status == 1)
        #expect(cli.dataEntries().map(\.path).sorted() == before)
    }

    @Test func runRefusesWithTheTokenMissingTextAndStartsNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let out = try cli.run(["run", "pool-a"])
        #expect(out.status == 1)
        #expect(text(out.stderr).contains(Messages.tokenMissing("pool-a")))
        #expect(!cli.fakeRecord("args.log").contains("--settings"))
        #expect(launchFiles(cli).isEmpty)
    }

    @Test func runRefusesALoggedOutLoginWithTheLoginRejectedText() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fakeFixture("logged_out", exit: 1)
        let out = try cli.run(["run", "main"])
        #expect(out.status == 1)
        #expect(text(out.stderr).contains("Login rejected."))
        // A login account's refusal gives its own next step, not a token probe's text.
        #expect(text(out.stderr).contains("Run `claude` and sign in again"))
        #expect(!text(out.stderr).contains(Messages.probeLoginRejected))
        #expect(!cli.fakeRecord("args.log").contains("--settings"))
    }

    // MARK: uninstall

    @Test func uninstallListsFirstAndRemovesOnlyAfterTheTypedWord() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let accounts = cli.dataRoot.appendingPathComponent("accounts/keep/.claude/x.json")
        try FileManager.default.createDirectory(
            at: accounts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: accounts, atomically: true, encoding: .utf8)

        let refused = try cli.run(["uninstall"], stdin: "no\n")
        #expect(refused.status == 1)
        let listing = text(refused.stdout)
        #expect(listing.contains("token files: 1"))
        #expect(listing.contains("launch files: 1"))
        #expect(listing.contains("launch files a session record still names: 0"))
        #expect(!listing.contains(secret) && !listing.contains("/l-"))
        #expect(!cli.read("config.json").isEmpty)

        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 0)
        let shown = text(done.stdout)
        #expect(shown.contains("may keep working until their year ends"))
        #expect(!shown.contains(secret))
        #expect(cli.read("config.json").isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: cli.dataRoot.appendingPathComponent("state").path))
        // A fresh launch file is younger than the lease window, so it stays as a tombstone.
        let left = launchFiles(cli)
        #expect(left.count == 1)
        for file in left {
            #expect(!((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains(secret))
        }
        #expect(FileManager.default.fileExists(atPath: accounts.path))
    }

    @Test func uninstallRefusesInAChatShellAndRemovesNothing() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let out = try cli.run(
            ["uninstall"], env: ["CLAUDE_CODE_CHILD_SESSION": "1"], stdin: "uninstall\n")
        #expect(out.status == 1)
        #expect(text(out.stderr).contains(Messages.chatShellRefusal))
        #expect(!cli.read("config.json").isEmpty)
    }

    // MARK: doctor

    @Test func doctorShowsTheLaunchFileCountAndAge() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let before = try cli.run(["doctor"])
        #expect(text(before.stdout).contains("launch files: 0"))
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let after = try cli.run(["doctor"])
        #expect(text(after.stdout).contains("launch files: 1, oldest under a minute old"))
        #expect(!text(after.stdout).contains("/l-"))
    }

    @Test func doctorWarnsWhenTheHomeSitsInASyncedFolder() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let inside = cli.home.appendingPathComponent("Dropbox/home")
        let bin = inside.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: cli.fakePath, to: bin.appendingPathComponent("claude"))
        let context = ToolContext(home: inside, ambient: [:])
        try ConfigStore(context: context).save(Config(accounts: []))
        try HookRecord(context: context).record(.empty)
        let out = try cli.run(["doctor"], env: ["HOME": inside.path])
        #expect(text(out.stdout).contains("the data folder sits in Dropbox"))
        let plain = try cli.run(["doctor"])
        #expect(!text(plain.stdout).contains("sits in"))
    }
}

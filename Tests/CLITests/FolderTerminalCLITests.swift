import Core
import Foundation
import Testing

@testable import Core

private func shown(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// Applying needs a terminal, advice that clears its state, and the caller-folder rules, end to
/// end against the fake `claude` in a temporary home.
extension FolderAccountsCLITests {
    static let twoHooks =
        #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"},{"type":"command","command":"echo two"}]}]}}"#

    /// Everything a refused command must leave alone: the links record, the config, the data
    /// folder's entries, the account folder's links and the default folder's files.
    func world(_ cli: CLIHome) throws -> [String: String] {
        var out: [String: String] = [
            "links": cli.read("links.json"), "config": cli.read("config.json"),
            "entries": cli.dataEntries().map(\.path).sorted().joined(separator: "\n"),
        ]
        let fm = FileManager.default
        let account = try folderPath(cli)
        for name in ((try? fm.contentsOfDirectory(atPath: account)) ?? []).sorted() {
            out["account/" + name] =
                (try? fm.destinationOfSymbolicLink(atPath: account + "/" + name)) ?? "not a link"
        }
        let source = cli.home.appendingPathComponent(".claude")
        for name in ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).sorted() {
            out["default/" + name] =
                (try? String(contentsOf: source.appendingPathComponent(name), encoding: .utf8))
                ?? "unreadable"
        }
        return out
    }

    func removeLink(_ cli: CLIHome, _ name: String) throws {
        try FileManager.default.removeItem(
            atPath: URL(fileURLWithPath: try folderPath(cli)).appendingPathComponent(name).path)
    }

    typealias Scenario = (
        name: String, args: [String], word: String,
        prepare: (FolderAccountsCLITests, CLIHome) throws -> Void
    )

    /// One state per applying command, the command, and the word it asks for.
    static var applyingScenarios: [Scenario] {
        [
            ("link", ["link", "spare"], "spare", { _, _ in }),
            (
                "repair", ["link", "--repair", "spare"], "spare",
                { suite, cli in
                    try suite.linked(cli)
                    try suite.removeLink(cli, "CLAUDE.md")
                }
            ),
            (
                "accept", ["link", "--accept-source-change"], "accept",
                { suite, cli in
                    try suite.linked(cli)
                    try cli.settings(twoHooks)
                }
            ),
            (
                "accept all", ["link", "--accept-source-change", "--all"], "accept",
                { suite, cli in
                    try suite.linked(cli)
                    try cli.settings(twoHooks)
                }
            ),
            ("unlink", ["unlink", "spare"], "spare", { suite, cli in try suite.linked(cli) }),
        ]
    }

    // MARK: applying needs a terminal

    @Test func everyApplyingCommandRefusesWithoutATerminalAndWritesNothing() throws {
        for scenario in Self.applyingScenarios {
            let cli = try setUp()
            defer { cli.cleanup() }
            try scenario.prepare(self, cli)
            let before = try world(cli)
            // The word is on standard input, but a pipe is not a person at a terminal.
            let piped = try cli.run(scenario.args, stdin: scenario.word + "\n")
            #expect(piped.status == 1, "\(scenario.name)")
            #expect(shown(piped.stderr).contains(Messages.terminalRequired), "\(scenario.name)")
            #expect(!shown(piped.stdout).contains("Type "), "\(scenario.name)")
            #expect(try world(cli) == before, "\(scenario.name)")
            // The same state applies on a terminal, so the refusal above was not a vacuous one.
            let typed = try cli.runOnTerminal(scenario.args, typing: scenario.word + "\n")
            #expect(typed.status == 0, "\(scenario.name) \(shown(typed.stderr))")
            #expect(try world(cli) != before, "\(scenario.name)")
        }
    }

    @Test func noVariableSwitchesTheTerminalCheckOff() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let before = try world(cli)
        let env = ["CI": "1", "TERM": "xterm", "CLAUDECODE": "1", "FORCE_TTY": "1"]
        let out = try cli.run(["link", "spare"], env: env, stdin: "spare\n")
        #expect(out.status == 1)
        #expect(shown(out.stderr).contains(Messages.terminalRequired))
        #expect(try world(cli) == before)
    }

    @Test func aDryRunNeedsNoTerminal() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try removeLink(cli, "CLAUDE.md")
        try cli.settings(Self.twoHooks)
        // A reader saves the verdict for the new file.
        _ = try cli.run(["doctor"])
        let before = try world(cli)
        for args in [
            ["link", "spare", "--dry-run"], ["link", "--repair", "spare", "--dry-run"],
            ["link", "--accept-source-change", "--dry-run"],
        ] {
            let out = try cli.run(args)
            #expect(out.status == 0, "\(args) \(shown(out.stderr))")
            #expect(shown(out.stdout).contains("Dry run: nothing was changed."), "\(args)")
        }
        #expect(try world(cli) == before)
    }

    @Test func everyApplyingCommandProceedsWhenOnlyClaudeCodeIsSetInAnEditorTerminal() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let editor = ["CLAUDECODE": "1"]
        let link = try cli.runOnTerminal(["link", "spare"], env: editor, typing: "spare\n")
        #expect(link.status == 0, "\(shown(link.stderr))")
        #expect(try destination(cli, "CLAUDE.md") != nil)
        try removeLink(cli, "CLAUDE.md")
        let repair = try cli.runOnTerminal(
            ["link", "--repair", "spare"], env: editor, typing: "spare\n")
        #expect(repair.status == 0, "\(shown(repair.stderr))")
        #expect(try destination(cli, "CLAUDE.md") != nil)
        try cli.settings(Self.twoHooks)
        let accept = try cli.runOnTerminal(
            ["link", "--accept-source-change"], env: editor, typing: "accept\n")
        #expect(accept.status == 0, "\(shown(accept.stderr))")
        #expect(shown(accept.stdout).contains("Recorded 2 hook entries."))
        let unlink = try cli.runOnTerminal(["unlink", "spare"], env: editor, typing: "spare\n")
        #expect(unlink.status == 0, "\(shown(unlink.stderr))")
        #expect(try destination(cli, "CLAUDE.md") == nil)
    }

    // MARK: status file and printed hook line

    func statusRow(_ cli: CLIHome) throws -> [String: Any] {
        let data = Data(cli.read("state/status.json").utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try #require(object["accounts"] as? [[String: Any]])
        return try #require(accounts.first { $0["label"] as? String == "spare" })
    }

    @Test func linkAndUnlinkRebuildTheStatusFile() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let file = cli.dataRoot.appendingPathComponent("state/status.json")
        try? FileManager.default.removeItem(at: file)
        #expect(try cli.runOnTerminal(["link", "spare"], typing: "spare\n").status == 0)
        #expect(try statusRow(cli)["linked"] as? Bool == true)
        try FileManager.default.removeItem(at: file)
        #expect(try cli.runOnTerminal(["unlink", "spare"], typing: "spare\n").status == 0)
        #expect(try statusRow(cli)["linked"] as? Bool == false)
    }

    @Test func acceptSourceChangePrintsTheDisableAllHooksLine() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.settings(Self.twoHooks)
        let plain = try cli.runOnTerminal(["link", "--accept-source-change"], typing: "no\n")
        #expect(shown(plain.stdout).contains("disableAllHooks: not present"))
        try cli.settings(
            #"{"disableAllHooks":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]}]}}"#
        )
        let off = try cli.runOnTerminal(["link", "--accept-source-change"], typing: "no\n")
        #expect(shown(off.stdout).contains("disableAllHooks: present"))
        #expect(!shown(off.stdout).contains("disableAllHooks: not present"))
    }

    // MARK: advice that clears its state

    @Test func aDanglingSourceIsNamedByRepairAndFixingItClearsVerify() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let skills = cli.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createSymbolicLink(
            atPath: skills.path, withDestinationPath: cli.home.path + "/nowhere")
        let verify = try cli.run(["verify", "spare", "--no-reading"])
        #expect(verify.status == 1)
        #expect(shown(verify.stdout).contains("fix the item it names"))
        let refused = try cli.runOnTerminal(["link", "--repair", "spare"], typing: "spare\n")
        #expect(refused.status == 1)
        let out = shown(refused.stdout)
        #expect(out.contains("Refused: skills") && out.contains("goes nowhere"))
        #expect(out.contains("~/.claude/skills"))
        #expect(out.contains("`agent-balancer link --repair spare` again"))
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 1)
        try FileManager.default.removeItem(at: skills)
        let fixed = try cli.runOnTerminal(["link", "--repair", "spare"], typing: "spare\n")
        #expect(fixed.status == 0, "\(shown(fixed.stdout)) \(shown(fixed.stderr))")
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
    }

    @Test func aSourceYouDoNotOwnIsNamedByRepairAndFixingItClearsVerify() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let skills = cli.home.appendingPathComponent(".claude/skills")
        // The system's /usr folder belongs to root.
        try FileManager.default.createSymbolicLink(atPath: skills.path, withDestinationPath: "/usr")
        let refused = try cli.runOnTerminal(["link", "--repair", "spare"], typing: "spare\n")
        #expect(refused.status == 1)
        let out = shown(refused.stdout)
        #expect(out.contains("Refused: skills") && out.contains("not owned by you"))
        #expect(out.contains("~/.claude/skills") && out.contains("again"))
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 1)
        try FileManager.default.removeItem(at: skills)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: false)
        let fixed = try cli.runOnTerminal(["link", "--repair", "spare"], typing: "spare\n")
        #expect(fixed.status == 0, "\(shown(fixed.stdout)) \(shown(fixed.stderr))")
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
    }

    @Test func aDestinationInTheWayIsNamedByRepairAndFixingItClearsVerify() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let skills = cli.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: false)
        let mine = URL(fileURLWithPath: try folderPath(cli)).appendingPathComponent("skills")
        try "mine".write(to: mine, atomically: true, encoding: .utf8)
        let refused = try cli.runOnTerminal(["link", "--repair", "spare"], typing: "spare\n")
        #expect(refused.status == 1)
        let out = shown(refused.stdout)
        #expect(out.contains("Refused: skills") && out.contains("destination exists"))
        #expect(out.contains("accounts/spare/.claude/skills") && out.contains("again"))
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 1)
        try FileManager.default.removeItem(at: mine)
        let fixed = try cli.runOnTerminal(["link", "--repair", "spare"], typing: "spare\n")
        #expect(fixed.status == 0, "\(shown(fixed.stdout)) \(shown(fixed.stderr))")
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
    }

    @Test func theLinksRecordRefusalAdviceClearsTheState() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let url = cli.dataRoot.appendingPathComponent("links.json")
        try #"{"schemaVersion":1,"links":[{"path":1}],"linkedLabels":["spare"]}"#.write(
            to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o600)
        let before = cli.read("links.json")
        let refused = try cli.runOnTerminal(["unlink", "spare"], typing: "spare\n")
        #expect(refused.status == 1)
        let advice = shown(refused.stderr)
        #expect(advice.contains("Move links.json aside"))
        #expect(advice.contains("`agent-balancer link --accept-source-change`"))
        #expect(advice.contains("`agent-balancer link <label>`"))
        #expect(cli.read("links.json") == before)
        // Follow the advice, step by step.
        try FileManager.default.moveItem(
            at: url, to: cli.dataRoot.appendingPathComponent("links.json.aside"))
        let accept = try cli.runOnTerminal(["link", "--accept-source-change"], typing: "accept\n")
        #expect(accept.status == 0, "\(shown(accept.stderr))")
        let again = try cli.runOnTerminal(["link", "spare"], typing: "spare\n")
        #expect(again.status == 0, "\(shown(again.stdout)) \(shown(again.stderr))")
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
    }

    // MARK: a record with a malformed hash

    @Test func aMalformedHashInTheRecordRefusesEverySaveAndTheAdvisedAcceptClearsIt() throws {
        for field in ["fingerprint", "commandHash"] {
            let cli = try setUp()
            defer { cli.cleanup() }
            try linked(cli)
            let url = cli.dataRoot.appendingPathComponent("links.json")
            var object = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var entry: [String: String] = [
                "event": "Stop", "matcher": "",
                "commandHash": String(repeating: "a", count: 64),
                "fingerprint": String(repeating: "b", count: 64),
            ]
            entry[field] = "not-a-hash"
            var folder = try #require(object["defaultFolder"] as? [String: Any])
            folder["hooks"] = [entry]
            object["defaultFolder"] = folder
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
                to: url)
            chmod(url.path, 0o600)
            let before = cli.read("links.json")
            let linksOnDisk = try world(cli)
            for args in [["unlink", "spare"], ["link", "spare"], ["link", "--repair", "spare"]] {
                let refused = try cli.runOnTerminal(args, typing: "spare\n")
                #expect(refused.status != 0, "\(field) \(args)")
                #expect(cli.read("links.json") == before, "\(field) \(args)")
                #expect(try world(cli) == linksOnDisk, "\(field) \(args)")
            }
            let advice = shown(
                try cli.runOnTerminal(["unlink", "spare"], typing: "spare\n").stderr)
            #expect(advice.contains("`agent-balancer link --accept-source-change`"), "\(field)")
            // Follow the advice. The accept keeps the links that are listed.
            let accept = try cli.runOnTerminal(
                ["link", "--accept-source-change"], typing: "accept\n")
            #expect(accept.status == 0, "\(field) \(shown(accept.stderr))")
            let after = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(((after["links"] as? [Any])?.count ?? 0) > 0, "\(field)")
            let removed = try cli.runOnTerminal(["unlink", "spare"], typing: "spare\n")
            #expect(removed.status == 0, "\(field) \(shown(removed.stderr))")
            let again = try cli.runOnTerminal(["link", "spare"], typing: "spare\n")
            #expect(again.status == 0, "\(field) \(shown(again.stderr))")
            #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0, "\(field)")
        }
    }

    // MARK: one bad folder blocks every save

    @Test func aFolderThatBlocksEverySaveNamesTheFixAndRemoveClearsIt() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        chmod(try folderPath(cli), 0o755)
        let blocked = try cli.run(["add", "third", "--kind", "folder"])
        #expect(blocked.status == 1)
        let advice = shown(blocked.stderr)
        #expect(advice.contains("Account 'spare'"))
        #expect(advice.contains("is wider than 0700. Run `chmod 700 "))
        #expect(advice.contains("`agent-balancer remove spare`"))
        let removed = try cli.run(["remove", "spare"])
        #expect(removed.status == 0, "\(shown(removed.stderr))")
        let after = try cli.run(["add", "third", "--kind", "folder"])
        #expect(after.status == 0, "\(shown(after.stderr))")
    }

    // MARK: uninstall keeps what is not a regular file

    @Test func uninstallKeepsAnEntryThatIsNotARegularFileAndWhatItPointsTo() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let outside = cli.home.appendingPathComponent("outside.txt")
        try "mine".write(to: outside, atomically: true, encoding: .utf8)
        let folder = cli.dataRoot.appendingPathComponent("state")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let odd = folder.appendingPathComponent("odd-link")
        try FileManager.default.createSymbolicLink(
            atPath: odd.path, withDestinationPath: outside.path)
        let pipe = folder.appendingPathComponent("odd-pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let out = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(out.status == 0, "\(shown(out.stderr))")
        var st = stat()
        #expect(lstat(odd.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK)
        #expect(lstat(pipe.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "mine")
        #expect(try destination(cli, "CLAUDE.md") == nil)
    }

    // MARK: the caller's session folder

    @Test func theCallerFolderVariablesNeverReachAnyOutputOrFile() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let jobCanary = Canary.randomTail(24)
        let pidCanary = Canary.randomTail(24)
        let tokenCanary = Canary.realShapeToken()
        try cli.settings(
            #"{"env":{"SOME_VALUE":"\#(tokenCanary)"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]}]}}"#
        )
        _ = try cli.run(["doctor"])
        let shells: [[String: String]] = [
            ["CLAUDE_JOB_DIR": "/elsewhere/" + jobCanary, "CLAUDE_PID": pidCanary],
            [
                "CLAUDE_JOB_DIR": cli.home.path + "/.claude/jobs/" + jobCanary,
                "CLAUDE_PID": pidCanary,
            ],
            [
                "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_JOB_DIR": jobCanary,
                "CLAUDE_PID": pidCanary,
            ],
            ["CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_PID": pidCanary],
        ]
        for env in shells {
            for args in [
                ["pick", "--json"], ["run", "--print-command", "main"],
                ["run", "--print-command", "spare"], ["doctor"],
            ] {
                let out = try cli.run(args, env: env)
                let seen = leakText(cli, out)
                for canary in [jobCanary, pidCanary, tokenCanary] {
                    #expect(!seen.contains(canary), "\(args) \(env.keys.sorted())")
                }
            }
        }
    }

    // MARK: run checks the saved settings verdict

    @Test func aStaleOrMissingSettingsVerdictRefusesAFolderRunWithoutOpeningTheFile() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        // A reader saves the verdict; a folder run then works.
        _ = try cli.run(["doctor"])
        #expect(try cli.run(["run", "--print-command", "spare"]).status == 0)
        let settings = cli.home.appendingPathComponent(".claude/settings.json")
        let original = try String(contentsOf: settings, encoding: .utf8)

        // The file changes and can no longer be opened. A run that opened it would fail with a
        // different text, so only the saved verdict can have been consulted.
        try Self.twoHooks.write(to: settings, atomically: true, encoding: .utf8)
        chmod(settings.path, 0o000)
        defer { chmod(settings.path, 0o600) }
        #expect(access(settings.path, R_OK) != 0)
        let before = cli.dataEntries().map(\.path).sorted()
        let argsBefore = cli.fakeRecord("args.log")
        for args in [["run", "--print-command", "spare"], ["run", "spare"]] {
            let stale = try cli.run(args)
            #expect(stale.status == 1, "\(args)")
            #expect(shown(stale.stderr).contains(Messages.settingsNotChecked), "\(args)")
            #expect(shown(stale.stderr).contains("`agent-balancer doctor` in Terminal"))
            #expect(shown(stale.stdout).isEmpty)
        }
        #expect(cli.dataEntries().map(\.path).sorted() == before)
        #expect(cli.fakeRecord("args.log") == argsBefore)

        // A missing verdict refuses the same way.
        chmod(settings.path, 0o600)
        try original.write(to: settings, atomically: true, encoding: .utf8)
        _ = try cli.run(["doctor"])
        #expect(try cli.run(["run", "--print-command", "spare"]).status == 0)
        try FileManager.default.removeItem(
            at: cli.dataRoot.appendingPathComponent("state/settings-seen.json"))
        let missing = try cli.run(["run", "--print-command", "spare"])
        #expect(missing.status == 1)
        #expect(shown(missing.stderr).contains(Messages.settingsNotChecked))
    }
}

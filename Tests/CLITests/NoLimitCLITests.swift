import Foundation
import Testing

@testable import Core

/// `config set <label> no-limit`, and what `config show`, `status` and `pick` make of the
/// setting, end to end against the fake `claude`.
@Suite struct NoLimitCLITests {
    func setUp(_ accounts: [Account]) throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: accounts)
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    func login(role: String = Role.pool, noLimit: [String]? = nil) -> Account {
        Account(
            label: "main", kind: Kind.login, role: role, email: "main@example.com",
            expectedPlanTier: "max_20x", noLimit: noLimit)
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func object(_ out: Support.Output) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
    }

    /// The account's object in `config.json` as saved.
    func saved(_ cli: CLIHome, _ label: String = "main") throws -> [String: Any] {
        let data = Data(cli.read("config.json").utf8)
        let config = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try #require(config["accounts"] as? [[String: Any]])
        return try #require(accounts.first { $0["label"] as? String == label })
    }

    func backups(_ cli: CLIHome) -> Int {
        let folder = cli.dataRoot.appendingPathComponent("backups").path
        return (try? FileManager.default.contentsOfDirectory(atPath: folder))?.count ?? 0
    }

    /// Makes the fake `claude` reply with the weekly window and, when given, the 5-hour one.
    func reply(_ cli: CLIHome, fiveHour: Double? = nil) throws {
        let now = Int(Date().timeIntervalSince1970)
        var windows = "\"seven_day\":{\"utilization\":0.1,\"resetsAt\":\(now + 3 * 86_400)}"
        if let fiveHour {
            windows =
                "\"five_hour\":{\"utilization\":\(fiveHour),\"resetsAt\":\(now + 3_600)}," + windows
        }
        try cli.fake(
            "probe.jsonl",
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\","
                + "\"unifiedWindows\":{\(windows)}}}\n")
    }

    /// The status document without the two fields that change by themselves between runs.
    func steady(_ out: Support.Output) throws -> [String: Any] {
        var document = try object(out)
        document["generatedAt"] = nil
        let rows = try #require(document["accounts"] as? [[String: Any]])
        document["accounts"] = rows.map { row -> [String: Any] in
            var row = row
            row["readingsAge"] = nil
            return row
        }
        return document
    }

    // MARK: config set

    @Test func configSetTurnsNoLimitOnAndOff() throws {
        let cli = try setUp([login()])
        defer { cli.cleanup() }
        let before = try saved(cli)
        let backupsBefore = backups(cli)

        let on = try cli.run(["config", "set", "main", "no-limit", "five_hour"])
        #expect(on.status == 0, "\(text(on.stderr))")
        #expect(text(on.stdout) == "Updated no-limit for 'main'.\n")
        #expect(try saved(cli)["noLimit"] as? [String] == ["five_hour"])
        #expect(backups(cli) == backupsBefore + 1)
        let shown = text(try cli.run(["config", "show"]).stdout)
        #expect(shown.contains("account main\n"))
        #expect(shown.contains("\n  no-limit: five_hour\n"))

        let off = try cli.run(["config", "set", "main", "no-limit", "none"])
        #expect(off.status == 0, "\(text(off.stderr))")
        #expect(text(off.stdout) == "Updated no-limit for 'main'.\n")
        #expect(NSDictionary(dictionary: try saved(cli)) == NSDictionary(dictionary: before))
        #expect(!text(try cli.run(["config", "show"]).stdout).contains("no-limit"))

        let bytes = cli.read("config.json")
        let kept = backups(cli)
        for value in ["seven_day", "fiveHour", "FIVE_HOUR", "5h", "true"] {
            let out = try cli.run(["config", "set", "main", "no-limit", value])
            #expect(out.status == 1, "\(value)")
            #expect(text(out.stderr).contains("no-limit must be five_hour or none."), "\(value)")
        }
        let missing = try cli.run(["config", "set", "main", "no-limit"])
        #expect(missing.status == 1)
        #expect(
            text(missing.stderr).contains(
                "Usage: config set <label> email|ends|ending-soon|label|no-limit <value>"))
        let unknown = try cli.run(["config", "set", "main", "colour", "red"])
        #expect(unknown.status == 1)
        #expect(
            text(unknown.stderr).contains(
                "Unknown field 'colour'. Use email, ends, ending-soon, label or no-limit."))
        let ghost = try cli.run(["config", "set", "ghost", "no-limit", "five_hour"])
        #expect(ghost.status == 1)
        #expect(text(ghost.stderr).contains("No account is labelled 'ghost'."))
        let chat = try cli.run(
            ["config", "set", "main", "no-limit", "five_hour"],
            env: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        #expect(chat.status == 1)
        #expect(cli.read("config.json") == bytes)
        #expect(backups(cli) == kept)
    }

    // MARK: status

    @Test func statusShowsNoLimitOnlyWhileSet() throws {
        let spare = Account(label: "spare", kind: Kind.token, role: Role.pool)
        let cli = try setUp([login(), spare])
        defer { cli.cleanup() }
        #expect(try cli.run(["refresh", "--label", "main"]).status == 0)
        let table = text(try cli.run(["status", "--cached"]).stdout)
        let document = try steady(try cli.run(["status", "--json", "--cached"]))
        let firstRows = try #require(document["accounts"] as? [[String: Any]])
        // The reading holds a 5-hour window, so the setting changes no pick.
        #expect(firstRows[0]["fiveHour"] is [String: Any])

        #expect(try cli.run(["config", "set", "main", "no-limit", "five_hour"]).status == 0)
        var lines = table.components(separatedBy: "\n")
        let row = try #require(lines.firstIndex { $0.hasPrefix("main [login, pool] ") })
        lines.insert("  no-limit: five_hour", at: row + 1)
        #expect(text(try cli.run(["status", "--cached"]).stdout) == lines.joined(separator: "\n"))
        var set = try steady(try cli.run(["status", "--json", "--cached"]))
        var rows = try #require(set["accounts"] as? [[String: Any]])
        #expect(rows[0]["noLimit"] as? [String] == ["five_hour"])
        #expect(rows[1]["noLimit"] == nil)
        rows[0]["noLimit"] = nil
        set["accounts"] = rows
        #expect(NSDictionary(dictionary: set) == NSDictionary(dictionary: document))

        #expect(try cli.run(["config", "set", "main", "no-limit", "none"]).status == 0)
        #expect(text(try cli.run(["status", "--cached"]).stdout) == table)
        let after = try steady(try cli.run(["status", "--json", "--cached"]))
        #expect(NSDictionary(dictionary: after) == NSDictionary(dictionary: document))
    }

    // MARK: pick

    @Test func aMainAccountWithNoWindowIsPickedOnlyWhileSet() throws {
        let cli = try setUp([login(role: Role.main)])
        defer { cli.cleanup() }
        try reply(cli)
        let refused = "No account has room. main: No 5-hour reading, which the main account needs."
        let unset = try cli.run(["pick", "--json", "--dry-run"])
        #expect(unset.status == 2)
        #expect(try object(unset)["reason"] as? String == refused)

        #expect(try cli.run(["config", "set", "main", "no-limit", "five_hour"]).status == 0)
        let set = try cli.run(["pick", "--json", "--dry-run"])
        #expect(set.status == 0)
        let answer = try object(set)
        #expect(answer["label"] as? String == "main")
        let reason = try #require(answer["reason"] as? String)
        #expect(reason.hasPrefix("Soonest weekly reset: resets "))
        #expect(!reason.contains("5-hour"))

        #expect(try cli.run(["config", "set", "main", "no-limit", "none"]).status == 0)
        let again = try cli.run(["pick", "--json", "--dry-run"])
        #expect(again.status == 2)
        #expect(try object(again)["reason"] as? String == refused)
    }

    @Test func aReplyWithTheWindowStillCountsForASetMainAccount() throws {
        let cli = try setUp([login(role: Role.main)])
        defer { cli.cleanup() }
        try reply(cli, fiveHour: 0.92)
        let full = "No account has room. main: 5-hour use 92.0% leaves no room for a run."
        #expect(try cli.run(["config", "set", "main", "no-limit", "five_hour"]).status == 0)
        let set = try cli.run(["pick", "--json", "--dry-run"])
        #expect(set.status == 2)
        #expect(try object(set)["reason"] as? String == full)
        #expect(try cli.run(["config", "set", "main", "no-limit", "none"]).status == 0)
        let unset = try cli.run(["pick", "--json", "--dry-run"])
        #expect(unset.status == 2)
        #expect(try object(unset)["reason"] as? String == full)
    }

    @Test func aSetAccountKeepsTheStoredWindowRule() throws {
        for role in Role.all {
            let cli = try setUp([login(role: role)])
            defer { cli.cleanup() }
            #expect(
                try cli.run(["config", "set", "main", "no-limit", "five_hour"]).status == 0,
                "\(role)")
            let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
            let now = Date()
            // Stored 20 minutes ago with a 5-hour window, so the pick probes again.
            let old = now.addingTimeInterval(-1_200)
            try store.save(
                Reading(
                    readAt: old,
                    windows: [
                        WindowName.sevenDay: WindowReading(
                            usedPercent: 10, resetsAt: now.addingTimeInterval(3 * 86_400),
                            readAt: old),
                        WindowName.fiveHour: WindowReading(
                            usedPercent: 10, resetsAt: now.addingTimeInterval(3_600), readAt: old),
                    ]), label: "main")
            try reply(cli)
            let out = try cli.run(["pick", "--json", "--dry-run"])
            #expect(out.status == 2, "\(role)")
            #expect(
                try object(out)["reason"] as? String
                    == "No account has room. main: stale reading, refresh failed", "\(role)")
            #expect(try store.load(label: "main")?.fiveHour?.usedPercent == 10, "\(role)")
        }
    }

    @Test func nothingSetsNoLimitByGuess() throws {
        for role in Role.all {
            let cli = try setUp([login(role: role)])
            defer { cli.cleanup() }
            try reply(cli)
            #expect(try cli.run(["refresh"]).status == 0, "\(role)")
            let pick = try cli.run(["pick", "--dry-run"])
            #expect(pick.status == (role == Role.main ? 2 : 0), "\(role)")
            #expect(try cli.run(["status"]).status == 0, "\(role)")
            let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
            #expect(try store.load(label: "main")?.fiveHour == nil, "\(role)")
            #expect(try saved(cli)["noLimit"] == nil, "\(role)")
            #expect(!cli.read("config.json").contains("noLimit"), "\(role)")
        }
    }

    // MARK: A new sign-in

    @Test func anEmailChangeClearsNoLimitForANewSignIn() throws {
        let cleared = "Also cleared no-limit: it was set for the old sign-in."
        let set = ["five_hour"]
        let cli = try setUp([
            login(noLimit: set),
            Account(
                label: "spare", kind: Kind.folder, role: Role.pool, email: "acct@example.com",
                expectedPlanTier: "max_20x", noLimit: set),
            Account(
                label: "tok", kind: Kind.token, role: Role.pool, email: "note@example.com",
                noLimit: set),
        ])
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        try NoFollowWriter(root: context.dataRoot).prepare(
            folders: FolderPaths.folders(label: "spare"))

        // The same email in other letter case is the same sign-in.
        let same = try cli.run(["config", "set", "main", "email", "MAIN@example.com"])
        #expect(same.status == 0, "\(text(same.stderr))")
        #expect(!text(same.stdout).contains("Also cleared"))
        #expect(try saved(cli)["noLimit"] as? [String] == set)

        for label in ["main", "spare"] {
            let out = try cli.run(["config", "set", label, "email", "other-\(label)@example.com"])
            #expect(out.status == 0, "\(label) \(text(out.stderr))")
            #expect(
                text(out.stdout).hasPrefix("Updated email for '\(label)'.\n\(cleared)\n"),
                "\(label)")
            #expect(try saved(cli, label)["noLimit"] == nil, "\(label)")
            #expect(try saved(cli, label)["expectedPlanTier"] == nil, "\(label)")
        }

        // Now unset, a further change has nothing to clear.
        let again = try cli.run(["config", "set", "main", "email", "third@example.com"])
        #expect(again.status == 0)
        #expect(!text(again.stdout).contains("Also cleared"))

        // A token account's email is a note, so its setting stays.
        let token = try cli.run(["config", "set", "tok", "email", "new-note@example.com"])
        #expect(token.status == 0, "\(text(token.stderr))")
        #expect(text(token.stdout) == "Updated email for 'tok'.\n")
        #expect(try saved(cli, "tok")["noLimit"] as? [String] == set)
    }

    // MARK: Docs

    @Test func theDocsDescribeNoLimit() throws {
        let config = try ContractAndArchitectureTextTests.section("### 7.1 Config", level: "###")
        #expect(
            config.contains(
                "This version accepts only `[\"five_hour\"]`; the validator refuses every other value, the empty list included."
            ))
        let rules = try ContractAndArchitectureTextTests.section(
            "### 7.2 Rules, in order", level: "###")
        #expect(
            rules.contains(
                "An account whose `noLimit` lists `five_hour` (7.1) and whose stored reading holds no 5-hour window is judged on its weekly use: a protected one by rules 2, 4 and 7 with no 5-hour check, a pool one by rules 3, 4 and 7."
            ))
        let status = try ContractAndArchitectureTextTests.section(
            "### 10.1 `agent-balancer status --json`", level: "###")
        #expect(
            status.contains(
                "`noLimit` is on a row only while its account's entry in `config.json` carries it (7.1), as the same list; other rows have no such key, and the menu app does not read it."
            ))
        let guide = try ContractAndArchitectureTextTests.prose("docs/GUIDE.md")
        #expect(
            guide.contains(
                "If you know an account's plan has no five-hour limit, run `agent-balancer config set <label> no-limit five_hour` in your own terminal."
            ))
        let contract = try ContractAndArchitectureTextTests.prose("docs/CONTRACT.md")
        #expect(
            contract.contains(
                "A row also carries `noLimit`, a list of usage window names (`[\"five_hour\"]` in this version), while a person has set with `config set <label> no-limit five_hour` that the account's plan has no limit on them; rows without the setting have no such key."
            ))
    }
}

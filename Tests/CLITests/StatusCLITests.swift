import Foundation
import Testing

@testable import Core

/// status, events and history end to end against the fake `claude`.
@Suite struct StatusCLITests {
    func login() -> Account {
        Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
    }

    func setUp(_ accounts: [Account]? = nil, tune: (inout Config) -> Void = { _ in }) throws
        -> CLIHome
    {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: accounts ?? [login()])
        config.fable.probe = false
        tune(&config)
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    func object(_ out: Support.Output) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
    }

    func rows(_ out: Support.Output) throws -> [[String: Any]] {
        try #require(object(out)["accounts"] as? [[String: Any]])
    }

    func argsLog(_ cli: CLIHome) -> [String] {
        cli.fakeRecord("args.log").split(separator: "\n").map(String.init)
    }

    func generatedAt(_ cli: CLIHome) throws -> String {
        let data = try #require(cli.read("state/status.json").data(using: .utf8))
        let doc = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(doc["generatedAt"] as? String)
    }

    // MARK: status

    @Test func statusJsonCarriesTheSchemaFields() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let out = try cli.run(["status", "--json"])
        #expect(out.status == 0)
        let doc = try object(out)
        #expect(doc["schemaVersion"] as? Int == 1)
        let row = try #require(try rows(out).first)
        for key in [
            "label", "email", "role", "kind", "fullLogin", "configDir", "state", "stateSince",
            "limited", "error", "warnings", "planTier", "weekly", "fable", "fiveHour", "inUse",
            "endsAt", "loginExpiresAt", "reserve", "accountKey", "endingSoon", "linked",
            "readingsAge",
        ] {
            #expect(row[key] != nil, "missing \(key)")
        }
        #expect(row["state"] as? String == "ok")
        #expect(row["kind"] as? String == "login" && row["fullLogin"] as? Bool == true)
        #expect(row["planTier"] as? String == "max_20x")
        let next = try #require(doc["next"] as? [String: Any])
        #expect((next["all"] as? [String: Any])?["label"] as? String == "main")
        #expect(cli.expectPrivateModes().isEmpty)
        // The file the menu reads is the same document.
        #expect(cli.read("state/status.json").contains("\"label\" : \"main\""))
    }

    @Test func everyStateFileIsPrivateAfterRefreshAndStatus() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        _ = try cli.run(["status", "--json"])
        for name in ["status.json", "events.jsonl", "current.json", "history/main.jsonl"] {
            let url = cli.dataRoot.appendingPathComponent("state/\(name)")
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(name)")
            #expect(cli.mode(url) == 0o600, "\(name) mode")
        }
        #expect(cli.mode(cli.dataRoot.appendingPathComponent("state/history")) == 0o700)
    }

    @Test func eventsRefusesABadLabelLimitOrTypeWithExitOne() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        for args in [
            ["--label", "../x"], ["--limit", "0"], ["--limit", "1001"], ["--type", "A b"],
        ] {
            let out = try cli.run(["events", "--json"] + args)
            #expect(out.status == 1, "\(args)")
        }
        #expect(try cli.run(["events", "--json", "--limit", "1000"]).status == 0)
        #expect(try cli.run(["events", "--json", "--limit", "1"]).status == 0)
    }

    @Test func aDamagedEventsRecordNeverChangesAPickOrItsExitCode() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let baseline = try cli.run(["pick", "--json"])
        #expect(baseline.status == 0)
        let label = try object(baseline)["label"] as? String
        let events = cli.dataRoot.appendingPathComponent("state/events.jsonl")
        let good = try String(contentsOf: events, encoding: .utf8)
        let first = try object(try cli.run(["events", "--json"]))["recordId"] as? String

        func check(_ note: String) throws {
            let out = try cli.run(["pick", "--json"])
            #expect(out.status == 0, "\(note)")
            #expect(try object(out)["label"] as? String == label, "\(note)")
            #expect(try cli.run(["refresh"]).status == 0, "\(note) refresh")
            #expect(try cli.run(["status", "--json"]).status == 0, "\(note) status")
        }
        // A torn last line.
        try (good + "{\"seq\":9,\"at\":").write(to: events, atomically: true, encoding: .utf8)
        try check("torn")
        // A broken sequence.
        try (good + good.split(separator: "\n").dropFirst().joined(separator: "\n") + "\n")
            .write(to: events, atomically: true, encoding: .utf8)
        try check("sequence")
        // Garbage.
        try "not json\nnot json\n".write(to: events, atomically: true, encoding: .utf8)
        try check("garbage")
        // Deleted: a new record id starts.
        try FileManager.default.removeItem(at: events)
        try check("deleted")
        let after = try object(try cli.run(["events", "--json"]))
        #expect(after["recordId"] as? String != first)
        #expect(after["recordId"] as? String != nil)
    }

    @Test func aFailingHistoryStepChangesNoExitCode() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let history = cli.dataRoot.appendingPathComponent("state/history")
        try FileManager.default.removeItem(at: history)
        try "x".write(to: history, atomically: true, encoding: .utf8)
        #expect(try cli.run(["pick", "--json"]).status == 0)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(try cli.run(["status", "--json"]).status == 0)
    }

    @Test func statusWithoutJsonPrintsATable() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let out = try cli.run(["status"])
        let text = String(decoding: out.stdout, as: UTF8.self)
        #expect(text.contains("main [login, pool]") && text.contains("week 45.6%"))
        #expect(text.contains("next: main"))
        #expect(!text.contains("main@example.com"))
    }

    @Test func statusBeforeSetupSaysSo() throws {
        let cli = try CLIHome()
        defer { cli.cleanup() }
        let out = try cli.run(["status"])
        #expect(out.status == 1)
        #expect(String(decoding: out.stderr, as: UTF8.self).contains("init"))
    }

    @Test func cachedStartsNoChildProcess() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let before = argsLog(cli).count
        let out = try cli.run(["status", "--cached", "--json"])
        #expect(out.status == 0)
        #expect(argsLog(cli).count == before)
    }

    @Test func plainStatusRunsAuthStatusAndNeverAProbe() throws {
        let token = Account(label: "pool-a", kind: Kind.token, role: Role.pool)
        let cli = try setUp([login(), token])
        defer { cli.cleanup() }
        let out = try cli.run(["status", "--json"])
        #expect(out.status == 0)
        let calls = argsLog(cli)
        #expect(calls.count == 1 && calls[0].hasPrefix("auth status"))
        #expect(!calls.contains { $0.contains("-p") })
        let pool = try #require(try rows(out).first { $0["label"] as? String == "pool-a" })
        #expect((pool["error"] as? [String: Any])?["code"] as? String == "token_missing")
    }

    @Test func aLoggedOutLoginShowsLoginRejectedThenRecovers() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fake("auth.json", "{\"loggedIn\":false}")
        try cli.fake("auth.exit", "1")
        let first = try cli.run(["status", "--json"])
        let error = try #require(try rows(first).first?["error"] as? [String: Any])
        #expect(error["code"] as? String == "login_rejected")

        try cli.fakeFixture("logged_in")
        let refresh = try cli.run(["refresh"])
        #expect(refresh.status == 0)
        let events = try object(try cli.run(["events", "--json"]))
        let list = try #require(events["events"] as? [[String: Any]])
        #expect(
            list.compactMap { $0["type"] as? String } == ["account_added", "error", "recovered"])
        #expect(list[1]["code"] as? String == "login_rejected")
        let cursor = try #require(events["cursor"] as? Int)
        let none = try object(try cli.run(["events", "--json", "--after", "\(cursor)"]))
        #expect((none["events"] as? [Any])?.isEmpty == true)
        #expect(none["gap"] as? Bool == false)
        #expect(none["cursor"] as? Int == cursor)
    }

    @Test func anEndingSoonAccountWithADroppedPlanIsEnded() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fakeFixture("plan_changed")
        var out = try cli.run(["status", "--json"])
        #expect(try rows(out).first?["state"] as? String == "error")
        #expect(try cli.run(["config", "set", "main", "ending-soon", "true"]).status == 0)
        out = try cli.run(["status", "--json"])
        let row = try #require(try rows(out).first)
        #expect(row["state"] as? String == "ended")
        #expect((row["error"] as? [String: Any])?["code"] as? String == "account_ended")
    }

    @Test func aChangedHookRecordShowsTheBannerAfterAPick() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.settings("{\"disableAllHooks\":true}")
        let pick = try cli.run(["pick", "--json"])
        #expect(pick.status == 2)
        let out = try cli.run(["status", "--cached", "--json"])
        let banner = try #require(try object(out)["banner"] as? [String: Any])
        #expect(banner["code"] as? String == "settings_changed")
        #expect((banner["text"] as? String)?.contains("link --accept-source-change") == true)
    }

    // MARK: generatedAt advances after every writing command

    @Test func everyWritingCommandRebuildsTheStatusFile() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["status", "--cached"])
        var last = try generatedAt(cli)
        func advanced(_ args: [String], _ label: String) throws {
            Thread.sleep(forTimeInterval: 1.1)
            let out = try cli.run(args)
            #expect(out.status == 0, "\(label): \(String(decoding: out.stderr, as: UTF8.self))")
            let now = try generatedAt(cli)
            #expect(now > last, "\(label) did not rebuild status.json")
            last = now
        }
        try advanced(["refresh", "--force"], "refresh")
        try advanced(["pick", "--json"], "pick")
        try advanced(["config", "set", "main", "ending-soon", "true"], "config set")
        try advanced(["config", "set-main", "main"], "set-main")
        try advanced(["config", "clear-main", "main"], "clear-main")
        try advanced(["status", "--cached"], "status --cached")
    }

    // MARK: history

    @Test func historyHoldsTheReadingsRefreshTookAndEventsHoldNoPersonalData() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let out = try cli.run(["history", "--json"])
        #expect(out.status == 0)
        let accounts = try rows(out)
        let readings = try #require(accounts.first?["readings"] as? [[String: Any]])
        #expect(readings.count == 1)
        #expect((readings[0]["weekly"] as? [String: Any])?["usedPercent"] as? Double == 45.6)
        let text = String(decoding: out.stdout, as: UTF8.self)
        #expect(!text.contains("accountKey") && !text.contains("main@example.com"))
        let unknown = try cli.run(["history", "--json", "--label", "nobody"])
        #expect(try rows(unknown).isEmpty)
        #expect(try cli.run(["history", "--json", "--limit", "0"]).status == 1)
        #expect(try cli.run(["events", "--json", "--label", "Bad Label"]).status == 1)
    }

    @Test func eventsBeforeAnyRebuildIsAnEmptyUnnamedRecord() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let out = try cli.run(["events", "--json"])
        #expect(out.status == 0)
        let doc = try object(out)
        #expect(doc["recordId"] is NSNull && doc["cursor"] as? Int == 0)
    }

    // MARK: Leaks

    @Test func noCanaryLeaksIntoStatusEventsOrHistory() throws {
        let email =
            "pat." + String((0..<8).map { _ in "abcdef0123456789".randomElement()! }) + "@"
            + "contoso" + ".test"
        let org = UUID().uuidString.lowercased()
        let secret = "sk-" + "ant-" + "oat01-" + String(repeating: "Zq7", count: 14)
        let token = Account(
            label: "pool-a", kind: Kind.token, role: Role.pool, email: "note@example.com")
        let cli = try setUp([login(), token])
        defer { cli.cleanup() }
        try cli.fake(
            "auth.json",
            "{\"loggedIn\":false,\"email\":\"\(email)\",\"orgId\":\"\(org)\",\"detail\":\"\(secret)\"}"
        )
        try cli.fake("auth.exit", "1")
        let context = ToolContext(home: cli.home, ambient: [:])
        let url = try TokenPaths.fileURL(context: context, label: "pool-a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let body = "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(secret)\"}}"
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        var seen = ""
        for args in [
            ["status", "--json"], ["status"], ["status", "--cached"], ["refresh"],
            ["pick", "--json"], ["events", "--json"], ["history", "--json"],
        ] {
            let out = try cli.run(args)
            seen +=
                String(decoding: out.stdout, as: UTF8.self)
                + String(decoding: out.stderr, as: UTF8.self)
        }
        let launchFolder = LaunchFiles.rootURL(context: context).resolvingSymlinksInPath().path
        let tokenPath = url.resolvingSymlinksInPath().path
        for entry in cli.dataEntries() {
            let path = entry.resolvingSymlinksInPath().path
            if path == tokenPath || path.hasPrefix(launchFolder) { continue }
            seen += (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
        }
        for (name, needle) in [("secret", secret), ("org", org)] {
            #expect(!seen.contains(needle), "\(name)")
        }
        #expect(!seen.contains(email))
        #expect(!seen.contains(cli.home.path))
        #expect(cli.expectPrivateModes().isEmpty)
    }

    // MARK: Lock order

    @Test func aReadingThatLandsWhileTheLockIsHeldIsSeenOnceByTwoRebuilds() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        let store = ReadingStore(context: context)
        func reading(_ weekly: Double) -> Reading {
            let at = Date()
            return Reading(
                readAt: at,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: weekly, resetsAt: at.addingTimeInterval(86_400), readAt: at)
                ])
        }
        try store.save(reading(40), label: "main")
        try StatusBuilder.rebuild(context: context)
        let writer = NoFollowWriter(root: context.dataRoot)
        let lock = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: StatusBuilder.lockName, wait: 1))
        let group = DispatchGroup()
        let failures = Counter()
        for _ in 0..<2 {
            group.enter()
            Thread {
                do { try StatusBuilder.rebuild(context: context, lockWait: 20) } catch {
                    failures.add()
                }
                group.leave()
            }.start()
        }
        Thread.sleep(forTimeInterval: 0.5)
        try store.save(reading(98), label: "main")
        lock.release()
        group.wait()
        #expect(failures.value == 0)
        let types = try EventLog(context: context).answer(EventsQuery(), now: Date()).events
            .map(\.type)
        #expect(types == ["account_added", "limited"])
        #expect(!types.contains("limit_cleared"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Foreign and read-back text never reaches the terminal raw.
@Suite struct ForeignTextCLITests {
    let esc: UInt8 = 0x1B
    let bel: UInt8 = 0x07

    func setUp() throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(
            accounts: [
                Account(
                    label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                    expectedPlanTier: "max_20x")
            ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    func plain(_ out: Support.Output) -> Bool {
        !(out.stdout + out.stderr).contains(esc) && !(out.stdout + out.stderr).contains(bel)
    }

    func text(_ out: Support.Output) -> String { String(decoding: out.stdout, as: UTF8.self) }

    @Test func aSessionIdWithControlCharactersIsNotPrintedAndMakesInUseUnknown() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let sessions = cli.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let launch =
            cli.dataRoot.appendingPathComponent(["lau", "nch"].joined()).path
            + "/main/l-0a0b0c0d.json"
        let record: [String: Any] = [
            "pid": Int(getpid()), "sessionId": "\u{1B}]0;x\u{07}", "name": "w\u{1B}[31m",
            "args": ["--settings", launch],
        ]
        try JSONSerialization.data(withJSONObject: record).write(
            to: sessions.appendingPathComponent("1.json"))
        _ = try cli.run(["refresh"])
        let doctor = try cli.run(["doctor"])
        let table = try cli.run(["status"])
        let doc = try cli.run(["status", "--json"])
        for out in [doctor, table, doc] {
            #expect(plain(out))
            #expect(!text(out).contains("]0;x"))
        }
        #expect(text(doctor).contains("in-use is unknown"))
        #expect(text(table).contains("in use unknown"))
        #expect(text(doc).contains("\"unknown\" : true") || text(doc).contains("\"unknown\":true"))
        #expect(!cli.read("state/status.json").contains("]0;x"))
    }

    @Test func aBadKeyInCurrentJsonIsADamagedRecordAndNeverBecomesALabel() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let url = cli.dataRoot.appendingPathComponent("state/current.json")
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var accounts = try #require(root["accounts"] as? [String: Any])
        accounts["\u{1B}]0;x\u{07}"] = accounts["main"]
        accounts["main"] = nil
        root["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        let status = try cli.run(["status"])
        let events = try cli.run(["events"])
        let eventsJson = try cli.run(["events", "--json"])
        for out in [status, events, eventsJson] {
            #expect(plain(out))
            #expect(!text(out).contains("]0;x"))
        }
        #expect(!cli.read("state/events.jsonl").contains("]0;x"))
        #expect(!cli.read("state/current.json").contains("]0;x"))
    }

    @Test func eventsAndHistoryTextNeverCarryAStoredControlCharacter() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let events = cli.dataRoot.appendingPathComponent("state/events.jsonl")
        let stored = try String(contentsOf: events, encoding: .utf8)
        try stored.replacingOccurrences(of: "Account added.", with: "hi\\u001b[31m\\u0007")
            .write(to: events, atomically: true, encoding: .utf8)
        let shown = try cli.run(["events"])
        let shownJson = try cli.run(["events", "--json"])
        #expect(plain(shown) && plain(shownJson))
        #expect(text(shown).contains("hi"))

        let history = cli.dataRoot.appendingPathComponent("state/history/main.jsonl")
        let line = try #require(
            String(contentsOf: history, encoding: .utf8).split(separator: "\n").first)
        let bad = line.replacingOccurrences(
            of: "\"state\":\"ok\"", with: "\"state\":\"\\u001b[2J\"")
        let good = try String(contentsOf: history, encoding: .utf8)
        try (good + bad + "\n").write(to: history, atomically: true, encoding: .utf8)
        let hist = try cli.run(["history"])
        let histJson = try cli.run(["history", "--json"])
        #expect(plain(hist) && plain(histJson))
        #expect(!text(histJson).contains("[2J"))
        #expect(text(hist).contains("main: 1 readings"))
    }

    @Test func aBadRecordIdInTheEventsHeaderIsNeverPrinted() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        _ = try cli.run(["refresh"])
        let url = cli.dataRoot.appendingPathComponent("state/events.jsonl")
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map(String.init)
        var header = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        header["recordId"] = "\u{9B}2J\u{1B}]0;x\u{07}"
        lines[0] = String(
            decoding: try JSONSerialization.data(withJSONObject: header), as: UTF8.self)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let shown = try cli.run(["events"])
        let shownJson = try cli.run(["events", "--json"])
        for out in [shown, shownJson] {
            #expect(plain(out))
            #expect(!text(out).contains("]0;x") && !text(out).contains("\u{9B}"))
        }
        let object = try #require(
            JSONSerialization.jsonObject(with: shownJson.stdout) as? [String: Any])
        #expect(object["recordId"] is NSNull)
    }

    @Test func aBadFingerprintInTheHookRecordIsNeverPrinted() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.settings(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}"#)
        let record = HookRecord(context: ToolContext(home: cli.home, ambient: [:]))
        try record.record(try record.readSettings())
        let url = cli.dataRoot.appendingPathComponent("links.json")
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var folder = try #require(root["defaultFolder"] as? [String: Any])
        var hooks = try #require(folder["hooks"] as? [[String: Any]])
        hooks[0]["fingerprint"] = "\u{1B}]0;x\u{07}" + String(repeating: "a", count: 58)
        folder["hooks"] = hooks
        root["defaultFolder"] = folder
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        let out = try cli.run(["link", "--accept-source-change"], stdin: "nope\n")
        #expect(plain(out))
        #expect(!text(out).contains("]0;x"))
        #expect(text(out).contains("No hook record exists"))
    }
}

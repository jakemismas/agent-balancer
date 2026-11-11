import Foundation
import Testing

@testable import Core

/// Ids and labels read from files the tool does not control never reach a terminal or a status
/// field, and a bad id leaves the pass unclean so nothing a record names is deleted.
@Suite struct ForeignTextTests {
    let leaseId = "l-0a0b0c0d"
    let badId = "\u{1B}]0;x\u{07}"

    func write(_ text: String, to url: URL, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path)
    }

    func launchFile(_ t: TestHome) throws -> URL {
        let url = try LaunchFiles.fileURL(context: t.context, label: "pool-a", leaseId: leaseId)
        try write("{}", to: url, age: 90 * 86_400 / 2)
        return url
    }

    func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func upkeep(_ t: TestHome, _ snapshot: SessionsSnapshot, keepDays: Int) -> Int {
        Upkeep.run(
            context: t.context, snapshot: snapshot, openLeases: [], leaseMinutes: 10,
            keepDays: keepDays, now: Date())
    }

    @Test(arguments: [
        "\u{1B}]0;x\u{07}", "abc\ndef", "abc\n", "abc\r", "bad id", "", "-lead", ".hidden",
        String(repeating: "a", count: 129),
    ])
    func aSessionIdThatIsNotPlainIsUncleanAndNeverStored(_ id: String) throws {
        let t = try TestHome()
        let file = try launchFile(t)
        try write(
            try json([
                "pid": 4242, "sessionId": id, "name": "n",
                "args": ["--settings", file.path],
            ]), to: t.home.appendingPathComponent(".claude/sessions/4242.json"))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        if id.isEmpty {
            // An empty id is the existing record without an id: it names its file, read stays clean.
            #expect(snapshot.live.isEmpty && snapshot.clean)
            return
        }
        #expect(!snapshot.clean && snapshot.live.isEmpty)
        #expect(snapshot.named == [LaunchRef(label: "pool-a", leaseId: leaseId)])
        // Unclean: only keepDays applies, and the file is younger than that.
        #expect(upkeep(t, snapshot, keepDays: 60) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aBadJobIdInASessionEntryIsUnclean() throws {
        let t = try TestHome()
        let file = try launchFile(t)
        try write(
            try json([
                "pid": 4242, "sessionId": "abc-123", "jobId": badId,
                "args": ["--settings", file.path],
            ]), to: t.home.appendingPathComponent(".claude/sessions/4242.json"))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(!snapshot.clean && snapshot.live.isEmpty)
        #expect(upkeep(t, snapshot, keepDays: 60) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aBadIdInAJobRecordIsUncleanAndNeverLinks() throws {
        let t = try TestHome()
        let file = try launchFile(t)
        try write(
            try json(["pid": 4242, "sessionId": "abc-123", "jobId": "j1"]),
            to: t.home.appendingPathComponent(".claude/sessions/4242.json"))
        for key in ["sessionId", "resumeSessionId", "jobId"] {
            try write(
                try json([key: badId, "state": "running", "args": ["--settings", file.path]]),
                to: t.home.appendingPathComponent(".claude/jobs/j1/state.json"))
            let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
            #expect(!snapshot.clean, "\(key)")
            #expect(snapshot.named == [LaunchRef(label: "pool-a", leaseId: leaseId)], "\(key)")
            #expect(upkeep(t, snapshot, keepDays: 60) == 0, "\(key)")
            #expect(FileManager.default.fileExists(atPath: file.path), "\(key)")
        }
    }

    @Test func theRealIdShapeStaysClean() throws {
        let t = try TestHome()
        let id = "0f8fad5bd9cb-469f-a165-70867728950e"
        try write(
            try json(["pid": 4242, "sessionId": id, "jobId": "1a2b3c4d"]),
            to: t.home.appendingPathComponent(".claude/sessions/4242.json"))
        try write(
            try json(["sessionId": id, "resumeSessionId": id, "state": "running"]),
            to: t.home.appendingPathComponent(".claude/jobs/1a2b3c4d/state.json"))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.clean && snapshot.live.map(\.id) == [id])
    }

    @Test func aTamperedSeqIsADamagedLineAndNeverTraps() throws {
        let t = try TestHome()
        let log = EventLog(context: t.context)
        let draft = EventDraft(
            label: "pool-a", accountKey: "k", type: EventType.limited, code: nil, window: "weekly",
            resetsAt: nil, notBefore: nil, text: "Limited.")
        try log.append([draft], now: Date())
        let url = t.context.dataRoot.appendingPathComponent("state/events.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let bad = lines[1].replacingOccurrences(
            of: "\"seq\":1,", with: "\"seq\":\(Int.max),")
        try (lines.joined(separator: "\n") + "\n" + bad + "\n").write(
            to: url, atomically: true, encoding: .utf8)
        try log.append([draft], now: Date())
        #expect(try log.answer(EventsQuery()).events.map(\.seq) == [1, 2])
    }

    @Test func anEventWithABadLabelTypeOrCodeIsNotKept() throws {
        let t = try TestHome()
        let log = EventLog(context: t.context)
        let draft = EventDraft(
            label: "pool-a", accountKey: "k", type: EventType.error, code: "login_rejected",
            window: nil, resetsAt: nil, notBefore: nil, text: "Login rejected.")
        try log.append([draft], now: Date())
        let url = t.context.dataRoot.appendingPathComponent("state/events.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        for (from, to) in [
            ("\"label\":\"pool-a\"", "\"label\":\"\\u001b]0;x\\u0007\""),
            ("\"type\":\"error\"", "\"type\":\"\\u001b[2J\""),
            ("\"code\":\"login_rejected\"", "\"code\":\"\\u001b[2J\""),
        ] {
            try text.replacingOccurrences(of: from, with: to).write(
                to: url, atomically: true, encoding: .utf8)
            #expect(try log.answer(EventsQuery()).events.isEmpty, "\(from)")
        }
    }

    @Test func anIdOfTheJobFolderShapeIsReadAndLinksToItsJob() throws {
        let t = try TestHome()
        let file = try launchFile(t)
        let job = "job_1.a"
        try write(
            try json(["pid": 4242, "sessionId": "s.1_a", "jobId": job]),
            to: t.home.appendingPathComponent(".claude/sessions/4242.json"))
        try write(
            try json(["sessionId": "s.1_a", "state": "running", "args": ["--settings", file.path]]),
            to: t.home.appendingPathComponent(".claude/jobs/\(job)/state.json"))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.clean && snapshot.live.map(\.id) == ["s.1_a"])
        #expect(snapshot.live.first?.refs == [LaunchRef(label: "pool-a", leaseId: leaseId)])
    }

    // MARK: Read back from the tool's own files

    func limitedDraft(_ label: String = "pool-a") -> EventDraft {
        EventDraft(
            label: label, accountKey: "k", type: EventType.limited, code: nil, window: "weekly",
            resetsAt: nil, notBefore: nil, text: "Limited.")
    }

    func eventLines(_ t: TestHome) throws -> [[String: Any]] {
        let url = t.context.dataRoot.appendingPathComponent("state/events.jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func writeEventLines(_ t: TestHome, _ lines: [[String: Any]]) throws {
        let text = try lines.map { try json($0) }.joined(separator: "\n") + "\n"
        try NoFollowWriter(root: t.context.dataRoot).put(
            Data(text.utf8), folders: ["state"], name: "events.jsonl")
    }

    @Test(arguments: ["\u{1B}]0;x\u{07}", "\u{9B}2J", "r-0a0b0c\n", "r-0A0B0C", "r-0a0b0c0d", ""])
    func aHeaderWithABadRecordIdIsADamagedRecordAndTheIdIsNeverReturned(_ id: String) throws {
        let t = try TestHome()
        let log = EventLog(context: t.context)
        try log.append([limitedDraft()], now: Date())
        var lines = try eventLines(t)
        lines[0]["recordId"] = id
        try writeEventLines(t, lines)
        let parsed = try log.read()
        #expect(parsed.recordId == nil && parsed.damaged)
        #expect(try log.answer(EventsQuery()).recordId == nil)
        // The next write sets the record aside and starts one whose id has the written shape.
        try log.append([limitedDraft()], now: Date())
        let fresh = try log.answer(EventsQuery())
        #expect(fresh.events.map(\.seq) == [1])
        #expect(fresh.recordId.map(EventHeader.isValidRecordId) == true)
    }

    @Test(arguments: ["window", "label", "type", "code"])
    func aBadValueInTheMiddleOfTheEventsRecordMarksItDamaged(_ key: String) throws {
        let t = try TestHome()
        let log = EventLog(context: t.context)
        try log.append([limitedDraft(), limitedDraft("pool-b")], now: Date())
        let first = try log.answer(EventsQuery()).recordId
        var lines = try eventLines(t)
        lines[1][key] = key == "window" ? "fable" : "\u{1B}[2J"
        try writeEventLines(t, lines)
        #expect(try log.read().damaged)
        try log.append([limitedDraft()], now: Date())
        let fresh = try log.answer(EventsQuery())
        #expect(fresh.recordId != first && fresh.events.map(\.seq) == [1])
    }

    @Test func aStoredEventTextIsScrubbedWhenReadBack() throws {
        let t = try TestHome()
        let log = EventLog(context: t.context)
        try log.append([limitedDraft()], now: Date())
        let secrets = [
            Canaries.email(), Canaries.oauth(), Canaries.orgId(), Canaries.homePath(),
        ]
        var lines = try eventLines(t)
        lines[1]["text"] = "seen " + secrets.joined(separator: " and ")
        try writeEventLines(t, lines)
        let text = try #require(try log.answer(EventsQuery()).events.first?.text)
        for secret in secrets { #expect(!text.contains(secret)) }
        #expect(text.contains("[email]") && text.contains(Scrubber.redacted))
    }

    func rebuildHome() throws -> TestHome {
        let t = try TestHome()
        let config = Config(accounts: [
            Account(label: "main", kind: Kind.login, role: Role.pool, accountKey: "k-main")
        ])
        try ConfigStore(context: t.context).save(config)
        try HookRecord(context: t.context).record(.empty)
        return t
    }

    /// Each case is a field of the `main` entry and the JSON text put there; `label` moves the
    /// entry to that key instead.
    @Test(arguments: [
        ["state", #""\u001b[2J""#], ["code", #""\u001b[2J""#], ["limitedWindow", #""fable""#],
        ["planTier", #""\u001b]0;x\u0007""#],
        ["planTier", #""\#(String(repeating: "a", count: 60))\u001b[31m""#],
        ["planTier", #""pro plan""#],
        ["expiringNotified", #""2026-12-07\n""#],
        ["authError", #"{"code":"\u001b[2J","text":"x"}"#],
        ["probeError", #"{"code":"nope","text":"x"}"#], ["label", "\u{1B}]0;x\u{07}"],
    ])
    func aCurrentFileWithAValueTheToolNeverWritesStartsOver(_ change: [String]) throws {
        let t = try rebuildHome()
        try StatusBuilder.rebuild(context: t.context)
        let url = t.context.dataRoot.appendingPathComponent("state/current.json")
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var accounts = try #require(root["accounts"] as? [String: Any])
        if change[0] == "label" {
            accounts[change[1]] = accounts.removeValue(forKey: "main")
        } else {
            var entry = try #require(accounts["main"] as? [String: Any])
            entry[change[0]] = try JSONSerialization.jsonObject(
                with: Data(change[1].utf8), options: .fragmentsAllowed)
            accounts["main"] = entry
        }
        root["accounts"] = accounts
        try NoFollowWriter(root: t.context.dataRoot).put(
            try JSONSerialization.data(withJSONObject: root), folders: ["state"],
            name: "current.json")

        let document = try #require(try StatusBuilder.rebuild(context: t.context))
        let log = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("logs/agent-balancer.log"),
            encoding: .utf8)
        #expect(log.contains("started over"))
        // Started over: the account reads as new again and nothing of the old entry is kept.
        let types = try EventLog(context: t.context).answer(EventsQuery()).events.map(\.type)
        #expect(types == [EventType.accountAdded, EventType.accountAdded])
        #expect(document.accounts.first?.planTier == nil)
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(!stored.contains("\\u001b") && !stored.contains("nope"))
    }

    @Test func aRemovedAccountsStoredKeyIsScrubbedBeforeItReachesTheEvents() throws {
        let t = try rebuildHome()
        try StatusBuilder.rebuild(context: t.context)
        let url = t.context.dataRoot.appendingPathComponent("state/current.json")
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var accounts = try #require(root["accounts"] as? [String: Any])
        var gone = try #require(accounts["main"] as? [String: Any])
        let email = Canaries.email()
        gone["accountKey"] = "k-" + email
        accounts["gone"] = gone
        root["accounts"] = accounts
        try NoFollowWriter(root: t.context.dataRoot).put(
            try JSONSerialization.data(withJSONObject: root), folders: ["state"],
            name: "current.json")
        try StatusBuilder.rebuild(context: t.context)
        let events = try EventLog(context: t.context).answer(EventsQuery()).events
        #expect(events.map { "\($0.label):\($0.type)" }.last == "gone:account_removed")
        let raw = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("state/events.jsonl"),
            encoding: .utf8)
        #expect(!raw.contains(email))
    }

    @Test(arguments: [
        "max_20x", "default_claude_max_20x", "\u{1B}]0;x\u{07}", "max_20x\n", "pro plan",
        String(repeating: "a", count: 60) + "\u{1B}[31m", String(repeating: "b", count: 65),
    ])
    func everyPlanTierTheReaderKeepsPassesTheCurrentFileCheck(_ raw: String) throws {
        let status = try #require(
            AuthStatusReader.parse(try json(["loggedIn": true, "planTier": raw])))
        var file = CurrentFile()
        file.accounts["main"] = CurrentEntry(
            accountKey: "k", state: "ok", code: nil, since: Date(), planTier: status.planTier,
            endedByPlan: false)
        #expect(file.isSound)
        // What is stored is what prints: the value is plain or there is none.
        if let tier = status.planTier { #expect(tier == raw && Display.safe(tier) == tier) }
        if raw == "max_20x" || raw == "default_claude_max_20x" { #expect(status.planTier == raw) }
    }

    @Test(arguments: ["\u{1B}[2J", "fable", "Probe", ""])
    func aStoredReadingWithASourceTheToolNeverWritesIsNoReading(_ source: String) throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        let now = Date()
        let window = WindowReading(
            usedPercent: 40, resetsAt: now.addingTimeInterval(86_400), readAt: now)
        try store.save(
            Reading(readAt: now, windows: [WindowName.sevenDay: window]), label: "pool-a")
        #expect(try store.load(label: "pool-a") != nil)
        let url = t.context.dataRoot.appendingPathComponent("state/readings/pool-a.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["source"] = source
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(try store.load(label: "pool-a") == nil)
    }

    @Test(arguments: ["fingerprint", "commandHash"])
    func aHookRecordWithAHashOfAnotherShapeReadsAsMissing(_ key: String) throws {
        let t = try TestHome()
        let facts = try HookRecord.parse(
            Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}"#.utf8))
        let record = HookRecord(context: t.context)
        try record.record(facts)
        #expect(record.status(current: facts) == .matches(added: 0))
        let url = t.context.dataRoot.appendingPathComponent("links.json")
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var folder = try #require(root["defaultFolder"] as? [String: Any])
        var hooks = try #require(folder["hooks"] as? [[String: Any]])
        hooks[0][key] = "\u{1B}]0;x\u{07}" + String(repeating: "a", count: 58)
        folder["hooks"] = hooks
        root["defaultFolder"] = folder
        try NoFollowWriter(root: t.context.dataRoot).put(
            try JSONSerialization.data(withJSONObject: root), folders: [], name: "links.json")
        #expect(record.diff(current: facts) == nil)
        #expect(record.status(current: facts) == .missing)
    }

    @Test func aHookSummaryPrintsNothingRawOrPersonal() {
        let email = Canaries.email()
        let entry = HookEntry(
            event: "Stop", matcher: "m " + email, commandHash: "",
            fingerprint: "\u{1B}]0;x\u{07}abcdef")
        #expect(!entry.summary.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
        #expect(!entry.summary.contains(email))
    }
}

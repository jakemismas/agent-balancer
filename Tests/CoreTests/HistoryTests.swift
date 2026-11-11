import Foundation
import Testing

@testable import Core

/// The events record, the readings history and the transitions that feed them.
@Suite struct HistoryTests {
    let now = StatusBuilderTests.now

    func draft(_ label: String = "pool-a", type: String = EventType.limited) -> EventDraft {
        EventDraft(
            label: label, accountKey: "k-" + label, type: type, code: nil, window: "weekly",
            resetsAt: nil, notBefore: nil, text: "Limited until Wed 6:00 PM.")
    }

    func lines(_ t: TestHome, _ name: String) -> [String] {
        let url = t.context.dataRoot.appendingPathComponent("state/\(name)")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func store(_ t: TestHome) -> EventLog { EventLog(context: t.context) }

    // MARK: Events record

    @Test func eventsAreNumberedFromOneUnderOneRecordId() throws {
        let t = try TestHome()
        let log = store(t)
        try log.append([draft(), draft("pool-b")], now: now)
        try log.append([draft()], now: now.addingTimeInterval(60))
        let answer = try log.answer(EventsQuery(), now: now)
        #expect(answer.events.map(\.seq) == [1, 2, 3])
        #expect(answer.cursor == 3 && answer.oldestSeq == 1 && !answer.gap && !answer.more)
        #expect(answer.recordId?.hasPrefix("r-") == true)
        #expect(lines(t, "events.jsonl").count == 4)
    }

    @Test func anEmptyRecordStillHasAnIdAndCursorZero() throws {
        let t = try TestHome()
        try store(t).append([], now: now)
        let answer = try store(t).answer(EventsQuery(after: 0), now: now)
        #expect(answer.recordId != nil && answer.cursor == 0 && answer.oldestSeq == nil)
        #expect(answer.events.isEmpty && !answer.gap)
    }

    @Test func afterReturnsOnlyNewerEventsAndNothingWhenCaughtUp() throws {
        let t = try TestHome()
        try store(t).append([draft(), draft("pool-b"), draft()], now: now)
        let log = store(t)
        #expect(try log.answer(EventsQuery(after: 1), now: now).events.map(\.seq) == [2, 3])
        let caught = try log.answer(EventsQuery(after: 3), now: now)
        #expect(caught.events.isEmpty && caught.cursor == 3 && !caught.gap)
    }

    @Test func limitCutsTheAnswerAndMovesTheCursorToTheLastReturned() throws {
        let t = try TestHome()
        try store(t).append([draft(), draft(), draft()], now: now)
        let answer = try store(t).answer(EventsQuery(limit: 2), now: now)
        #expect(answer.events.map(\.seq) == [1, 2] && answer.more && answer.cursor == 2)
    }

    @Test func gapIsTrueBelowTheOldestKeptOrAboveTheCursor() throws {
        let t = try TestHome()
        try store(t).append([draft("pool-a"), draft("pool-b"), draft("pool-b")], now: now)
        // Keep only each label's newest line: seq 1 and 3 remain.
        try store(t).prune(retentionDays: 0, now: now.addingTimeInterval(86_400))
        let log = store(t)
        let after = try log.answer(EventsQuery(after: 0), now: now)
        #expect(after.oldestSeq == 1 && !after.gap)
        #expect(after.events.map(\.seq) == [1, 3])
        #expect(try log.answer(EventsQuery(after: 9), now: now).gap)
    }

    @Test func filtersByLabelTypeAndSince() throws {
        let t = try TestHome()
        try store(t).append(
            [draft("pool-a"), draft("pool-b", type: EventType.limitCleared)], now: now)
        let log = store(t)
        #expect(try log.answer(EventsQuery(label: "pool-b"), now: now).events.count == 1)
        #expect(
            try log.answer(EventsQuery(type: "limit_cleared"), now: now).events.first?.label
                == "pool-b")
        #expect(try log.answer(EventsQuery(since: "1h"), now: now).events.count == 2)
        #expect(try log.answer(EventsQuery(since: "2030-01-01T00:00:00Z"), now: now).events.isEmpty)
    }

    @Test func badQueriesAreRefused() throws {
        let t = try TestHome()
        let log = store(t)
        #expect(throws: ToolError.self) { try log.answer(EventsQuery(label: "../x")) }
        #expect(throws: ToolError.self) { try log.answer(EventsQuery(limit: 0)) }
        #expect(throws: ToolError.self) { try log.answer(EventsQuery(limit: 1001)) }
        #expect(throws: ToolError.self) { try log.answer(EventsQuery(since: "soon")) }
        #expect(throws: ToolError.self) { try log.answer(EventsQuery(type: "A b")) }
    }

    @Test func threeHundredEventsPageByTheDefaultLimitOfTwoHundred() throws {
        let t = try TestHome()
        let log = store(t)
        try log.append((0..<300).map { _ in draft() }, now: now)
        let first = try log.answer(EventsQuery(after: 0), now: now)
        #expect(first.events.count == 200 && first.cursor == 200 && first.more)
        let rest = try log.answer(EventsQuery(after: first.cursor), now: now)
        #expect(rest.events.count == 100 && rest.cursor == 300 && !rest.more)
        #expect(rest.events.first?.seq == 201)
    }

    @Test func limitAcceptsOneAndAThousandAndRefusesTheValuesAround() throws {
        let t = try TestHome()
        let log = store(t)
        try log.append([draft(), draft()], now: now)
        #expect(try log.answer(EventsQuery(limit: 1), now: now).events.count == 1)
        #expect(try log.answer(EventsQuery(limit: 1000), now: now).events.count == 2)
        for bad in [-1, 0, 1001, 5000] {
            #expect(throws: ToolError.self) { try log.answer(EventsQuery(limit: bad)) }
        }
    }

    @Test func everyEventTypeIsProducedOrAcceptedAndKept() throws {
        let t = try TestHome()
        let a = account()
        var seen = Set<String>()
        let first = build([a], reading: reading(weekly: 40, at: now))
        seen.formUnion(first.events.map(\.type))
        let limited = build(
            [a], reading: reading(weekly: 97, at: now.addingTimeInterval(600)),
            previous: first.current, at: now.addingTimeInterval(600))
        seen.formUnion(limited.events.map(\.type))
        let cleared = build(
            [a], reading: reading(weekly: 5, at: now.addingTimeInterval(1200)),
            previous: limited.current, at: now.addingTimeInterval(1200))
        seen.formUnion(cleared.events.map(\.type))
        var bad = StatusObservations()
        bad.probe["main"] = ProbeObservation(error: Issue(.checkFailed, .error, "Check failed: x."))
        let failed = build([a], reading: nil, previous: cleared.current, observations: bad)
        seen.formUnion(failed.events.map(\.type))
        var good = StatusObservations()
        good.probe["main"] = ProbeObservation(error: nil)
        let healed = build(
            [a], reading: reading(weekly: 10, at: now), previous: failed.current,
            observations: good)
        seen.formUnion(healed.events.map(\.type))
        var expiring = StatusObservations()
        expiring.auth["main"] = AuthObservation(
            error: nil, planTier: "max_20x", loginExpiresAt: now.addingTimeInterval(86_400),
            signedIn: true)
        let soon = build([a], reading: nil, previous: healed.current, observations: expiring)
        seen.formUnion(soon.events.map(\.type))
        let removed = build([], reading: nil, previous: soon.current)
        seen.formUnion(removed.events.map(\.type))
        // The login command writes token_replaced through the same log.
        let log = store(t)
        try log.append([draft(type: EventType.tokenReplaced)], now: now)
        let kept = try log.answer(EventsQuery(type: EventType.tokenReplaced), now: now)
        #expect(kept.events.map(\.type) == [EventType.tokenReplaced])
        seen.insert(EventType.tokenReplaced)
        #expect(
            seen == [
                "limited", "limit_cleared", "error", "recovered", "login_expiring",
                "account_added", "account_removed", "token_replaced",
            ])
    }

    @Test func aLastLineThatDoesNotParseIsCutOff() throws {
        let t = try TestHome()
        let log = store(t)
        try log.append([draft()], now: now)
        let url = t.context.dataRoot.appendingPathComponent("state/events.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":2,\"at\":".utf8))
        try handle.close()
        let notes = try log.append([draft("pool-b")], now: now)
        #expect(notes.count == 1)
        let answer = try log.answer(EventsQuery(), now: now)
        #expect(answer.events.map(\.seq) == [1, 2])
    }

    @Test func aDamagedRecordIsSetAsideAndAnotherStartsAtOne() throws {
        let t = try TestHome()
        let log = store(t)
        try log.append([draft(), draft()], now: now)
        let first = try log.answer(EventsQuery(), now: now).recordId
        let url = t.context.dataRoot.appendingPathComponent("state/events.jsonl")
        var text = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        text[1] = "garbage"
        try text.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try log.append([draft("pool-b")], now: now)
        let answer = try log.answer(EventsQuery(), now: now)
        #expect(answer.events.map(\.seq) == [1])
        #expect(answer.recordId != first)
        let aside =
            (try? FileManager.default.contentsOfDirectory(
                atPath: t.context.dataRoot.appendingPathComponent("state").path)) ?? []
        #expect(aside.contains { $0.hasPrefix("events-damaged-") })
        // A caller that sees an unknown record id treats it as a gap; the id changed.
        #expect(
            !FileManager.default.fileExists(
                atPath: t.context.dataRoot.appendingPathComponent("state/events.seq").path))
    }

    @Test func pruneDropsOldLinesButKeepsEachLabelsNewest() throws {
        let t = try TestHome()
        let log = store(t)
        try log.append(
            [draft("pool-a"), draft("pool-b")], now: now.addingTimeInterval(-40 * 86_400))
        try log.append([draft("pool-b")], now: now.addingTimeInterval(-10 * 86_400))
        #expect(try log.prune(retentionDays: 35, now: now))
        let seqs = try log.answer(EventsQuery(), now: now).events.map(\.seq)
        #expect(seqs == [1, 3])
    }

    @Test func eventLinesHoldNoEmailPathOrSessionName() throws {
        let t = try TestHome()
        try store(t).append([draft()], now: now)
        let text = lines(t, "events.jsonl").joined()
        #expect(!text.contains("@") && !text.contains("/Users") && !text.contains("session"))
    }

    // MARK: Transitions

    func account(_ key: String = "key-main", label: String = "main") -> Account {
        Account(
            label: label, kind: Kind.login, role: Role.pool, email: "\(label)@example.com",
            expectedPlanTier: "max_20x", accountKey: key)
    }

    func build(
        _ accounts: [Account], reading: Reading?, previous: CurrentFile = CurrentFile(),
        observations: StatusObservations = .init(), at: Date? = nil
    ) -> StatusBuild {
        var readings: [String: Reading] = [:]
        for a in accounts { readings[a.label] = reading }
        if reading == nil { readings = [:] }
        return StatusBuilder.build(
            config: Config(accounts: accounts), readings: readings, previous: previous,
            observations: observations, sessions: .empty, tokens: [:], launchExists: { _ in true },
            now: at ?? now)
    }

    func reading(weekly: Double, at: Date) -> Reading {
        Reading(
            readAt: at,
            windows: [
                WindowName.sevenDay: WindowReading(
                    usedPercent: weekly, resetsAt: at.addingTimeInterval(86_400), readAt: at)
            ])
    }

    @Test func limitedThenLimitCleared() throws {
        let a = account()
        let first = build([a], reading: reading(weekly: 40, at: now))
        #expect(first.events.map(\.type) == ["account_added"])
        let second = build(
            [a], reading: reading(weekly: 97, at: now.addingTimeInterval(600)),
            previous: first.current, at: now.addingTimeInterval(600))
        #expect(second.events.map(\.type) == ["limited"])
        #expect(second.events.first?.window == "weekly")
        #expect(second.events.first?.notBefore == now)
        let still = build(
            [a], reading: reading(weekly: 98, at: now.addingTimeInterval(1200)),
            previous: second.current, at: now.addingTimeInterval(1200))
        #expect(still.events.isEmpty)
        #expect(still.document.accounts[0].limited?.since == now.addingTimeInterval(600))
        let cleared = build(
            [a], reading: reading(weekly: 5, at: now.addingTimeInterval(1800)),
            previous: still.current, at: now.addingTimeInterval(1800))
        #expect(cleared.events.map(\.type) == ["limit_cleared"])
        #expect(cleared.events.first?.window == "weekly")
    }

    @Test func rejectedThenRecoveredByASuccessfulProbe() throws {
        let a = account()
        var obs = StatusObservations()
        obs.auth["main"] = AuthObservation(
            error: Issue(.loginRejected, .error, "Login rejected."), planTier: nil,
            loginExpiresAt: nil, signedIn: false)
        let rejected = build([a], reading: nil, observations: obs)
        #expect(rejected.events.map(\.type) == ["account_added", "error"])
        #expect(rejected.events.last?.code == "login_rejected")
        // A cached rebuild carries the error and writes nothing new.
        let cached = build([a], reading: nil, previous: rejected.current)
        #expect(cached.document.accounts[0].error?.code == "login_rejected")
        #expect(cached.events.isEmpty)
        var good = StatusObservations()
        good.probe["main"] = ProbeObservation(error: nil)
        let healed = build(
            [a], reading: reading(weekly: 10, at: now), previous: cached.current,
            observations: good)
        #expect(healed.events.map(\.type) == ["recovered"])
        #expect(healed.events.first?.text.contains("login_rejected") == true)
        #expect(healed.document.accounts[0].state == "ok")
    }

    @Test func aRepeatedErrorWritesNoSecondEvent() throws {
        let a = account()
        var obs = StatusObservations()
        obs.probe["main"] = ProbeObservation(error: Issue(.checkFailed, .error, "Check failed: x."))
        let one = build([a], reading: nil, observations: obs)
        let two = build([a], reading: nil, previous: one.current, observations: obs)
        #expect(two.events.isEmpty)
        #expect(two.document.accounts[0].stateSince == one.document.accounts[0].stateSince)
    }

    @Test func aPruneThenAnUnchangedRebuildAppendsNothingAndKeepsStateSince() throws {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        try StatusBuilder.rebuild(context: context, now: now)
        let log = EventLog(context: context)
        let before = try log.answer(EventsQuery(), now: now).events
        let since = try StatusBuilder.rebuild(context: context, now: now)?.accounts[0].stateSince
        let later = now.addingTimeInterval(40 * 86_400)
        // The first rebuild after a day prunes; the second sees no change.
        let afterPrune = try StatusBuilder.rebuild(context: context, now: later)
        let again = try StatusBuilder.rebuild(context: context, now: later.addingTimeInterval(60))
        let after = try log.answer(EventsQuery(), now: later).events
        #expect(after.map(\.seq) == before.map(\.seq))
        #expect(afterPrune?.accounts[0].stateSince == since)
        #expect(again?.accounts[0].stateSince == since)
    }

    @Test func aProbeThatDidNotRunLeavesTheProbeUnobserved() throws {
        let r = reading(weekly: 10, at: now)
        var obs = StatusObservations()
        obs.add([
            AccountRefresh(label: "a", status: .fresh(r), fable: .notRun),
            AccountRefresh(label: "b", status: .usedStored(r), fable: .notRun),
            AccountRefresh(label: "c", status: .probed(r), fable: .notRun),
        ])
        #expect(obs.probe["a"] == nil && obs.probe["b"] == nil)
        #expect(obs.probe["c"] != nil && obs.probe["c"]?.error == nil)
    }

    @Test func removedAndAddedAccountsWriteEvents() throws {
        let a = account()
        let one = build([a], reading: nil)
        let b = account("key-b", label: "pool-b")
        let two = build([b], reading: nil, previous: one.current)
        #expect(two.events.map(\.type) == ["account_removed", "account_added"])
        #expect(two.events.map(\.label) == ["main", "pool-b"])
        #expect(two.current.accounts["main"] == nil)
    }

    @Test func aRenamedLabelKeepsItsKeyAndWritesNoEvent() throws {
        let one = build([account()], reading: nil)
        let two = build([account(label: "work")], reading: nil, previous: one.current)
        #expect(two.events.isEmpty)
        #expect(two.current.accounts["work"] != nil)
    }

    @Test func aLabelRemovedAndAddedForAnotherAccountIsNotMixedWithTheOld() throws {
        let one = build([account("key-old")], reading: reading(weekly: 99, at: now))
        let two = build([account("key-new")], reading: nil, previous: one.current)
        #expect(two.events.map(\.type) == ["account_removed", "account_added"])
        #expect(two.document.accounts[0].state == "ok")
    }

    @Test func loginExpiringIsWrittenOncePerExpiryDate() throws {
        let a = account()
        var obs = StatusObservations()
        obs.auth["main"] = AuthObservation(
            error: nil, planTier: "max_20x", loginExpiresAt: now.addingTimeInterval(3 * 86_400),
            signedIn: true)
        let first = build([a], reading: nil, observations: obs)
        #expect(first.events.map(\.type) == ["account_added", "login_expiring"])
        let again = build([a], reading: nil, previous: first.current, observations: obs)
        #expect(again.events.isEmpty)
    }

    // MARK: Readings history

    @Test func aLineIsAppendedOnlyWhenSomethingChangedAndNotMoreThanEveryFifteenMinutes() throws {
        let a = account()
        let first = build([a], reading: reading(weekly: 10, at: now))
        #expect(first.history.count == 1)
        let same = build(
            [a], reading: reading(weekly: 10, at: now), previous: first.current,
            at: now.addingTimeInterval(1_000))
        #expect(same.history.isEmpty)
        let soon = build(
            [a], reading: reading(weekly: 11, at: now.addingTimeInterval(300)),
            previous: first.current, at: now.addingTimeInterval(300))
        #expect(soon.history.isEmpty)
        let later = build(
            [a], reading: reading(weekly: 11, at: now.addingTimeInterval(1_000)),
            previous: first.current, at: now.addingTimeInterval(1_000))
        #expect(later.history.count == 1)
        // A change of state is written at once.
        let limited = build(
            [a], reading: reading(weekly: 99, at: now.addingTimeInterval(100)),
            previous: first.current, at: now.addingTimeInterval(100))
        #expect(limited.history.count == 1 && limited.history[0].line.state == "limited")
    }

    @Test func retentionZeroKeepsNoHistoryLine() throws {
        var config = Config(accounts: [account()])
        config.history.retentionDays = 0
        let built = StatusBuilder.build(
            config: config, readings: ["main": reading(weekly: 10, at: now)],
            previous: CurrentFile(), observations: .init(), sessions: .empty, tokens: [:],
            launchExists: { _ in true }, now: now)
        #expect(built.history.isEmpty)
    }

    @Test func historyFilesAppendReadAndPrune() throws {
        let t = try TestHome()
        let h = ReadingHistory(context: t.context)
        let a = account()
        let old = StatusBuilder.historyLine(
            account: a, reading: reading(weekly: 10, at: now.addingTimeInterval(-40 * 86_400)),
            state: "ok")
        let fresh = StatusBuilder.historyLine(
            account: a, reading: reading(weekly: 20, at: now.addingTimeInterval(-3_600)),
            state: "ok")
        try h.append(old, label: "main")
        try h.append(fresh, label: "main")
        #expect(try h.read(label: "main").count == 2)
        try h.prune(retentionDays: 35, now: now)
        #expect(try h.read(label: "main") == [fresh])
        let answer = try h.answer(
            HistoryQuery(label: "main", since: "24h"), config: Config(accounts: [a]), now: now)
        #expect(answer.accounts.first?.readings.count == 1)
    }

    @Test func historyCutsABrokenLastLineAndKeepsNoAccountKeyInTheAnswer() throws {
        let t = try TestHome()
        let h = ReadingHistory(context: t.context)
        let a = account()
        let line = StatusBuilder.historyLine(
            account: a, reading: reading(weekly: 20, at: now.addingTimeInterval(-60)), state: "ok")
        try h.append(line, label: "main")
        let url = t.context.dataRoot.appendingPathComponent("state/history/main.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"at\":".utf8))
        try handle.close()
        #expect(try h.append(line, label: "main"))
        #expect(try h.read(label: "main").count == 2)
        let answer = try h.answer(HistoryQuery(), config: Config(accounts: [a]), now: now)
        let text = String(decoding: try StatusDocument.encoder().encode(answer), as: UTF8.self)
        #expect(!text.contains("accountKey") && !text.contains("key-main"))
        #expect(throws: ToolError.self) { try h.answer(HistoryQuery(limit: 0), config: nil) }
    }

    // MARK: Golden files for events and history

    func goldenAnswer(_ name: String, _ value: some Encodable) throws {
        let data = try StatusDocument.encoder().encode(value) + Data([0x0A])
        let url = StatusBuilderTests.goldenFolder.appendingPathComponent("\(name).json")
        guard let saved = FileManager.default.contents(atPath: url.path) else {
            try data.write(to: url)
            Issue.record("Recorded the golden file \(name).json. Review it and run again.")
            return
        }
        #expect(
            String(decoding: saved, as: UTF8.self) == String(decoding: data, as: UTF8.self),
            "golden \(name).json")
    }

    func sampleLog(_ t: TestHome) throws -> EventLog {
        let log = store(t)
        try log.append(
            [
                EventDraft(
                    label: "pool-a", accountKey: "k-pool-a", type: EventType.limited, code: nil,
                    window: "weekly", resetsAt: now.addingTimeInterval(86_400), notBefore: now,
                    text: "Limited until Tue 9:00 PM."),
                draft("pool-b", type: EventType.error),
            ], now: now)
        try log.append(
            [draft("pool-a", type: EventType.limitCleared)], now: now.addingTimeInterval(600))
        return log
    }

    @Test func eventsAnswersMatchTheGoldenFiles() throws {
        let t = try TestHome()
        let log = try sampleLog(t)
        var all = try log.answer(EventsQuery(), now: now)
        all.recordId = "r-golden"
        try goldenAnswer("events-all", all)
        var after = try log.answer(EventsQuery(after: 1, label: "pool-a", limit: 5), now: now)
        after.recordId = "r-golden"
        try goldenAnswer("events-after-label", after)
        var empty = try store(try TestHome()).answer(EventsQuery(), now: now)
        empty.recordId = "r-golden"
        try goldenAnswer("events-empty", empty)
    }

    @Test func historyAnswersMatchTheGoldenFiles() throws {
        let t = try TestHome()
        let h = ReadingHistory(context: t.context)
        let a = account()
        for (weekly, ago) in [(10.0, 7_200.0), (40, 3_600), (97, 600)] {
            try h.append(
                StatusBuilder.historyLine(
                    account: a, reading: reading(weekly: weekly, at: now.addingTimeInterval(-ago)),
                    state: weekly > 95 ? "limited" : "ok"), label: "main")
        }
        let config = Config(accounts: [a])
        try goldenAnswer("history-all", try h.answer(HistoryQuery(), config: config, now: now))
        try goldenAnswer(
            "history-since-limit",
            try h.answer(
                HistoryQuery(label: "main", since: "30m", limit: 1), config: config, now: now))
        try goldenAnswer(
            "history-no-readings",
            try ReadingHistory(context: try TestHome().context).answer(
                HistoryQuery(), config: config, now: now))
    }

    // MARK: Racing rebuilds

    @Test func seqRisesByOnePerEventWhenRebuildsRaceForTheLock() throws {
        let t = try TestHome()
        let context = t.context
        let config = Config(accounts: [
            account("k1", label: "main"),
            Account(label: "spare", kind: Kind.token, role: Role.pool, accountKey: "k2"),
        ])
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        let group = DispatchGroup()
        let failures = Counter()
        for _ in 0..<6 {
            group.enter()
            Thread {
                do { try StatusBuilder.rebuild(context: context, lockWait: 20) } catch {
                    failures.add()
                }
                group.leave()
            }.start()
        }
        group.wait()
        withExtendedLifetime(t) {}
        #expect(failures.value == 0)
        let events = try EventLog(context: context).answer(EventsQuery(), now: Date()).events
        #expect(events.map(\.seq) == [1, 2, 3])
        #expect(
            events.map { "\($0.label):\($0.type)" } == [
                "main:account_added", "spare:account_added", "spare:error",
            ])
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

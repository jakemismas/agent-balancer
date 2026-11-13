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
        // A stored reading, so the rebuild 40 days on has a time to prune from.
        try ReadingStore(context: context).save(reading(weekly: 10, at: now), label: "main")
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
            AccountRefresh(label: "d", status: .notStarted, fable: .notRun),
        ])
        #expect(obs.probe["a"] == nil && obs.probe["b"] == nil && obs.probe["d"] == nil)
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
        let next = StatusBuilder.historyLine(
            account: a, reading: reading(weekly: 21, at: now.addingTimeInterval(-30)), state: "ok")
        #expect(try h.append(next, label: "main") == HistoryAppend(wrote: true, dropped: 1))
        #expect(try h.read(label: "main") == [line, next])
        let answer = try h.answer(HistoryQuery(), config: Config(accounts: [a]), now: now)
        let text = String(decoding: try StatusDocument.encoder().encode(answer), as: UTF8.self)
        #expect(!text.contains("accountKey") && !text.contains("key-main"))
        #expect(throws: ToolError.self) { try h.answer(HistoryQuery(limit: 0), config: nil) }
    }

    func line(_ weekly: Double, ago: TimeInterval) -> HistoryLine {
        StatusBuilder.historyLine(
            account: account(), reading: reading(weekly: weekly, at: now.addingTimeInterval(-ago)),
            state: "ok")
    }

    func appendRaw(_ t: TestHome, _ label: String, _ text: String) throws {
        let url = t.context.dataRoot.appendingPathComponent("state/history/\(label).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func aHistoryRewriteCountsTheLinesThatDoNotParseInsteadOfDroppingThemSilently() throws {
        let t = try TestHome()
        let h = ReadingHistory(context: t.context)
        func text(_ line: HistoryLine) throws -> String {
            String(decoding: try EventLog.encoder().encode(line), as: UTF8.self) + "\n"
        }
        // Cutting a last line rewrites the file without every line that does not parse.
        try h.append(line(10, ago: 7_200), label: "main")
        try appendRaw(
            t, "main", "corrupt-marker in the middle\n" + text(line(20, ago: 3_600)) + "{\"at\":")
        #expect(
            try h.append(line(30, ago: 60), label: "main")
                == HistoryAppend(wrote: true, dropped: 2))
        #expect(try h.read(label: "main").map { $0.weekly?.usedPercent } == [10, 20, 30])

        // A prune that rewrites the file counts the same way, per label.
        try h.append(line(5, ago: 40 * 86_400), label: "spare")
        try appendRaw(t, "spare", "corrupt-marker again\n" + text(line(6, ago: 60)))
        var counts: [String: Int] = [:]
        try h.prune(retentionDays: 35, now: now) { label, count in counts[label] = count }
        #expect(counts == ["spare": 1])
        #expect(try h.read(label: "spare").map { $0.weekly?.usedPercent } == [6])
    }

    @Test func theRebuildLogsHowManyHistoryLinesItDroppedAndNeverTheirText() throws {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        try ReadingStore(context: context).save(reading(weekly: 20, at: now), label: "main")
        let h = ReadingHistory(context: context)
        try h.append(line(10, ago: 3_600), label: "main")
        try appendRaw(t, "main", "corrupt-marker text\n{\"at\":")
        try StatusBuilder.rebuild(context: context, now: now)
        let log = try String(
            contentsOf: context.dataRoot.appendingPathComponent("logs/agent-balancer.log"),
            encoding: .utf8)
        #expect(log.contains("dropped 2 lines that did not parse from the history of main"))
        #expect(!log.contains("corrupt-marker"))
        #expect(try h.read(label: "main").count == 2)
    }

    @Test func aRepeatedAppendWritesTheLineOnce() throws {
        let t = try TestHome()
        let h = ReadingHistory(context: t.context)
        let first = line(20, ago: 600)
        #expect(try h.append(first, label: "main").wrote)
        #expect(try h.append(first, label: "main") == HistoryAppend(wrote: false, dropped: 0))
        // The same numbers read again later carry nothing new either.
        var later = first
        later.at = now
        #expect(try !h.append(later, label: "main").wrote)
        // A changed number is written, and so is the same reading for another account.
        var changed = first
        changed.weekly?.usedPercent = 21
        #expect(try h.append(changed, label: "main").wrote)
        var other = changed
        other.accountKey = "key-other"
        #expect(try h.append(other, label: "main").wrote)
        #expect(try h.read(label: "main") == [first, changed, other])
        // A repeat that comes with a cut last line is not written twice either.
        try appendRaw(t, "main", "{\"at\":")
        #expect(try h.append(other, label: "main") == HistoryAppend(wrote: false, dropped: 1))
        #expect(try h.read(label: "main") == [first, changed, other])
    }

    @Test func pruningKeepsRecentLinesWhenTheClockMovesForwardOrBackward() throws {
        let old = line(10, ago: 50 * 86_400)
        let days = line(20, ago: 2 * 86_400)
        let hour = line(30, ago: 3_600)
        let cases: [(String, Date, [HistoryLine])] = [
            // Ahead of the newest reading: retention counts back from that reading, not the clock.
            ("forward", now.addingTimeInterval(400 * 86_400), [days, hour]),
            // Behind every line: nothing newer than the clock's own cutoff goes.
            ("backward", now.addingTimeInterval(-400 * 86_400), [old, days, hour]),
        ]
        for (direction, moved, kept) in cases {
            let t = try TestHome()
            let context = t.context
            try ConfigStore(context: context).save(Config(accounts: [account()]))
            try HookRecord(context: context).record(.empty)
            // The stored reading is the newest line's, so the rebuild appends nothing.
            try ReadingStore(context: context).save(
                reading(weekly: 30, at: now.addingTimeInterval(-3_600)), label: "main")
            let h = ReadingHistory(context: context)
            for item in [old, days, hour] { try h.append(item, label: "main") }
            try StatusBuilder.rebuild(context: context, now: moved)
            #expect(try h.read(label: "main") == kept, "clock moved \(direction)")
        }
    }

    @Test func aRemovedLabelsHistoryAgesOutOnceTheReadingsAreMoreThanTheRetentionNewer() throws {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        // A label no longer in the config: no line will ever be added to its file.
        let gone = account("key-gone", label: "gone")
        let h = ReadingHistory(context: context)
        for ago in [20.0, 10, 2] {
            let at = now.addingTimeInterval(-ago * 86_400)
            try h.append(
                StatusBuilder.historyLine(
                    account: gone, reading: reading(weekly: 50 - ago, at: at), state: "ok"),
                label: "gone")
        }
        let last = now.addingTimeInterval(-2 * 86_400)
        let store = ReadingStore(context: context)
        let first = last.addingTimeInterval(35 * 86_400 - 3_600)
        try store.save(reading(weekly: 10, at: first), label: "main")
        try StatusBuilder.rebuild(context: context, now: first)
        #expect(try h.read(label: "gone").map(\.at) == [last])
        let second = first.addingTimeInterval(86_400)
        try store.save(reading(weekly: 11, at: second), label: "main")
        try StatusBuilder.rebuild(context: context, now: second)
        #expect(try h.read(label: "gone").isEmpty)
    }

    @Test func theHistoryOfAnAccountWhoseProbesKeepFailingAgesOutTheSameWay() throws {
        let t = try TestHome()
        let context = t.context
        let spare = Account(label: "spare", kind: Kind.token, role: Role.pool, accountKey: "k2")
        try ConfigStore(context: context).save(Config(accounts: [account(), spare]))
        try HookRecord(context: context).record(.empty)
        let store = ReadingStore(context: context)
        // The last reading of spare; every probe of it fails from then on.
        let stuck = now.addingTimeInterval(-86_400)
        try store.save(reading(weekly: 30, at: stuck), label: "spare")
        try store.save(reading(weekly: 20, at: now), label: "main")
        var failing = StatusObservations()
        failing.probe["spare"] = ProbeObservation(
            error: Issue(.checkFailed, .error, "Check failed: x."))
        try StatusBuilder.rebuild(context: context, observations: failing, now: now)
        let h = ReadingHistory(context: context)
        #expect(try h.read(label: "spare").map(\.at) == [stuck])
        let later = now.addingTimeInterval(40 * 86_400)
        try store.save(reading(weekly: 21, at: later), label: "main")
        try StatusBuilder.rebuild(context: context, observations: failing, now: later)
        #expect(try h.read(label: "spare").isEmpty)
        #expect(try h.read(label: "main").map(\.at) == [later])
    }

    @Test func aReadingTakenUnderAClockThatRunsAheadMovesTheCutoffByAsMuch() throws {
        let t = try TestHome()
        let context = t.context
        var config = Config(accounts: [account()])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        let h = ReadingHistory(context: context)
        for ago in [30.0, 28, 1] { try h.append(line(40 - ago, ago: ago * 86_400), label: "main") }
        let store = ReadingStore(context: context)
        try store.save(reading(weekly: 39, at: now.addingTimeInterval(-86_400)), label: "main")
        // The clock runs 6 days ahead. The service's weekly reset is 6.5 days after the real time.
        let ahead = now.addingTimeInterval(6 * 86_400)
        let weekly = Int(now.addingTimeInterval(6.5 * 86_400).timeIntervalSince1970)
        let five = Int(now.addingTimeInterval(3_600).timeIntervalSince1970)
        func reply(fiveHour: Bool) -> String {
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
                + (fiveHour ? "\"five_hour\":{\"utilization\":0.1,\"resetsAt\":\(five)}," : "")
                + "\"seven_day\":{\"utilization\":0.45,\"resetsAt\":\(weekly)}}}}"
        }
        // A five_hour reset time bounds the offset at 5 hours 5 minutes, so this reply is refused.
        if case .reading = ProbeReader.parse(reply(fiveHour: true), readAt: ahead) {
            Issue.record("a reply with a five_hour reset was read 6 days ahead")
        }
        // A weekly-only reply is read, dated 6 days ahead.
        guard case .reading(let r) = ProbeReader.parse(reply(fiveHour: false), readAt: ahead)
        else {
            Issue.record("the weekly-only reply was refused")
            return
        }
        try store.record(r, label: "main", callsHook: false, fable: config.fable, now: ahead)
        try StatusBuilder.rebuild(context: context, now: ahead)
        // The cutoff is 35 days before the reading, 29 days before the real time.
        let ages = try h.read(label: "main").map { now.timeIntervalSince($0.at) / 86_400 }
        #expect(ages == [28, 1, -6])
    }

    @Test func aRebuildPrunesFromTheNewestReadingAndStillPrunesWhenTheClockMovedBack() throws {
        // Forward: events the rebuild just wrote under the moved clock do not set the cutoff.
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        try ReadingStore(context: context).save(reading(weekly: 20, at: now), label: "main")
        let log = EventLog(context: context)
        for (type, ago) in [
            (EventType.limited, 3.0), (EventType.limitCleared, 2), (EventType.limited, 1),
        ] {
            try log.append([draft("main", type: type)], now: now.addingTimeInterval(-ago * 86_400))
        }
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(400 * 86_400))
        let events = try log.answer(EventsQuery(), now: now).events
        #expect(events.prefix(3).map(\.seq) == [1, 2, 3])

        // Backward: a prune time ahead of the clock does not stop pruning, and the prune keeps
        // every line newer than the clock's own cutoff.
        let u = try TestHome()
        let back = u.context
        try ConfigStore(context: back).save(Config(accounts: [account()]))
        try HookRecord(context: back).record(.empty)
        try ReadingStore(context: back).save(reading(weekly: 20, at: now), label: "main")
        try StatusBuilder.rebuild(context: back, now: now)
        let h = ReadingHistory(context: back)
        try h.append(line(5, ago: 200 * 86_400), label: "main")
        try StatusBuilder.rebuild(context: back, now: now.addingTimeInterval(-100 * 86_400))
        let ages = try h.read(label: "main").map { now.timeIntervalSince($0.at) }
        #expect(!ages.contains(200 * 86_400))
        #expect(ages.contains(0))
    }

    @Test func aRerunAfterAFailedEventsStepWritesNoHistoryLineTwice() throws {
        let t = try TestHome()
        let context = t.context
        let accounts = [
            account("k1", label: "main"),
            Account(label: "spare", kind: Kind.token, role: Role.pool, accountKey: "k2"),
        ]
        try ConfigStore(context: context).save(Config(accounts: accounts))
        try HookRecord(context: context).record(.empty)
        let store = ReadingStore(context: context)
        for label in ["main", "spare"] {
            try store.save(reading(weekly: 20, at: now), label: label)
        }
        // A folder where the events file goes makes the events step fail.
        try NoFollowWriter(root: context.dataRoot).prepare(folders: ["state"])
        let state = context.dataRoot.appendingPathComponent("state")
        let blocker = state.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(
            at: blocker, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try StatusBuilder.rebuild(context: context, now: now)
        let h = ReadingHistory(context: context)
        #expect(try h.read(label: "main").count == 1)
        #expect(try h.read(label: "spare").count == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: state.appendingPathComponent("current.json").path))

        // The rerun finds the same changes and saves the events, and writes no line twice.
        try FileManager.default.removeItem(at: blocker)
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(60))
        #expect(try h.read(label: "main").count == 1)
        #expect(try h.read(label: "spare").count == 1)
        let events = try EventLog(context: context).answer(EventsQuery(), now: now).events
        #expect(
            events.map { "\($0.label):\($0.type)" } == [
                "main:account_added", "spare:account_added", "spare:error",
            ])

        // A real change after that still gets its own line.
        try store.save(reading(weekly: 40, at: now.addingTimeInterval(1_200)), label: "main")
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(1_200))
        #expect(try h.read(label: "main").count == 2)
        #expect(try h.read(label: "spare").count == 1)
    }

    @Test func aRebuildThatCannotSaveTheCurrentFileWritesItsEventsAgainInTheDocumentedShape()
        throws
    {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        let store = ReadingStore(context: context)
        try store.save(reading(weekly: 40, at: now), label: "main")
        try StatusBuilder.rebuild(context: context, now: now)
        // The account reaches its limit. A state folder that takes no new file still lets the
        // events and history appends through, and refuses the new current.json.
        let limitedAt = now.addingTimeInterval(600)
        try store.save(reading(weekly: 97, at: limitedAt), label: "main")
        let state = context.dataRoot.appendingPathComponent("state").path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state)
        }
        #expect(throws: ToolError.self) {
            try StatusBuilder.rebuild(context: context, now: limitedAt)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state)
        // The rerun compares with the old current.json and writes the same change again.
        try StatusBuilder.rebuild(context: context, now: limitedAt.addingTimeInterval(60))
        let log = EventLog(context: context)
        let events = try log.answer(EventsQuery(), now: now).events
        #expect(events.map(\.type) == ["account_added", "limited", "limited"])
        guard events.count == 3 else { return }
        let (first, again) = (events[1], events[2])
        #expect(first.window == "weekly" && first.notBefore == now && first.resetsAt != nil)
        func shape(_ e: EventOut) -> String {
            "\(e.label)|\(e.type)|\(e.code ?? "-")|\(e.window ?? "-")|"
                + "\(e.resetsAt.map { "\($0)" } ?? "-")|\(e.notBefore.map { "\($0)" } ?? "-")"
        }
        #expect(again.seq > first.seq)
        #expect(shape(again) == shape(first))
        // Each copy carries the time of the rebuild that wrote it.
        #expect(first.at == limitedAt && again.at == limitedAt.addingTimeInterval(60))
        // The history line was written once, and once current.json is saved nothing repeats.
        #expect(try ReadingHistory(context: context).read(label: "main").count == 2)
        try StatusBuilder.rebuild(context: context, now: limitedAt.addingTimeInterval(120))
        #expect(try log.answer(EventsQuery(), now: now).events.count == 3)
    }

    @Test func aLineEqualToAnEarlierLineButNotTheLastOneIsWritten() throws {
        let t = try TestHome()
        let h = ReadingHistory(context: t.context)
        let a = line(20, ago: 600)
        var b = a
        b.accountKey = "key-other"
        var limited = a
        limited.state = "limited"
        let steps: [(HistoryLine, Bool)] = [
            (a, true), (b, true), (a, true), (a, false), (limited, true), (a, true),
        ]
        for (index, (item, wrote)) in steps.enumerated() {
            #expect(try h.append(item, label: "main").wrote == wrote, "append \(index)")
        }
        #expect(try h.read(label: "main") == [a, b, a, limited, a])
    }

    @Test func aPruneCountsAnEventsLastLineThatDoesNotParse() throws {
        let t = try TestHome()
        let log = store(t)
        try log.append([draft(), draft()], now: now.addingTimeInterval(-40 * 86_400))
        let url = t.context.dataRoot.appendingPathComponent("state/events.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":3,".utf8))
        try handle.close()
        var counted: [Int] = []
        #expect(try log.prune(retentionDays: 35, now: now) { counted.append($0) })
        #expect(counted == [1])
        #expect(try log.answer(EventsQuery(), now: now).events.map(\.seq) == [2])
    }

    @Test func theRebuildLogsHowManyUnreadableLinesAPruneDroppedAndNeverTheirText() throws {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        try ReadingStore(context: context).save(reading(weekly: 20, at: now), label: "main")
        try StatusBuilder.rebuild(context: context, now: now)
        // An unreadable line in the middle of the history and an old line after it.
        func text(_ line: HistoryLine) throws -> String {
            String(decoding: try EventLog.encoder().encode(line), as: UTF8.self) + "\n"
        }
        try appendRaw(t, "main", "corrupt-marker in history\n" + text(line(5, ago: 40 * 86_400)))
        // Old events of another label and an unreadable last events line.
        let log = EventLog(context: context)
        try log.append(
            [draft("gone"), draft("gone")], now: now.addingTimeInterval(-40 * 86_400))
        let url = context.dataRoot.appendingPathComponent("state/events.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"seq\":4,\"corrupt-marker\":".utf8))
        try handle.close()
        // Nothing changed, so only the prune of the next day rewrites the two files.
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(86_400 + 60))
        let logged = try String(
            contentsOf: context.dataRoot.appendingPathComponent("logs/agent-balancer.log"),
            encoding: .utf8)
        #expect(logged.contains("dropped 1 line that did not parse from the history of main"))
        #expect(logged.contains("dropped 1 line that did not parse from the events record"))
        #expect(!logged.contains("corrupt-marker"))
        #expect(try ReadingHistory(context: context).read(label: "main").count == 1)
        #expect(try log.answer(EventsQuery(), now: now).events.map(\.seq) == [1, 3])
    }

    @Test func aPruneTimeLessThanAMinuteAheadOfTheClockIsNotDueYet() throws {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        try ReadingStore(context: context).save(reading(weekly: 20, at: now), label: "main")
        try StatusBuilder.rebuild(context: context, now: now)
        let h = ReadingHistory(context: context)
        try h.append(line(5, ago: 40 * 86_400), label: "main")
        // A rebuild that read its clock just before the one that pruned does not prune again.
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(-30))
        #expect(try h.read(label: "main").count == 2)
        // More than a minute behind, the clock moved back, and the prune is due.
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(-90))
        #expect(try h.read(label: "main").count == 1)
    }

    @Test(arguments: [
        "no reading file", "a reading file that does not decode", "a reading",
        "no reading file and 1 day of retention",
    ])
    func aClockMovedForwardPrunesOnlyFromAStoredReading(_ stored: String) throws {
        let t = try TestHome()
        let context = t.context
        var config = Config(accounts: [account()])
        // The shortest retention above 0 waits for a stored reading too.
        if stored.hasSuffix("1 day of retention") { config.history.retentionDays = 1 }
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        let h = ReadingHistory(context: context)
        let log = EventLog(context: context)
        let ages: [TimeInterval] = [50 * 86_400, 10 * 86_400, 2 * 86_400, 3_600]
        for (index, ago) in ages.enumerated() {
            try h.append(line(Double(10 + index), ago: ago), label: "main")
            try log.append([draft("main")], now: now.addingTimeInterval(-ago))
        }
        if stored == "a reading" {
            try ReadingStore(context: context).save(reading(weekly: 40, at: now), label: "main")
        } else if stored == "a reading file that does not decode" {
            try NoFollowWriter(root: context.dataRoot).put(
                Data("{not json".utf8), folders: Layout.readingsFolders,
                name: Layout.readingName("main"))
        }
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(400 * 86_400))
        let left = try h.read(label: "main").map { now.timeIntervalSince($0.at) }
        let seqs = try log.answer(EventsQuery(), now: now).events.map(\.seq)
        if stored == "a reading" {
            // Retention counts back from the reading: only the line and the event of 50 days go.
            #expect(left == Array(ages.dropFirst()) + [0])
            #expect(seqs == [2, 3, 4, 5])
        } else {
            // No stored reading to count back from: the clock alone prunes nothing.
            #expect(left == ages, "\(stored)")
            #expect(seqs == [1, 2, 3, 4, 5], "\(stored)")
        }
    }

    @Test func aRemovedLabelsHistoryWaitsForAStoredReadingAndThenAgesOut() throws {
        let t = try TestHome()
        let context = t.context
        // The only configured account replaced the removed one and has no reading yet.
        try ConfigStore(context: context).save(
            Config(accounts: [account("key-fresh", label: "fresh")]))
        try HookRecord(context: context).record(.empty)
        let gone = account("key-gone", label: "gone")
        let h = ReadingHistory(context: context)
        let days = [10.0, 2, 1].map { now.addingTimeInterval(-$0 * 86_400) }
        for (index, at) in days.enumerated() {
            try h.append(
                StatusBuilder.historyLine(
                    account: gone, reading: reading(weekly: Double(20 + index), at: at),
                    state: "ok"),
                label: "gone")
        }
        let ahead = now.addingTimeInterval(400 * 86_400)
        try StatusBuilder.rebuild(context: context, now: ahead)
        #expect(try h.read(label: "gone").map(\.at) == days)
        // A reading 32 days on: the cutoff is 35 days before it, whatever the clock says.
        let store = ReadingStore(context: context)
        try store.save(reading(weekly: 5, at: now.addingTimeInterval(32 * 86_400)), label: "fresh")
        try StatusBuilder.rebuild(context: context, now: ahead)
        #expect(try h.read(label: "gone").map(\.at) == Array(days.dropFirst()))
        // Once a reading is more than 35 days newer than its last line, nothing of it is left.
        try store.save(reading(weekly: 6, at: now.addingTimeInterval(37 * 86_400)), label: "fresh")
        try StatusBuilder.rebuild(context: context, now: ahead.addingTimeInterval(86_400))
        #expect(try h.read(label: "gone").isEmpty)
    }

    @Test(arguments: [
        "neither", "a five-hour one", "a weekly one", "another window's one", "a carried Fable one",
    ])
    func onlyAReadingWithAFiveHourOrWeeklyResetTimeMovesThePruneCutoff(_ resets: String) throws {
        let t = try TestHome()
        let context = t.context
        var config = Config(accounts: [account()])
        config.fable.probe = resets == "a carried Fable one"
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        let h = ReadingHistory(context: context)
        let log = EventLog(context: context)
        // 35 days less 7 days 4 minutes 30 seconds, the most a weekly reset time lets a reading be
        // dated ahead of a real time on the minute.
        let bound: TimeInterval = 35 * 86_400 - (7 * 86_400 + 270)
        let ages: [TimeInterval] = [50 * 86_400, bound + 1, bound, 3_600]
        for (index, ago) in ages.enumerated() {
            try h.append(line(Double(10 + index), ago: ago), label: "main")
            try log.append([draft("main")], now: now.addingTimeInterval(-ago))
        }
        // The service gives each reset time 30 seconds before a whole minute, at most one window
        // after the real time, and it is stored at that minute. The clock runs as far ahead as the
        // reply allows: 300 seconds past the time given, 270 past the minute stored.
        func window(_ name: String, _ used: String, resetIn seconds: TimeInterval?) -> String {
            let base: Int = Int(now.timeIntervalSince1970) - 30
            let reset: String = seconds.map { ",\"resetsAt\":\(base + Int($0))" } ?? ""
            return "\"\(name)\":{\"utilization\":\(used)" + reset + "}"
        }
        func stream(_ entries: [String]) -> String {
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
                + entries.joined(separator: ",") + "}}}"
        }
        let store = ReadingStore(context: context)
        let noPickerReset = [
            window("five_hour", "0.1", resetIn: nil), window("seven_day", "0.45", resetIn: nil),
        ]
        let entries: [String]
        let ahead: TimeInterval
        switch resets {
        case "a five-hour one":
            entries = [
                window("five_hour", "0.1", resetIn: 5 * 3_600),
                window("seven_day", "0.45", resetIn: nil),
            ]
            ahead = 5 * 3_600 + 270
        case "a weekly one":
            entries = [window("seven_day", "0.45", resetIn: 7 * 86_400)]
            ahead = 7 * 86_400 + 270
        case "another window's one":
            // Only a 31-day window has a reset time.
            entries = noPickerReset + [window("monthly_extra", "0.3", resetIn: 31 * 86_400)]
            ahead = 31 * 86_400 + 270
        case "a carried Fable one":
            // A Fable reply at the real time; the plain reply below carries its Fable reset time
            // over, read when that reset time is 270 seconds back.
            let fable = stream([
                window("five_hour", "0.1", resetIn: 3_600),
                window("seven_day", "0.2", resetIn: 3 * 86_400),
                window(WindowName.fable, "0.3", resetIn: 7 * 86_400),
            ])
            guard case .reading(let first) = ProbeReader.parse(fable, readAt: now) else {
                Issue.record("the Fable reply was refused")
                return
            }
            try store.record(first, label: "main", callsHook: false, fable: config.fable, now: now)
            entries = noPickerReset
            ahead = 7 * 86_400 + 270
        default:
            entries = noPickerReset
            ahead = 400 * 86_400
        }
        let reply = stream(entries)
        if resets != "neither" && resets != "a carried Fable one",
            case .reading = ProbeReader.parse(reply, readAt: now.addingTimeInterval(ahead + 1))
        {
            Issue.record("a reply with \(resets) was read more than \(ahead) seconds ahead")
        }
        let readAt = now.addingTimeInterval(ahead)
        guard case .reading(let r) = ProbeReader.parse(reply, readAt: readAt) else {
            Issue.record("the reply with \(resets) was refused")
            return
        }
        try store.record(r, label: "main", callsHook: false, fable: config.fable, now: readAt)
        // The saved reading keeps the reset time the case is about.
        let saved = try #require(try store.load(label: "main"))
        if resets == "another window's one" {
            #expect(
                saved.windows["monthly_extra"]?.resetsAt == now.addingTimeInterval(31 * 86_400))
        }
        if resets == "a carried Fable one" {
            #expect(saved.fable?.resetsAt == now.addingTimeInterval(7 * 86_400))
            #expect(saved.fiveHour?.resetsAt == nil && saved.sevenDay?.resetsAt == nil)
        }
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(400 * 86_400))
        let left = try h.read(label: "main").map { now.timeIntervalSince($0.at) }
        let seqs = try log.answer(EventsQuery(), now: now).events.map(\.seq)
        switch resets {
        case "a five-hour one":
            // The cutoff is 35 days before the reading, which is 5 hours 4 minutes 30 seconds
            // ahead.
            #expect(left == Array(ages.dropFirst()) + [-ahead])
            #expect(seqs == [2, 3, 4, 5])
        case "a weekly one":
            // 7 days 4 minutes 30 seconds ahead: a line 27 days 23 hours 55 minutes 30 seconds old
            // stays, and one a second older goes.
            #expect(left == Array(ages.dropFirst(2)) + [-ahead])
            #expect(seqs == [3, 4, 5])
        default:
            // No five-hour or weekly reset time bounds how far ahead this reading is dated, so it
            // moves no cutoff, whatever another window's or the Fable reading's reset time says.
            #expect(left == ages + [-ahead])
            #expect(seqs == [1, 2, 3, 4, 5])
        }
    }

    @Test(arguments: [
        "both far before it", "a weekly one 270 seconds before it",
        "a weekly one 271 seconds before it", "a five-hour one 270 seconds before it",
    ])
    func aReadingMovesThePruneCutoffOnlyByAResetTimeAtMost270SecondsBeforeItsOwnTime(
        _ resets: String
    ) throws {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        let h = ReadingHistory(context: context)
        let log = EventLog(context: context)
        let ages: [TimeInterval] = [50 * 86_400, 10 * 86_400, 3_600]
        for (index, ago) in ages.enumerated() {
            try h.append(line(Double(10 + index), ago: ago), label: "main")
            try log.append([draft("main")], now: now.addingTimeInterval(-ago))
        }
        // Reading files saved as they are. The first, dated 400 days ahead with the reset times of
        // the real time, is one this version never writes, as an earlier version or an edit can.
        let far = resets == "both far before it"
        let lead: TimeInterval = far ? 400 * 86_400 : 0
        let readAt = now.addingTimeInterval(lead)
        func window(_ used: Double, resetIn seconds: TimeInterval) -> WindowReading {
            WindowReading(
                usedPercent: used, resetsAt: now.addingTimeInterval(seconds), readAt: readAt)
        }
        var windows: [String: WindowReading] = [:]
        switch resets {
        case "both far before it":
            windows[WindowName.fiveHour] = window(5, resetIn: 2 * 3_600)
            windows[WindowName.sevenDay] = window(40, resetIn: 3 * 86_400)
        case "a weekly one 270 seconds before it":
            windows[WindowName.sevenDay] = window(40, resetIn: -270)
        case "a weekly one 271 seconds before it":
            windows[WindowName.sevenDay] = window(40, resetIn: -271)
        default:
            windows[WindowName.fiveHour] = window(5, resetIn: -270)
            windows[WindowName.sevenDay] = window(40, resetIn: -2 * 86_400)
        }
        try ReadingStore(context: context).save(
            Reading(readAt: readAt, windows: windows), label: "main")
        try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(400 * 86_400))
        let left = try h.read(label: "main").map { now.timeIntervalSince($0.at) }
        let seqs = try log.answer(EventsQuery(), now: now).events.map(\.seq)
        if resets.hasSuffix("270 seconds before it") {
            // The cutoff is 35 days before the reading: only the line and the event of 50 days go.
            #expect(left == Array(ages.dropFirst()) + [0])
            #expect(Array(seqs.prefix(2)) == [2, 3])
        } else {
            // No reading bounds the cutoff, so nothing is pruned.
            #expect(left == ages + [-lead])
            #expect(Array(seqs.prefix(3)) == [1, 2, 3])
        }
    }

    @Test(arguments: ["an earlier version", "this version"])
    func aReadingFileThisOrAnEarlierVersionSavedKeepsEveryLineInsideTheBound(_ saver: String)
        throws
    {
        let t = try TestHome()
        let context = t.context
        let config = Config(accounts: [account()])
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        // The real time is 30 seconds past a minute. The service gives the weekly reset time one
        // window after it, and a reading file stores that time rounded up to the next minute.
        let real = now.addingTimeInterval(30)
        let given = real.addingTimeInterval(7 * 86_400)
        let stored = given.addingTimeInterval(30)
        let h = ReadingHistory(context: context)
        let log = EventLog(context: context)
        // 35 days less 7 days 5 minutes: a line younger than that always stays.
        let bound: TimeInterval = 35 * 86_400 - (7 * 86_400 + 300)
        let ages: [TimeInterval] = [50 * 86_400, bound + 1, bound, bound - 29, 3_600]
        for (index, ago) in ages.enumerated() {
            // `line` counts back from `now`, 30 seconds before the real time.
            try h.append(line(Double(10 + index), ago: ago - 30), label: "main")
            try log.append([draft("main")], now: real.addingTimeInterval(-ago))
        }
        let reply: String =
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
            + "\"seven_day\":{\"utilization\":0.45,\"resetsAt\":"
            + "\(Int(given.timeIntervalSince1970))}}}}"
        let readAt: Date
        if saver == "this version" {
            // The latest this version reads the reply: 300 seconds after the time given.
            readAt = given.addingTimeInterval(300)
            if case .reading = ProbeReader.parse(reply, readAt: readAt.addingTimeInterval(1)) {
                Issue.record("the reply was read more than 300 seconds after its reset time")
            }
            guard case .reading(let r) = ProbeReader.parse(reply, readAt: readAt) else {
                Issue.record("the reply was refused")
                return
            }
            try ReadingStore(context: context).record(
                r, label: "main", callsHook: false, fable: config.fable, now: readAt)
        } else {
            // An earlier version checked only the minute it stored, so it read the reply as late
            // as 330 seconds after the time given, which this version refuses.
            readAt = given.addingTimeInterval(330)
            #expect(ResetBounds.contains(stored, window: WindowName.sevenDay, readAt: readAt))
            if case .reading = ProbeReader.parse(reply, readAt: readAt) {
                Issue.record("the reply was read 330 seconds after its reset time")
            }
            // The file as that version saved it.
            let iso = ISO8601DateFormatter()
            let text: String =
                "{\"fable\":{\"guaranteedRoomPercentOfCap\":10,\"source\":\"estimate\","
                + "\"upToPercentOfWeekly\":45},\"readAt\":\"\(iso.string(from: readAt))\","
                + "\"schemaVersion\":1,\"source\":\"probe\",\"windows\":{\"seven_day\":{"
                + "\"readAt\":\"\(iso.string(from: readAt))\",\"resetsAt\":"
                + "\"\(iso.string(from: stored))\",\"usedPercent\":45}}}\n"
            try NoFollowWriter(root: context.dataRoot).put(
                Data(text.utf8), folders: Layout.readingsFolders, name: Layout.readingName("main"))
        }
        let saved = try #require(try ReadingStore(context: context).load(label: "main"))
        #expect(saved.readAt == readAt && saved.sevenDay?.resetsAt == stored)
        // A rebuild while the clock is still that far ahead.
        try StatusBuilder.rebuild(context: context, now: readAt.addingTimeInterval(60))
        let left = try h.read(label: "main").map { real.timeIntervalSince($0.at) }
        let seqs = try log.answer(EventsQuery(), now: now).events.map(\.seq)
        let lead = readAt.timeIntervalSince(real)
        if saver == "this version" {
            // 7 days 5 minutes ahead, 270 seconds after the stored minute: a line 27 days 23 hours
            // 55 minutes old stays, and one a second older goes.
            #expect(left == Array(ages.dropFirst(2)) + [-lead])
            #expect(seqs == [3, 4, 5, 6])
        } else {
            // 300 seconds after the stored minute, so the reading moves no cutoff.
            #expect(left == ages + [-lead])
            #expect(seqs == [1, 2, 3, 4, 5, 6])
        }
    }

    @Test(arguments: ["no reading", "a reading with no reset time"])
    func retentionZeroDropsEveryLineWithoutWaitingForAReadingWithAResetTime(_ stored: String)
        throws
    {
        let t = try TestHome()
        let context = t.context
        var config = Config(accounts: [account()])
        config.history.retentionDays = 0
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        // Lines written while retention was longer.
        let h = ReadingHistory(context: context)
        let log = EventLog(context: context)
        let ages: [TimeInterval] = [10 * 86_400, 3_600]
        for (index, ago) in ages.enumerated() {
            try h.append(line(Double(10 + index), ago: ago), label: "main")
            try log.append([draft("main")], now: now.addingTimeInterval(-ago))
        }
        if stored == "a reading with no reset time" {
            let at = now.addingTimeInterval(-60)
            try ReadingStore(context: context).save(
                Reading(
                    readAt: at,
                    windows: [
                        WindowName.sevenDay: WindowReading(
                            usedPercent: 10, resetsAt: nil, readAt: at)
                    ]), label: "main")
        }
        try StatusBuilder.rebuild(context: context, now: now)
        // With 0 days a prune counts back from no time, so it does not wait for a reading with a
        // reset time: every history line goes, and the events record keeps the label's newest.
        #expect(try h.read(label: "main").isEmpty)
        let events = try log.answer(EventsQuery(), now: now).events
        #expect(events.map(\.label) == ["main"])
    }

    @Test func aChangeTheStateDidNotKeepStaysAfterAFailedSaveAndStatusIsRight() throws {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        try ReadingStore(context: context).save(reading(weekly: 20, at: now), label: "main")
        var failing = StatusObservations()
        failing.probe["main"] = ProbeObservation(
            error: Issue(.checkFailed, .error, "Check failed: x."))
        var good = StatusObservations()
        good.probe["main"] = ProbeObservation(error: nil)
        try StatusBuilder.rebuild(context: context, observations: failing, now: now)
        // The account recovers, and current.json cannot be saved after the events were.
        let state = context.dataRoot.appendingPathComponent("state").path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state)
        }
        #expect(throws: ToolError.self) {
            try StatusBuilder.rebuild(
                context: context, observations: good, now: now.addingTimeInterval(60))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state)
        // The error is back before the next rebuilds, which compare with the old file.
        var document: StatusDocument?
        for minutes in [2.0, 3] {
            document = try StatusBuilder.rebuild(
                context: context, observations: failing, now: now.addingTimeInterval(minutes * 60))
        }
        let events = try EventLog(context: context).answer(EventsQuery(), now: now).events
        #expect(events.map(\.type) == ["account_added", "error", "recovered"])
        let states = try ReadingHistory(context: context).read(label: "main").map(\.state)
        #expect(states == ["error", "ok"])
        #expect(document?.accounts.first?.state == "error")
        #expect(document?.accounts.first?.error?.code == StateCode.checkFailed.rawValue)
    }

    @Test(arguments: ["current.json", "the events step"])
    func aChangeOnlyAProbeSawIsSeenAgainOnlyAtTheAccountsNextProbe(_ failed: String) throws {
        let t = try TestHome()
        let context = t.context
        try ConfigStore(context: context).save(Config(accounts: [account()]))
        try HookRecord(context: context).record(.empty)
        try ReadingStore(context: context).save(reading(weekly: 20, at: now), label: "main")
        var failing = StatusObservations()
        failing.probe["main"] = ProbeObservation(
            error: Issue(.checkFailed, .error, "Check failed: x."))
        var good = StatusObservations()
        good.probe["main"] = ProbeObservation(error: nil)
        try StatusBuilder.rebuild(context: context, observations: good, now: now)
        // A probe fails, and its rebuild cannot save current.json, or its events step fails.
        let state = context.dataRoot.appendingPathComponent("state")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: state.path)
        }
        let record = state.appendingPathComponent("events.jsonl")
        let aside = state.appendingPathComponent("events-aside.jsonl")
        if failed == "current.json" {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: state.path)
            #expect(throws: ToolError.self) {
                try StatusBuilder.rebuild(
                    context: context, observations: failing, now: now.addingTimeInterval(60))
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: state.path)
        } else {
            try FileManager.default.moveItem(at: record, to: aside)
            try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
            try StatusBuilder.rebuild(
                context: context, observations: failing, now: now.addingTimeInterval(60))
            try FileManager.default.removeItem(at: record)
            try FileManager.default.moveItem(at: aside, to: record)
        }
        let log = EventLog(context: context)
        let h = ReadingHistory(context: context)
        let written: [String] =
            failed == "current.json" ? ["account_added", "error"] : ["account_added"]
        // A rebuild with no probe compares with the old file: status shows the state before the
        // change, and nothing is written again.
        let quiet = try StatusBuilder.rebuild(context: context, now: now.addingTimeInterval(120))
        #expect(quiet?.accounts.first?.state == "ok")
        #expect(try log.answer(EventsQuery(), now: now).events.map(\.type) == written)
        #expect(try h.read(label: "main").map(\.state) == ["ok", "error"])
        if failed == "current.json" {
            // The account's next probe sees the error again, and its event is written again.
            let next = try StatusBuilder.rebuild(
                context: context, observations: failing, now: now.addingTimeInterval(180))
            #expect(next?.accounts.first?.state == "error")
            #expect(
                try log.answer(EventsQuery(), now: now).events.map(\.type) == written + ["error"])
        } else {
            // The account is fine at its next probe, so the error never gets an event, and the
            // history keeps it.
            let next = try StatusBuilder.rebuild(
                context: context, observations: good, now: now.addingTimeInterval(180))
            #expect(next?.accounts.first?.state == "ok")
            #expect(try log.answer(EventsQuery(), now: now).events.map(\.type) == written)
        }
        #expect(try h.read(label: "main").map(\.state) == ["ok", "error"])
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

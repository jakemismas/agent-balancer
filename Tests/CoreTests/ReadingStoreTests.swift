import Foundation
import Testing

@testable import Core

@Suite struct ReadingStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = Date(timeIntervalSince1970: 1_800_100_000)
    let fable = FableSettings()

    func reading(
        week: Double, at: Date, resets: Date? = nil, fableUsed: Double? = nil
    ) -> Reading {
        var r = Reading(
            readAt: at,
            windows: [
                WindowName.sevenDay: WindowReading(
                    usedPercent: week, resetsAt: resets ?? reset, readAt: at)
            ])
        if let fableUsed {
            r.fable = FableReading(
                source: ReadingSource.probe, usedPercent: fableUsed, resetsAt: resets ?? reset,
                readAt: at, weeklyUsedPercentAtRead: week)
        }
        return r
    }

    @Test func aLowerValueNeverReplacesAHigherOneAndReadAtDoesNotMove() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        _ = try store.record(
            reading(week: 80, at: t0), label: "a", callsHook: false, fable: fable, now: t0)
        let later = t0.addingTimeInterval(600)
        let merged = try store.record(
            reading(week: 40, at: later), label: "a", callsHook: false, fable: fable, now: later)
        #expect(merged.sevenDay?.usedPercent == 80)
        #expect(merged.sevenDay?.readAt == t0)
        let saved = try store.load(label: "a")
        #expect(saved?.sevenDay?.usedPercent == 80)
        #expect(saved?.sevenDay?.readAt == t0)
        #expect(saved?.readAt == later)
    }

    @Test func aHigherValueReplacesTheStoredOne() {
        let merged = ReadingMerge.merge(
            stored: reading(week: 40, at: t0), incoming: reading(week: 60, at: t0 + 60),
            fableSettings: fable, now: t0 + 60)
        #expect(merged.sevenDay?.usedPercent == 60)
        #expect(merged.sevenDay?.readAt == t0 + 60)
    }

    @Test func aWindowThatResetEarlyIsDiscarded() {
        let early = reset.addingTimeInterval(7 * 86_400)
        let merged = ReadingMerge.merge(
            stored: reading(week: 80, at: t0),
            incoming: reading(week: 2, at: t0 + 60, resets: early), fableSettings: fable,
            now: t0 + 60)
        #expect(merged.sevenDay?.usedPercent == 80)
        #expect(merged.sevenDay?.resetsAt == reset)
    }

    @Test func aNewWindowReplacesOneWhoseResetHasPassed() {
        let next = reset.addingTimeInterval(7 * 86_400)
        let after = reset.addingTimeInterval(60)
        let merged = ReadingMerge.merge(
            stored: reading(week: 80, at: t0),
            incoming: reading(week: 2, at: after, resets: next), fableSettings: fable, now: after)
        #expect(merged.sevenDay?.usedPercent == 2)
        #expect(merged.sevenDay?.resetsAt == next)
    }

    @Test func resetTimesEqualToTheMinuteAreOneWindow() {
        let minuteStart = Date(
            timeIntervalSince1970: (reset.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let a = reading(week: 80, at: t0, resets: minuteStart)
        let b = reading(week: 10, at: t0 + 60, resets: minuteStart.addingTimeInterval(30))
        let merged = ReadingMerge.merge(
            stored: a, incoming: b, fableSettings: fable, now: t0 + 60)
        #expect(merged.sevenDay?.usedPercent == 80)
    }

    @Test func aHeldWindowAPickReadsTakesAHigherUseButKeepsItsResetTime() {
        let later = t0.addingTimeInterval(1_200)
        let resets = [
            WindowName.fiveHour: t0.addingTimeInterval(3_600), WindowName.sevenDay: reset,
            "monthly_extra": reset,
        ]
        // Every window, the Fable one too, at `used`, with its reset moved by `moved`, or none.
        func held(_ used: Double, at: Date, moved: TimeInterval?) -> Reading {
            var r = Reading(readAt: at)
            for (name, resetsAt) in resets {
                r.windows[name] = WindowReading(
                    usedPercent: used, resetsAt: moved.map { resetsAt.addingTimeInterval($0) },
                    readAt: at)
            }
            r.fable = FableReading(
                source: ReadingSource.probe, usedPercent: used,
                resetsAt: moved.map { reset.addingTimeInterval($0) }, readAt: at,
                weeklyUsedPercentAtRead: used)
            return r
        }
        let stored = held(40, at: t0, moved: 0)
        // The stored resets have not passed; the reply names a later one, an earlier one or none.
        for moved in [2 * 86_400, -1_800, nil] as [TimeInterval?] {
            let note = "reply reset moved by \(moved.map { "\($0)" } ?? "none")"
            let merged = ReadingMerge.merge(
                stored: stored, incoming: held(95, at: later, moved: moved),
                fableSettings: fable, now: later)
            for name in [WindowName.fiveHour, WindowName.sevenDay] {
                #expect(
                    merged.windows[name]
                        == WindowReading(usedPercent: 95, resetsAt: resets[name], readAt: later),
                    "\(name), \(note)")
            }
            #expect(merged.fable?.usedPercent == 95, "\(note)")
            #expect(merged.fable?.resetsAt == reset && merged.fable?.readAt == later, "\(note)")
            #expect(merged.fable?.weeklyUsedPercentAtRead == 95, "\(note)")
            // A window no pick reads keeps the stored use while it holds.
            #expect(merged.windows["monthly_extra"] == stored.windows["monthly_extra"], "\(note)")
            // A lower use from the reply never lowers a held window, and the same use leaves it
            // as it was, its time included.
            for used in [5.0, 40] {
                let kept = ReadingMerge.merge(
                    stored: stored, incoming: held(used, at: later, moved: moved),
                    fableSettings: fable, now: later)
                #expect(kept.windows == stored.windows, "\(note), use \(used)")
                #expect(kept.fable == stored.fable, "\(note), use \(used)")
            }
        }
    }

    /// A Fable pick of `reading` on a pool account a minute after `at`.
    func fablePick(_ reading: Reading, at: Date) -> PickDecision {
        let account = Account(label: "a", kind: Kind.token, role: Role.pool)
        return Picker.decide(
            inputs: [PickInput(account: account, reading: reading)], config: Config(),
            model: .fable, openLeases: [:], now: at.addingTimeInterval(60))
    }

    @Test func aFableReprobeWithTheSameUseKeepsAFablePickOpenADayLater() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        _ = try store.record(
            reading(week: 40, at: t0, fableUsed: 31), label: "a", callsHook: false,
            fable: fable, now: t0)
        // 25 hours later, before the window resets, the probe shows the same Fable use.
        let later = t0.addingTimeInterval(25 * 3_600)
        let merged = try store.record(
            reading(week: 40, at: later, fableUsed: 31), label: "a", callsHook: false,
            fable: fable, now: later)
        #expect(merged.fable?.usedPercent == 31)
        #expect(merged.fable?.readAt == later)
        let d = fablePick(merged, at: later)
        #expect(d.chosen == 0, "\(d.candidates.first?.reason ?? "")")
        #expect(d.reason.contains("Fable at least 69% of cap left."))
    }

    @Test func theFableRiseRuleCountsFromTheProbeThatConfirmedTheUse() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        _ = try store.record(
            reading(week: 40, at: t0, fableUsed: 31), label: "a", callsHook: false,
            fable: fable, now: t0)
        // All-models use rose 8 points; ten minutes later the probe shows the same Fable use.
        let later = t0.addingTimeInterval(600)
        let risen = try store.record(
            reading(week: 48, at: later, fableUsed: 31), label: "a", callsHook: false,
            fable: fable, now: later)
        #expect(risen.fable?.readAt == later)
        #expect(risen.fable?.weeklyUsedPercentAtRead == 48)
        let d = fablePick(risen, at: later)
        #expect(d.chosen == 0, "\(d.candidates.first?.reason ?? "")")
    }

    @Test func aLowerFableUseInTheSameWindowNeverLowersTheStoredUseOrMovesItsTime() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        let first = try store.record(
            reading(week: 40, at: t0, fableUsed: 31), label: "a", callsHook: false,
            fable: fable, now: t0)
        let later = t0.addingTimeInterval(25 * 3_600)
        let merged = try store.record(
            reading(week: 40, at: later, fableUsed: 20), label: "a", callsHook: false,
            fable: fable, now: later)
        #expect(merged.fable == first.fable)
        #expect(try store.load(label: "a")?.fable?.usedPercent == 31)
        // The lower reply confirms nothing, so the reading is as old as the reply that showed it.
        let d = fablePick(merged, at: later)
        #expect(d.chosen == nil)
        #expect(d.candidates.first?.reason == "Fable reading is stale, refresh failed.")
    }

    @Test func theFableReadingMergesByTheSameRule() {
        let merged = ReadingMerge.merge(
            stored: reading(week: 50, at: t0, fableUsed: 70),
            incoming: reading(week: 50, at: t0 + 60, fableUsed: 20), fableSettings: fable,
            now: t0 + 60)
        #expect(merged.fable?.source == "probe")
        #expect(merged.fable?.usedPercent == 70)
    }

    @Test func noFableReadingKeepsTheEstimate() {
        let at41 = ReadingMerge.merge(
            stored: nil, incoming: reading(week: 41, at: t0), fableSettings: fable, now: t0)
        #expect(at41.fable?.source == "estimate")
        #expect(at41.fable?.usedPercent == nil)
        #expect(at41.fable?.upToPercentOfWeekly == 41)
        #expect(at41.fable?.guaranteedRoomPercentOfCap == 18)
        let at55 = ReadingMerge.merge(
            stored: nil, incoming: reading(week: 55, at: t0), fableSettings: fable, now: t0)
        #expect(at55.fable?.upToPercentOfWeekly == 50)
        #expect(at55.fable?.guaranteedRoomPercentOfCap == 0)
    }

    @Test func switchingFableProbeOffFallsBackToTheEstimate() {
        var off = fable
        off.probe = false
        let merged = ReadingMerge.merge(
            stored: reading(week: 41, at: t0, fableUsed: 30),
            incoming: reading(week: 41, at: t0 + 60), fableSettings: off, now: t0 + 60)
        #expect(merged.fable?.source == "estimate")
    }

    @Test func freshnessUsesTheAgeLimitAndRejectsFutureDates() {
        let r = reading(week: 10, at: t0)
        #expect(r.isFresh(now: t0 + 14 * 60, maxAgeMinutes: 15))
        #expect(!r.isFresh(now: t0 + 15 * 60, maxAgeMinutes: 15))
        #expect(!r.isFresh(now: t0 - 120, maxAgeMinutes: 15))
    }

    @Test func theEncodedKeySetIsPinned() throws {
        var r = reading(week: 41, at: t0, fableUsed: 10)
        r.fableProbedAt = t0
        r.windows[WindowName.fiveHour] = WindowReading(usedPercent: 1, resetsAt: reset, readAt: t0)
        let data = try Reading.encoder().encode(r)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(object.keys)
                == ["schemaVersion", "source", "readAt", "windows", "fable", "fableProbedAt"])
        let windows = try #require(object["windows"] as? [String: [String: Any]])
        #expect(Set(windows.keys) == ["five_hour", "seven_day"])
        #expect(Set(windows["seven_day"]!.keys) == ["usedPercent", "resetsAt", "readAt"])
        let f = try #require(object["fable"] as? [String: Any])
        #expect(
            Set(f.keys)
                == ["source", "usedPercent", "resetsAt", "readAt", "weeklyUsedPercentAtRead"])
        let estimate = FableReading.estimate(weeklyUsedPercent: 41, capPercentOfWeekly: 50)
        let e = try #require(
            JSONSerialization.jsonObject(with: Reading.encoder().encode(estimate))
                as? [String: Any])
        #expect(Set(e.keys) == ["source", "upToPercentOfWeekly", "guaranteedRoomPercentOfCap"])
    }

    @Test func savedFileIsPrivateAndRoundTrips() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        let r = reading(week: 41, at: t0, fableUsed: 10)
        try store.save(r, label: "a")
        #expect(try store.load(label: "a") == r)
        let url = t.context.dataRoot.appendingPathComponent("state/readings/a.json")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)
        #expect(try store.load(label: "missing") == nil)
    }

    @Test func theHookRunsOnlyWhenTheCallerSaysSo() throws {
        let t = try TestHome()
        let calls = HookCalls()
        var store = ReadingStore(context: t.context)
        store.afterProbe = { label, _ in calls.add(label) }
        _ = try store.record(
            reading(week: 1, at: t0), label: "a", callsHook: true, fable: fable, now: t0)
        _ = try store.record(
            reading(week: 1, at: t0), label: "b", callsHook: false, fable: fable, now: t0)
        #expect(calls.labels == ["a"])
    }

    @Test func aStoredFarFutureResetDoesNotPinTheWindow() {
        let far = Date(timeIntervalSince1970: 9_000_000_000)
        let now = t0.addingTimeInterval(600)
        let merged = ReadingMerge.merge(
            stored: reading(week: 80, at: t0, resets: far),
            incoming: reading(week: 5, at: now, resets: reset), fableSettings: fable, now: now)
        #expect(merged.sevenDay?.usedPercent == 5)
        #expect(merged.sevenDay?.resetsAt == reset)
    }

    @Test func aStoredResetAtTheCeilingStillHoldsTheWindow() {
        let weekly = 7 * 86_400.0
        let atEdge = t0.addingTimeInterval(weekly + 600)
        let merged = ReadingMerge.merge(
            stored: reading(week: 80, at: t0, resets: atEdge),
            incoming: reading(week: 5, at: t0, resets: reset), fableSettings: fable, now: t0)
        #expect(merged.sevenDay?.usedPercent == 80)
        let beyond = t0.addingTimeInterval(weekly + 601)
        let replaced = ReadingMerge.merge(
            stored: reading(week: 80, at: t0, resets: beyond),
            incoming: reading(week: 5, at: t0, resets: reset), fableSettings: fable, now: t0)
        #expect(replaced.sevenDay?.usedPercent == 5)
    }

    @Test func aStoredFarFutureFableResetDoesNotPinTheFableReading() {
        let far = Date(timeIntervalSince1970: 9_000_000_000)
        let merged = ReadingMerge.merge(
            stored: reading(week: 80, at: t0, resets: far, fableUsed: 90),
            incoming: reading(week: 81, at: t0 + 60, resets: reset, fableUsed: 10),
            fableSettings: fable, now: t0 + 60)
        #expect(merged.fable?.usedPercent == 10)
    }

    func writeRaw(_ t: TestHome, _ text: String) throws {
        let url = t.context.dataRoot.appendingPathComponent("state/readings/a.json")
        try Data(text.utf8).write(to: url)
    }

    @Test func aStoredResetThatDoesNotDecodeReadsAsUnknownAndKeepsTheRest() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        try store.save(reading(week: 41, at: t0, fableUsed: 10), label: "a")
        let url = t.context.dataRoot.appendingPathComponent("state/readings/a.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "\"resetsAt\" : \"2027-01-16T11:46:40Z\"",
            with: "\"resetsAt\" : \"-4712-01-01T00:00:00Z\"")
        try writeRaw(t, text)
        let loaded = try #require(try store.load(label: "a"))
        #expect(loaded.sevenDay?.usedPercent == 41)
        #expect(loaded.sevenDay?.resetsAt == nil)
        #expect(loaded.fable?.usedPercent == 10)
        #expect(loaded.fable?.resetsAt == nil)
    }

    @Test func aStoredUseOutsideZeroToHundredIsDroppedOnLoad() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        var r = reading(week: 41, at: t0)
        r.windows[WindowName.fiveHour] = WindowReading(
            usedPercent: 1e9, resetsAt: reset, readAt: t0)
        try store.save(r, label: "a")
        let loaded = try #require(try store.load(label: "a"))
        #expect(loaded.fiveHour == nil)
        #expect(loaded.sevenDay?.usedPercent == 41)
    }

    @Test func aFileThatIsNotJSONLoadsAsNoReading() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        try store.save(reading(week: 41, at: t0), label: "a")
        try writeRaw(t, "garbage")
        #expect(try store.load(label: "a") == nil)
        let merged = try store.record(
            reading(week: 12, at: t0), label: "a", callsHook: false, fable: fable, now: t0)
        #expect(merged.sevenDay?.usedPercent == 12)
        #expect(try store.load(label: "a")?.sevenDay?.usedPercent == 12)

        // A file whose only fault is one reset time that does not decode still loads, so the
        // next reading merges into it: the stored weekly use holds, and the window whose reset
        // did not decode takes the new value.
        var damaged = reading(week: 80, at: t0)
        damaged.windows[WindowName.fiveHour] = WindowReading(
            usedPercent: 30, resetsAt: t0.addingTimeInterval(3600), readAt: t0)
        try store.save(damaged, label: "a")
        let url = t.context.dataRoot.appendingPathComponent("state/readings/a.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        let fiveHourReset = "\"2027-01-15T09:00:00Z\""
        #expect(text.components(separatedBy: fiveHourReset).count == 2)
        try writeRaw(
            t, text.replacingOccurrences(of: fiveHourReset, with: "\"-4712-01-01T00:00:00Z\""))
        var next = reading(week: 12, at: t0 + 60)
        next.windows[WindowName.fiveHour] = WindowReading(
            usedPercent: 10, resetsAt: t0.addingTimeInterval(7200), readAt: t0 + 60)
        let kept = try store.record(next, label: "a", callsHook: false, fable: fable, now: t0 + 60)
        #expect(kept.sevenDay?.usedPercent == 80)
        #expect(kept.fiveHour?.usedPercent == 10)
    }

    @Test func recordRefusesAReadingWithoutTheWeeklyUseOrAStoredFiveHour() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        var both = reading(week: 40, at: t0)
        both.windows[WindowName.fiveHour] = WindowReading(
            usedPercent: 10, resetsAt: t0.addingTimeInterval(3600), readAt: t0)
        try store.save(both, label: "a")
        let url = t.context.dataRoot.appendingPathComponent("state/readings/a.json")
        let before = try Data(contentsOf: url)
        let later = t0.addingTimeInterval(7200)
        #expect(throws: ToolError(ProbeReader.noFiveHour, code: .checkFailed)) {
            try store.record(
                reading(week: 45, at: later), label: "a", callsHook: false, fable: fable,
                now: later)
        }
        let noWeekly = Reading(
            readAt: later,
            windows: [
                WindowName.fiveHour: WindowReading(
                    usedPercent: 12, resetsAt: t0.addingTimeInterval(3600), readAt: later)
            ])
        #expect(throws: ToolError(ProbeReader.noWeekly, code: .checkFailed)) {
            try store.record(noWeekly, label: "a", callsHook: false, fable: fable, now: later)
        }
        #expect(try Data(contentsOf: url) == before)
        // With no five_hour stored, the weekly use alone is recorded.
        try store.save(reading(week: 40, at: t0), label: "b")
        let recorded = try store.record(
            reading(week: 45, at: later), label: "b", callsHook: false, fable: fable, now: later)
        #expect(recorded.sevenDay?.usedPercent == 45)
    }

    // Eviction: a stored window that the new probe reading does not carry goes once its value is
    // more than 32 days old or more than 60 seconds ahead; at most 14 other names stay.

    func other(_ used: Double, at: Date) -> WindowReading {
        WindowReading(usedPercent: used, resetsAt: nil, readAt: at)
    }

    @Test func aWindowNoReadingCarriedForMoreThan32DaysIsEvictedAtTheNextMerge() throws {
        let day = 86_400.0
        var stored = reading(week: 40, at: t0.addingTimeInterval(-40 * day))
        stored.windows["gone_33d"] = other(5, at: t0.addingTimeInterval(-33 * day))
        stored.windows["gone_32d1s"] = other(5, at: t0.addingTimeInterval(-32 * day - 1))
        stored.windows["kept_32d"] = other(5, at: t0.addingTimeInterval(-32 * day))
        stored.windows["kept_31d"] = other(5, at: t0.addingTimeInterval(-31 * day))
        stored.windows["gone_ahead_2m"] = other(5, at: t0.addingTimeInterval(120))
        stored.windows["kept_ahead_1m"] = other(5, at: t0.addingTimeInterval(60))
        stored.windows["carried_40d"] = other(5, at: t0.addingTimeInterval(-40 * day))
        var incoming = reading(week: 41, at: t0)
        incoming.windows["carried_40d"] = other(6, at: t0)
        let expected: Set<String> = [
            WindowName.sevenDay, "kept_32d", "kept_31d", "kept_ahead_1m", "carried_40d",
        ]
        let merged = ReadingMerge.merge(
            stored: stored, incoming: incoming, fableSettings: fable, now: t0)
        #expect(Set(merged.windows.keys) == expected)
        #expect(merged.windows["carried_40d"]?.usedPercent == 6)
        // The saved file holds the same names.
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        try store.save(stored, label: "a")
        try store.record(incoming, label: "a", callsHook: false, fable: fable, now: t0)
        #expect(Set(try #require(try store.load(label: "a")).windows.keys) == expected)
    }

    @Test func atMostFourteenOtherNamesStayWithTheNewReadingsNamesFirst() {
        var stored = reading(week: 40, at: t0)
        stored.windows[WindowName.fiveHour] = WindowReading(
            usedPercent: 10, resetsAt: t0.addingTimeInterval(3600), readAt: t0)
        for i in 0..<20 {
            stored.windows[String(format: "o%02d", i)] = other(
                1, at: t0.addingTimeInterval(-Double(i) * 3600))
        }
        // The oldest name is carried at a lower use, so it keeps its old time and stays only
        // because the new reading carries it.
        stored.windows["o19"]?.usedPercent = 9
        var incoming = reading(week: 41, at: t0)
        incoming.windows[WindowName.fiveHour] = stored.windows[WindowName.fiveHour]
        for name in ["n0", "n1", "o19"] { incoming.windows[name] = other(2, at: t0) }
        let merged = ReadingMerge.merge(
            stored: stored, incoming: incoming, fableSettings: fable, now: t0)
        // The carried names first, then the newest of the rest.
        let newest = (0..<11).map { String(format: "o%02d", $0) }
        #expect(
            Set(merged.windows.keys).subtracting(WindowName.picker)
                == Set(["n0", "n1", "o19"] + newest))
        #expect(merged.windows["o19"]?.usedPercent == 9)
        #expect(merged.fiveHour != nil && merged.sevenDay != nil)
        // With equal times, name order decides.
        var tied = reading(week: 40, at: t0)
        let names = (0..<20).map { String(format: "a%02d", $0) }
        for name in names.shuffled() { tied.windows[name] = other(1, at: t0) }
        let merged2 = ReadingMerge.merge(
            stored: tied, incoming: reading(week: 41, at: t0), fableSettings: fable, now: t0)
        #expect(Set(merged2.windows.keys).subtracting(WindowName.picker) == Set(names.prefix(14)))
    }

    @Test func theMergeNeverEvictsFiveHourOrSevenDay() {
        // Only a direct call can merge a reading that carries neither: the store refuses one.
        for at in [t0.addingTimeInterval(-40 * 86_400), t0.addingTimeInterval(3600)] {
            let stored = Reading(
                readAt: at,
                windows: [
                    WindowName.fiveHour: other(10, at: at), WindowName.sevenDay: other(96, at: at),
                ])
            let incoming = Reading(readAt: t0, windows: ["monthly_extra": other(1, at: t0)])
            let merged = ReadingMerge.merge(
                stored: stored, incoming: incoming, fableSettings: fable, now: t0)
            #expect(merged.fiveHour?.usedPercent == 10)
            #expect(merged.sevenDay?.usedPercent == 96)
        }
    }

    @Test func loadingAndSavingTheFableProbeTimeEvictNothing() throws {
        let t = try TestHome()
        let store = ReadingStore(context: t.context)
        var stored = reading(week: 40, at: t0)
        stored.windows["monthly_extra"] = other(5, at: t0.addingTimeInterval(-40 * 86_400))
        try store.save(stored, label: "a")
        #expect(try store.load(label: "a")?.windows["monthly_extra"] != nil)
        try store.noteFableAttempt(label: "a", at: t0)
        let after = try #require(try store.load(label: "a"))
        #expect(after.windows["monthly_extra"] != nil)
        #expect(after.fableProbedAt == t0)
    }

    @Test func eachStoredResetIsJudgedByItsOwnWindowLength() {
        let extra = "monthly_extra"
        let fiveHourCeiling = ResetBounds.storedCeiling(window: WindowName.fiveHour, now: t0)
        // Past the five_hour ceiling but inside the seven_day one; inside 31 days but past 7.
        let stored = Reading(
            readAt: t0,
            windows: [
                WindowName.fiveHour: WindowReading(
                    usedPercent: 80, resetsAt: fiveHourCeiling.addingTimeInterval(60), readAt: t0),
                extra: WindowReading(
                    usedPercent: 80, resetsAt: t0.addingTimeInterval(20 * 86_400), readAt: t0),
            ])
        let soon = t0.addingTimeInterval(3600)
        let incoming = Reading(
            readAt: t0,
            windows: [
                WindowName.fiveHour: WindowReading(usedPercent: 5, resetsAt: soon, readAt: t0),
                extra: WindowReading(usedPercent: 5, resetsAt: soon, readAt: t0),
            ])
        let merged = ReadingMerge.merge(
            stored: stored, incoming: incoming, fableSettings: fable, now: t0)
        #expect(merged.fiveHour?.usedPercent == 5)
        #expect(merged.windows[extra]?.usedPercent == 80)
    }

    @Test func theResetBoundsHoldPerWindowName() {
        let now = t0
        #expect(
            ResetBounds.contains(
                now.addingTimeInterval(5 * 3600 + 300), window: "five_hour", readAt: now))
        #expect(
            !ResetBounds.contains(
                now.addingTimeInterval(5 * 3600 + 301), window: "five_hour", readAt: now))
        #expect(
            !ResetBounds.contains(
                Date(timeIntervalSince1970: .infinity), window: "seven_day", readAt: now))
        #expect(
            !ResetBounds.contains(
                Date(timeIntervalSince1970: .nan), window: "seven_day", readAt: now))
    }
}

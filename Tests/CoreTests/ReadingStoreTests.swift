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

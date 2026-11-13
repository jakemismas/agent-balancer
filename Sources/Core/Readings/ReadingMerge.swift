import Foundation

/// The merge rule of docs/ARCHITECTURE.md section 6.3.
public enum ReadingMerge {
    /// True when two reset times are the same window: equal to the minute, or both unknown.
    static func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?):
            return (x.timeIntervalSince1970 / 60).rounded(.down)
                == (y.timeIntervalSince1970 / 60).rounded(.down)
        default: return false
        }
    }

    /// The windows a pick judges an account by: `five_hour`, `seven_day` and the Fable window.
    static let readByPick: Set<String> = WindowName.picker.union([WindowName.fable])

    /// Within one window the stored use never goes down, and `readAt` stays with the stored value
    /// then. A reading of another window replaces the stored one only when the stored window's
    /// reset time has passed and the new reset time is later. A claim that the window reset early
    /// is discarded, except that a window in `readByPick` keeps its reset time but takes a higher
    /// use, with its `readAt`. A stored reset time beyond what the window allows (`ResetBounds`)
    /// is not trusted, so a later valid reading replaces it.
    public static func window(
        stored: WindowReading?, incoming: WindowReading, now: Date, name: String
    ) -> WindowReading {
        guard let stored else { return incoming }
        if let reset = stored.resetsAt, reset > ResetBounds.storedCeiling(window: name, now: now) {
            return incoming
        }
        if sameWindow(stored.resetsAt, incoming.resetsAt) {
            return incoming.usedPercent > stored.usedPercent ? incoming : stored
        }
        guard let storedReset = stored.resetsAt else { return incoming }
        if storedReset <= now, (incoming.resetsAt ?? .distantFuture) > storedReset {
            return incoming
        }
        // A held window never shows a pick less use than the newest reply gives.
        if readByPick.contains(name), incoming.usedPercent > stored.usedPercent {
            return WindowReading(
                usedPercent: incoming.usedPercent, resetsAt: storedReset, readAt: incoming.readAt)
        }
        return stored
    }

    /// The reading to save after `incoming`, given what was stored. `fableSettings` decides
    /// whether a Fable probe reading is kept or the section 7.4 estimate takes its place. Stored
    /// windows that `incoming` does not carry are evicted by `evict`. The store calls this only to
    /// save a probe reading that passed its checks.
    public static func merge(
        stored: Reading?, incoming: Reading, fableSettings: FableSettings, now: Date
    ) -> Reading {
        var result = Reading(
            source: incoming.source, readAt: incoming.readAt,
            windows: stored?.windows ?? [:], fable: stored?.fable,
            fableProbedAt: stored?.fableProbedAt)
        for (name, window) in incoming.windows {
            result.windows[name] = Self.window(
                stored: result.windows[name], incoming: window, now: now, name: name)
        }
        result.windows = evict(result.windows, carried: Set(incoming.windows.keys), now: now)
        if let probed = incoming.fable, probed.source == ReadingSource.probe {
            result.fable = mergeFable(stored: stored?.fable, incoming: probed, now: now)
        }
        if let at = incoming.fableProbedAt { result.fableProbedAt = at }
        return withFableFallback(result, settings: fableSettings)
    }

    /// How long a stored window that no reading carries stays: longer than the longest window a
    /// reset time may span (31 days plus the slack), so a window whose reset may still be ahead
    /// is never dropped.
    static let evictAfter: TimeInterval = 32 * 86_400

    /// The most stored window names kept besides `five_hour` and `seven_day`.
    static let maxStoredOtherWindows = 14

    /// The stored windows minus those `carried` leaves out whose value was taken more than
    /// `evictAfter` before `now`, or more than 60 seconds after it. Of the rest, at most
    /// `maxStoredOtherWindows` names other than `five_hour` and `seven_day` stay: the carried
    /// names first, then the newest `readAt`, then name order.
    static func evict(_ windows: [String: WindowReading], carried: Set<String>, now: Date)
        -> [String: WindowReading]
    {
        var kept = windows.filter { name, window in
            if carried.contains(name) { return true }
            // Every saved probe reading carries seven_day and any stored five_hour, so this never
            // decides anything; it keeps a later change from evicting a window the picker reads.
            if WindowName.picker.contains(name) { return true }
            let age = now.timeIntervalSince(window.readAt)
            return age <= evictAfter && age >= -60
        }
        let others = kept.keys.filter { !WindowName.picker.contains($0) }
        guard others.count > maxStoredOtherWindows else { return kept }
        let order = others.sorted { a, b in
            let (carriedA, carriedB) = (carried.contains(a), carried.contains(b))
            if carriedA != carriedB { return carriedA }
            let (readA, readB) = (kept[a]?.readAt ?? .distantPast, kept[b]?.readAt ?? .distantPast)
            if readA != readB { return readA > readB }
            return a < b
        }
        for name in order.dropFirst(maxStoredOtherWindows) { kept[name] = nil }
        return kept
    }

    static func mergeFable(stored: FableReading?, incoming: FableReading, now: Date)
        -> FableReading
    {
        guard let stored, stored.source == ReadingSource.probe, let storedUsed = stored.usedPercent,
            let used = incoming.usedPercent
        else { return incoming }
        let old = WindowReading(
            usedPercent: storedUsed, resetsAt: stored.resetsAt, readAt: stored.readAt ?? now)
        let new = WindowReading(
            usedPercent: used, resetsAt: incoming.resetsAt, readAt: incoming.readAt ?? now)
        let kept = window(stored: old, incoming: new, now: now, name: WindowName.fable)
        if kept == old { return stored }
        // A held window keeps its reset time; the use, its time and the weekly use come from the
        // reply.
        var merged = incoming
        merged.resetsAt = kept.resetsAt
        return merged
    }

    /// An account with no Fable probe reading, or with `fable.probe` off, carries the estimate
    /// from its weekly reading, with `source` `estimate`.
    static func withFableFallback(_ reading: Reading, settings: FableSettings) -> Reading {
        var out = reading
        let hasProbe = out.fable?.source == ReadingSource.probe
        if hasProbe && settings.probe { return out }
        if let weekly = out.sevenDay {
            out.fable = FableReading.estimate(
                weeklyUsedPercent: weekly.usedPercent,
                capPercentOfWeekly: settings.capPercentOfWeekly)
        } else {
            out.fable = nil
        }
        return out
    }
}

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

    /// Within one window the stored use never goes down, and `readAt` stays with the stored value
    /// then. A reading of another window replaces the stored one only when the stored window's
    /// reset time has passed and the new reset time is later. A claim that the window reset early
    /// is discarded. A stored reset time beyond what the window allows (`ResetBounds`) is not
    /// trusted, so a later valid reading replaces it.
    public static func window(
        stored: WindowReading?, incoming: WindowReading, now: Date,
        name: String = WindowName.sevenDay
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
        return stored
    }

    /// The reading to save after `incoming`, given what was stored. `fableSettings` decides
    /// whether a Fable probe reading is kept or the section 7.4 estimate takes its place.
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
        if let probed = incoming.fable, probed.source == ReadingSource.probe {
            result.fable = mergeFable(stored: stored?.fable, incoming: probed, now: now)
        }
        if let at = incoming.fableProbedAt { result.fableProbedAt = at }
        return withFableFallback(result, settings: fableSettings)
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
        return kept == old ? stored : incoming
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

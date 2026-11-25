import Foundation

/// The model a pick is for. Only the Fable rules depend on it (section 7.2 rule 4).
public enum PickModel: Equatable, Sendable {
    case fable
    case other
    /// No `--model`, or a name placed neither way: the session may start on a Fable model.
    case unknown

    /// Name parts of the model families that are not Fable.
    static let otherFamilies = ["opus", "sonnet", "haiku"]

    public static func parse(_ name: String?) -> PickModel {
        guard let name = name?.lowercased() else { return .unknown }
        if name.contains("fable") { return .fable }
        return otherFamilies.contains { name.contains($0) } ? .other : .unknown
    }

    /// `--model` only chooses the Fable rules and must match this shape.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._:\\[\\]-]{0,63}$", options: .regularExpression)
            != nil
    }
}

/// One account as the picker sees it: the account, its reading after the refresh, and a reason to
/// skip it that the caller already settled (kind checks, ambient rule, exclusion).
public struct PickInput: Sendable {
    public var account: Account
    public var reading: Reading?
    public var skip: String?

    public init(account: Account, reading: Reading?, skip: String? = nil) {
        self.account = account
        self.reading = reading
        self.skip = skip
    }
}

public struct PickDecision: Equatable, Sendable {
    /// Index into the inputs of the chosen account, or nil.
    public var chosen: Int?
    public var reason: String
    public var candidates: [CandidateResult]
}

/// The pure picker of docs/ARCHITECTURE.md section 7.2: `(config, readings, now, model)` to a
/// decision. It reads no file and starts no process.
public enum Picker {
    private struct Eligible {
        var index: Int
        var expiry: Date
        var expiryFromReset: Bool
        /// The weekly reset time, nil when the reading has none; `expiry` then starts from the far
        /// future.
        var weeklyReset: Date?
        var room: Double
        var reason: String
        var fableNote: String?
        var fiveHourKnown: Bool
    }

    private static let fiveHourUnknown = "5-hour use unknown."

    private enum Verdict {
        case no(String)
        case yes(Eligible)
    }

    public static func decide(
        inputs: [PickInput], config: Config, model: PickModel, openLeases: [String: Int],
        now: Date
    ) -> PickDecision {
        var verdicts: [Verdict] = []
        for (index, input) in inputs.enumerated() {
            if let skip = input.skip {
                verdicts.append(.no(skip))
            } else {
                verdicts.append(
                    evaluate(
                        input, index: index, config: config, model: model,
                        leases: openLeases[input.account.label] ?? 0, now: now))
            }
        }
        let candidates = zip(inputs, verdicts).map { input, verdict -> CandidateResult in
            switch verdict {
            case .no(let reason):
                return CandidateResult(label: input.account.label, eligible: false, reason: reason)
            case .yes(let e):
                return CandidateResult(label: input.account.label, eligible: true, reason: e.reason)
            }
        }
        let eligible = verdicts.compactMap { v -> Eligible? in
            if case .yes(let e) = v { return e }
            return nil
        }
        // 5-hour use known first, then soonest expiry (to the minute), most room, config order.
        let ranked = eligible.sorted { a, b in
            if a.fiveHourKnown != b.fiveHourKnown { return a.fiveHourKnown }
            let ma = (a.expiry.timeIntervalSince1970 / 60).rounded(.down)
            let mb = (b.expiry.timeIntervalSince1970 / 60).rounded(.down)
            if ma != mb { return ma < mb }
            if a.room != b.room { return a.room > b.room }
            return a.index < b.index
        }
        guard let best = ranked.first else {
            let detail = zip(inputs, candidates).map {
                "\(Display.safe($0.account.label)): \($1.reason)"
            }
            .joined(separator: " ")
            let reason =
                detail.isEmpty ? "No account is configured." : "No account has room. " + detail
            return PickDecision(
                chosen: nil, reason: Display.safe(reason, limit: 800), candidates: candidates)
        }
        let head =
            best.expiryFromReset
            ? "Soonest weekly reset: resets \(shortTime(best.weeklyReset))."
            : "Soonest expiry: ends \(shortTime(best.expiry))."
        var reason = best.fableNote.map { head + " " + $0 } ?? head
        if !best.fiveHourKnown {
            reason += " " + fiveHourUnknown
        } else if ranked.contains(where: { !$0.fiveHourKnown }) {
            reason += " Accounts with no 5-hour reading go last."
        }
        return PickDecision(chosen: best.index, reason: reason, candidates: candidates)
    }

    // MARK: One account

    private static func evaluate(
        _ input: PickInput, index: Int, config: Config, model: PickModel, leases: Int, now: Date
    ) -> Verdict {
        let account = input.account
        let picker = config.picker
        if let ends = endsAtEnd(account.endsAt), now >= ends { return .no("Account ended.") }

        let maxAge = picker.maxReadingAgeMinutes
        guard let reading = input.reading, let weekly = reading.sevenDay else {
            return .no("no weekly reading")
        }
        let isMain = account.role == Role.main
        if isMain && reading.source != ReadingSource.probe {
            return .no("No probe reading, which the main account needs.")
        }
        for name in [WindowName.fiveHour, WindowName.sevenDay] {
            if let reset = reading.windows[name]?.resetsAt, reset <= now {
                return .no("window reset, refresh failed")
            }
        }
        guard reading.isFresh(now: now, maxAgeMinutes: maxAge) else {
            return .no("stale reading, refresh failed")
        }

        let limitedAt = Double(picker.limitedAtPercent)
        if weekly.usedPercent >= limitedAt {
            return .no("Limited until \(shortTime(weekly.resetsAt)).")
        }
        let five = reading.fiveHour
        // A plan set as having no 5-hour limit has no window to read; one in the reading counts.
        let fiveHourKnown = five != nil || account.noLimit?.contains(WindowName.fiveHour) == true
        if let five, five.usedPercent >= limitedAt {
            return .no("Limited until \(shortTime(five.resetsAt)).")
        }

        let bump = Double(leases * picker.expectedRunPercent)
        let used = min(100, weekly.usedPercent + bump)
        let fiveUsed = five.map { min(100, $0.usedPercent + bump) }
        let run = Double(picker.expectedRunPercent)

        var room: Double
        if isMain {
            let reserve = account.reserve ?? Reserve.standard
            let days = weekly.resetsAt.map { $0.timeIntervalSince(now) / 86_400 }
            let line = reserveLine(reserve, daysLeft: days)
            let margin = Double(reserve.marginPercent)
            if used + margin > line {
                return .no(
                    String(
                        format:
                            "Weekly use %.1f%% is above the reserve line of %.1f%% minus a %ld point margin.",
                        used, line, reserve.marginPercent))
            }
            // Unknown 5-hour use could lock the user out until the reset, which nothing undoes.
            guard fiveHourKnown else {
                return .no("No 5-hour reading, which the main account needs.")
            }
            if let fiveUsed, fiveUsed + run >= limitedAt {
                return .no(String(format: "5-hour use %.1f%% leaves no room for a run.", fiveUsed))
            }
            room = line - margin - used
        } else {
            let left = limitedAt - used
            if left < Double(picker.minRoomPercent) {
                return .no(
                    String(
                        format: "Only %.1f%% of the week is left, and %ld%% is needed.",
                        max(0, left),
                        picker.minRoomPercent))
            }
            if let fiveUsed, fiveUsed >= limitedAt {
                return .no(String(format: "5-hour use %.1f%% leaves no room.", fiveUsed))
            }
            room = left
        }

        var fableNote: String?
        if model != .other {
            switch fableCheck(
                account: account, model: model, reading: reading, used: used, config: config,
                now: now)
            {
            case .no(let why): return .no(why)
            case .yes(let note): fableNote = note
            }
        }

        var expiry = weekly.resetsAt ?? .distantFuture
        var fromReset = true
        let assumed: Date? =
            account.endingSoon == true && account.endsAt == nil
            ? now.addingTimeInterval(Double(picker.endingSoonAssumeDays) * 86_400) : nil
        if let ends = endsAtEnd(account.endsAt), ends < expiry {
            expiry = ends
            fromReset = false
        }
        if let assumed, assumed < expiry {
            expiry = assumed
            fromReset = false
        }
        room = max(0, room)
        let note = fiveHourKnown ? "" : " " + fiveHourUnknown
        return .yes(
            Eligible(
                index: index, expiry: expiry, expiryFromReset: fromReset,
                weeklyReset: weekly.resetsAt, room: room,
                reason: "Resets \(shortTime(weekly.resetsAt))." + note, fableNote: fableNote,
                fiveHourKnown: fiveHourKnown))
    }

    private enum FableVerdict {
        case no(String)
        case yes(String)
    }

    /// Rule 4 and section 7.4, for a Fable model or one the tool cannot place.
    private static func fableCheck(
        account: Account, model: PickModel, reading: Reading, used: Double, config: Config,
        now: Date
    ) -> FableVerdict {
        if account.fable?.allowLaunches == false {
            let place = account.role == Role.main ? "the main account" : "this account"
            return .no(
                model == .fable
                    ? "Fable launches not allowed on \(place)."
                    : "Model unknown, and Fable launches not allowed on \(place).")
        }
        // Room needs a Fable reading that only a Fable pick's paid probe keeps fresh.
        if model == .unknown { return .yes("Model unknown, so Fable room not checked.") }
        let settings = config.fable
        if settings.probe, let f = reading.fable, f.source == ReadingSource.probe,
            let fableUsed = f.usedPercent
        {
            let rawWeekly = reading.sevenDay?.usedPercent ?? used
            let rise = rawWeekly - (f.weeklyUsedPercentAtRead ?? rawWeekly)
            let old = f.readAt.map { now.timeIntervalSince($0) >= 86_400 } ?? true
            let reset = f.resetsAt.map { $0 <= now } ?? false
            if old || reset || rise >= Double(settings.recheckAfterWeeklyRisePercent) {
                return .no("Fable reading is stale, refresh failed.")
            }
            let left = 100 - fableUsed
            if fableUsed >= Double(config.picker.limitedAtPercent) {
                return .no("Fable limited until \(shortTime(f.resetsAt)).")
            }
            if left < Double(settings.minRoomPercentOfCap) {
                return .no(
                    String(
                        format: "Fable has %.0f%% of its cap left, and %ld%% is needed.",
                        max(0, left).rounded(.down), settings.minRoomPercentOfCap))
            }
            return .yes(String(format: "Fable at least %.0f%% of cap left.", left.rounded(.down)))
        }
        // No reading yet, or probing is off: only the guaranteed room counts.
        let cap = Double(settings.capPercentOfWeekly)
        let guaranteedWeek = max(0, cap - used)
        if guaranteedWeek < Double(config.picker.minRoomPercent) {
            return .no(
                "Fable room not readable and not guaranteed above \(settings.capPercentOfWeekly)% weekly use."
            )
        }
        let ofCap = (guaranteedWeek / cap * 100).rounded(.down)
        return .yes(String(format: "Fable room guaranteed at %.0f%% of cap.", ofCap))
    }

    // MARK: Helpers

    /// The reserve line of section 7.2 rule 2: the configured value, linear between points, flat
    /// beyond the ends. With no known reset the first point (the most days) applies, which is
    /// the lowest line. No points means no launch.
    static func reserveLine(_ reserve: Reserve, daysLeft: Double?) -> Double {
        let points = reserve.points.sorted { $0.daysLeft > $1.daysLeft }
        guard let first = points.first, let last = points.last else { return 0 }
        guard let d = daysLeft else { return Double(first.maxUsedPercent) }
        if d >= Double(first.daysLeft) { return Double(first.maxUsedPercent) }
        if d <= Double(last.daysLeft) { return Double(last.maxUsedPercent) }
        for (a, b) in zip(points, points.dropFirst()) {
            let hi = Double(a.daysLeft)
            let lo = Double(b.daysLeft)
            if d <= hi && d >= lo {
                if hi == lo { return Double(b.maxUsedPercent) }
                let t = (hi - d) / (hi - lo)
                return Double(a.maxUsedPercent)
                    + t * Double(b.maxUsedPercent - a.maxUsedPercent)
            }
        }
        return Double(last.maxUsedPercent)
    }

    /// An account's `endsAt` date is its last day: it ends when that local day is over.
    static func endsAtEnd(_ text: String?) -> Date? {
        guard let text, ConfigValidator.isValidDate(text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: text) else { return nil }
        return Calendar.current.date(byAdding: .day, value: 1, to: day)
    }

    static func shortTime(_ date: Date?) -> String {
        guard let date else { return "an unknown time" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE h:mm a"
        formatter.timeZone = LocalTime.zone
        return formatter.string(from: date)
    }
}

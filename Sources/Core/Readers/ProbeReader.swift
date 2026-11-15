import Foundation

public enum ProbeReadResult: Equatable, Sendable {
    case reading(Reading)
    case failed(Issue)
}

/// Reads the output of the one-turn probe (docs/ARCHITECTURE.md section 6.2). It reads only the
/// `rate_limit_event` lines and the error fields of the final `result` line. Every other line is
/// dropped unread, so nothing personal in them can reach a reading.
public enum ProbeReader {
    /// Window names a reply keeps besides `five_hour`, `seven_day` and the Fable window.
    static let maxOtherWindows = 14
    static let authStatusCodes: Set<Int> = [401]
    static let authPhrases = [
        "invalid api key", "please run /login", "authentication", "unauthorized",
        "oauth token", "token has expired", "invalid bearer", "not logged in",
    ]
    static let badUsage = "Check failed: the probe gave a usage value outside 0 to 1."
    static let badReset = "Check failed: the probe gave a reset time outside the window."
    static let noWeekly = "Check failed: the probe reply carried no weekly usage."
    static let noFiveHour = "Check failed: the probe reply carried no 5-hour usage."

    public static func parse(_ output: String, readAt: Date) -> ProbeReadResult {
        var windows: [String: WindowReading] = [:]
        var fableWindow: WindowReading?
        var sawEvent = false
        var sawJSON = false
        var namedFiveHour = false
        var resultError: (auth: Bool, subtype: String)?

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "{", let data = line.data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            sawJSON = true
            switch object["type"] as? String {
            case "rate_limit_event":
                guard let info = object["rate_limit_info"] as? [String: Any] else { continue }
                let found: [(String, Any)]
                if let unified = info["unifiedWindows"] as? [String: Any] {
                    found = unified.map { ($0.key, $0.value) }
                } else if let kind = info["rateLimitType"] as? String {
                    found = [(kind, info)]
                } else {
                    found = []
                }
                // Every entry with a usage value is checked, whatever its name and whether the
                // cap below keeps it: a value the tool cannot trust fails the whole reply.
                for (name, raw) in found {
                    guard isValidName(name) else { continue }
                    if name == WindowName.fiveHour { namedFiveHour = true }
                    guard let entry = raw as? [String: Any], let utilization = entry["utilization"]
                    else { continue }
                    guard let percent = percent(from: utilization) else {
                        return .failed(Issue(.checkFailed, .error, badUsage))
                    }
                    let resetsAt: Date?
                    switch resetTime(entry["resetsAt"], window: name, readAt: readAt) {
                    case .absent: resetsAt = nil
                    case .valid(let date): resetsAt = date
                    case .invalid: return .failed(Issue(.checkFailed, .error, badReset))
                    }
                    sawEvent = true
                    let window = WindowReading(
                        usedPercent: percent, resetsAt: resetsAt, readAt: readAt)
                    if name == WindowName.fable {
                        fableWindow = merged(fableWindow, window, name: name)
                    } else {
                        windows[name] = merged(windows[name], window, name: name)
                    }
                }
            case "result":
                guard object["is_error"] as? Bool == true else { continue }
                let status = object["api_error_status"] as? Int
                let text = (object["result"] as? String)?.lowercased() ?? ""
                let auth =
                    status.map(authStatusCodes.contains) == true
                    || authPhrases.contains { text.contains($0) }
                resultError = (auth, object["subtype"] as? String ?? "error")
            default:
                continue
            }
        }

        if let error = resultError, error.auth {
            return .failed(Issue(.loginRejected, .error, Messages.probeLoginRejected))
        }
        guard sawEvent else {
            if let error = resultError {
                return .failed(
                    Issue(
                        .checkFailed, .error,
                        "Check failed: the probe ended with \(Display.safe(error.subtype, limit: 40))."
                    ))
            }
            let why = sawJSON ? "carried no usage window" : "could not be read"
            return .failed(Issue(.checkFailed, .error, "Check failed: the probe reply \(why)."))
        }
        // Without these the merge would keep the stored use under this reading's time, and a pick
        // would judge the account on old use as if it were new.
        guard windows[WindowName.sevenDay] != nil else {
            return .failed(Issue(.checkFailed, .error, noWeekly))
        }
        if namedFiveHour && windows[WindowName.fiveHour] == nil {
            return .failed(Issue(.checkFailed, .error, noFiveHour))
        }
        // Name order, so which names stay never depends on the order the reply listed them in.
        let others = windows.keys.filter { !WindowName.picker.contains($0) }.sorted()
        for name in others.dropFirst(maxOtherWindows) { windows[name] = nil }

        var reading = Reading(readAt: readAt, windows: windows)
        if let fableWindow {
            reading.fable = FableReading(
                source: ReadingSource.probe, usedPercent: fableWindow.usedPercent,
                resetsAt: fableWindow.resetsAt, readAt: readAt,
                weeklyUsedPercentAtRead: windows[WindowName.sevenDay]?.usedPercent)
        }
        return .reading(reading)
    }

    /// Two entries of one reply for one window, merged by the rule of docs/ARCHITECTURE.md section
    /// 6.3. Both were read at the same moment, so a window a pick reads keeps the higher use of
    /// the two, in either order, with the reset time the merge chose; but when one entry's window
    /// had ended by then and the other's reset time is later or unknown, that other entry stands
    /// as it is, in either order.
    static func merged(_ earlier: WindowReading?, _ entry: WindowReading, name: String)
        -> WindowReading
    {
        var kept = ReadingMerge.window(
            stored: earlier, incoming: entry, now: entry.readAt, name: name)
        guard let earlier, ReadingMerge.readByPick.contains(name) else { return kept }
        if let later = laterWindow(earlier, entry, now: entry.readAt) { return later }
        kept.usedPercent = max(earlier.usedPercent, entry.usedPercent)
        return kept
    }

    /// The entry of the window that followed the other's: when one entry's reset time had passed
    /// at `now`, the other one, if its reset time is later or unknown. Nil otherwise.
    static func laterWindow(_ a: WindowReading, _ b: WindowReading, now: Date) -> WindowReading? {
        // An ended window's use says nothing about the window after it.
        func ended(_ old: WindowReading, before new: WindowReading) -> Bool {
            guard let end = old.resetsAt, end <= now else { return false }
            return (new.resetsAt ?? .distantFuture) > end
        }
        if ended(a, before: b) { return b }
        if ended(b, before: a) { return a }
        return nil
    }

    /// Converts a probe utilization (0 to 1) to percent (0 to 100, one decimal). A value that is
    /// not a number, or is outside 0 to 1, gives nil.
    static func percent(from value: Any) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let utilization = number.doubleValue
        guard utilization.isFinite, utilization >= 0, utilization <= 1 else { return nil }
        return Reading.round1(utilization * 100)
    }

    enum ResetParse: Equatable {
        case absent
        case valid(Date)
        case invalid
    }

    /// A probe reset time: absent or null is unknown, and anything else must be a date within the
    /// bounds of the window (`ResetBounds`). A malformed or out-of-range value is invalid, and the
    /// caller fails the reading.
    static func resetTime(_ raw: Any?, window: String, readAt: Date) -> ResetParse {
        guard let raw, !(raw is NSNull) else { return .absent }
        // Both the time given and the minute stored must be in range, so rounding never widens it.
        guard let given = AuthStatusReader.date(raw),
            ResetBounds.contains(given, window: window, readAt: readAt),
            let date = minute(given),
            ResetBounds.contains(date, window: window, readAt: readAt)
        else { return .invalid }
        return .valid(date)
    }

    /// A reset time to the minute, so the same window always compares equal.
    static func minute(_ date: Date?) -> Date? {
        date.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9_]{1,40}$", options: .regularExpression) != nil
    }
}

import Foundation

public enum ProbeReadResult: Equatable, Sendable {
    case reading(Reading)
    case failed(Issue)
}

/// Reads the output of the one-turn probe (docs/ARCHITECTURE.md section 6.2). It reads only the
/// `rate_limit_event` lines and the error fields of the final `result` line. Every other line is
/// dropped unread, so nothing personal in them can reach a reading.
public enum ProbeReader {
    static let maxWindows = 16
    static let authStatusCodes: Set<Int> = [401]
    static let authPhrases = [
        "invalid api key", "please run /login", "authentication", "unauthorized",
        "oauth token", "token has expired", "invalid bearer", "not logged in",
    ]

    public static func parse(_ output: String, readAt: Date) -> ProbeReadResult {
        var windows: [String: WindowReading] = [:]
        var fableWindow: WindowReading?
        var sawEvent = false
        var sawJSON = false
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
                for (name, raw) in found {
                    guard isValidName(name), let entry = raw as? [String: Any],
                        let utilization = entry["utilization"]
                    else { continue }
                    guard let percent = percent(from: utilization) else {
                        return .failed(
                            Issue(
                                .checkFailed, .error,
                                "Check failed: the probe gave a usage value outside 0 to 1."))
                    }
                    let resetsAt: Date?
                    switch resetTime(entry["resetsAt"], window: name, readAt: readAt) {
                    case .absent: resetsAt = nil
                    case .valid(let date): resetsAt = date
                    case .invalid:
                        return .failed(
                            Issue(
                                .checkFailed, .error,
                                "Check failed: the probe gave a reset time outside the window."))
                    }
                    sawEvent = true
                    let window = WindowReading(
                        usedPercent: percent, resetsAt: resetsAt, readAt: readAt)
                    if name == WindowName.fable {
                        fableWindow = ReadingMerge.window(
                            stored: fableWindow, incoming: window, now: readAt, name: name)
                    } else if windows[name] != nil || windows.count < maxWindows {
                        windows[name] = ReadingMerge.window(
                            stored: windows[name], incoming: window, now: readAt, name: name)
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
            return .failed(
                Issue(
                    .loginRejected, .error,
                    "Login rejected. Sign in to this account again, then run `agent-balancer refresh`."
                ))
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

        var reading = Reading(readAt: readAt, windows: windows)
        if let fableWindow {
            reading.fable = FableReading(
                source: ReadingSource.probe, usedPercent: fableWindow.usedPercent,
                resetsAt: fableWindow.resetsAt, readAt: readAt,
                weeklyUsedPercentAtRead: windows[WindowName.sevenDay]?.usedPercent)
        }
        return .reading(reading)
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
        guard let date = minute(AuthStatusReader.date(raw)),
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

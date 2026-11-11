import Foundation

/// Where a reading came from.
public enum ReadingSource {
    public static let probe = "probe"
    public static let estimate = "estimate"
}

/// Window names the tool knows. Others a probe reports are kept under their own name.
public enum WindowName {
    public static let fiveHour = "five_hour"
    public static let sevenDay = "seven_day"
    /// The Fable weekly meter (docs/ARCHITECTURE.md section 4A.6).
    public static let fable = "seven_day_overage_included"
}

/// One usage window: percent used (0 to 100, one decimal), when it resets and when the stored
/// value was taken.
public struct WindowReading: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    public var readAt: Date

    public init(usedPercent: Double, resetsAt: Date?, readAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.readAt = readAt
    }

    enum CodingKeys: String, CodingKey { case usedPercent, resetsAt, readAt }

    /// A stored reset time that does not decode reads as unknown, so one bad value does not make
    /// the whole file unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try c.decode(Double.self, forKey: .usedPercent)
        resetsAt = (try? c.decodeIfPresent(Date.self, forKey: .resetsAt)) ?? nil
        readAt = try c.decode(Date.self, forKey: .readAt)
    }
}

/// The Fable reading of one account. With `source` `probe`, `usedPercent` is a share of the Fable
/// cap. With `source` `estimate` only the bounds of section 7.4 are known.
public struct FableReading: Codable, Equatable, Sendable {
    public var source: String
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var readAt: Date?
    /// All-models weekly use when the probe was read, for the recheck rule.
    public var weeklyUsedPercentAtRead: Double?
    /// Estimate only: the most Fable can have used, in percent of the week.
    public var upToPercentOfWeekly: Double?
    /// Estimate only: Fable room that is guaranteed, in percent of the Fable cap.
    public var guaranteedRoomPercentOfCap: Double?

    public init(
        source: String, usedPercent: Double? = nil, resetsAt: Date? = nil, readAt: Date? = nil,
        weeklyUsedPercentAtRead: Double? = nil, upToPercentOfWeekly: Double? = nil,
        guaranteedRoomPercentOfCap: Double? = nil
    ) {
        self.source = source
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.readAt = readAt
        self.weeklyUsedPercentAtRead = weeklyUsedPercentAtRead
        self.upToPercentOfWeekly = upToPercentOfWeekly
        self.guaranteedRoomPercentOfCap = guaranteedRoomPercentOfCap
    }

    enum CodingKeys: String, CodingKey {
        case source, usedPercent, resetsAt, readAt, weeklyUsedPercentAtRead, upToPercentOfWeekly,
            guaranteedRoomPercentOfCap
    }

    /// A stored reset time that does not decode reads as unknown.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        usedPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercent)
        resetsAt = (try? c.decodeIfPresent(Date.self, forKey: .resetsAt)) ?? nil
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        weeklyUsedPercentAtRead = try c.decodeIfPresent(
            Double.self, forKey: .weeklyUsedPercentAtRead)
        upToPercentOfWeekly = try c.decodeIfPresent(Double.self, forKey: .upToPercentOfWeekly)
        guaranteedRoomPercentOfCap = try c.decodeIfPresent(
            Double.self, forKey: .guaranteedRoomPercentOfCap)
    }

    /// The fallback of section 7.4 for an account with no Fable probe reading. With `T` percent of
    /// the week used and a Fable cap of `cap` percent of the week, Fable used sits between 0 and
    /// `min(T, cap)`, and only `max(0, cap - T)` percent of the week is guaranteed.
    public static func estimate(weeklyUsedPercent t: Double, capPercentOfWeekly cap: Int)
        -> FableReading
    {
        let cap = Double(cap)
        let guaranteedWeek = max(0, cap - t)
        return FableReading(
            source: ReadingSource.estimate, upToPercentOfWeekly: Reading.round1(min(t, cap)),
            guaranteedRoomPercentOfCap: Reading.round1(guaranteedWeek / cap * 100))
    }
}

/// `state/readings/<label>.json`: the last reading of one account.
public struct Reading: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var source: String
    /// When the last probe that fed this reading finished. The age rule reads this one.
    public var readAt: Date
    /// By window name. The Fable window is not here; it is in `fable`.
    public var windows: [String: WindowReading]
    public var fable: FableReading?
    /// When the last Fable probe was tried, whether or not it gave a reading.
    public var fableProbedAt: Date?

    public init(
        source: String = ReadingSource.probe, readAt: Date, windows: [String: WindowReading] = [:],
        fable: FableReading? = nil, fableProbedAt: Date? = nil
    ) {
        self.schemaVersion = Reading.currentSchema
        self.source = source
        self.readAt = readAt
        self.windows = windows
        self.fable = fable
        self.fableProbedAt = fableProbedAt
    }

    public var fiveHour: WindowReading? { windows[WindowName.fiveHour] }
    public var sevenDay: WindowReading? { windows[WindowName.sevenDay] }

    /// Percent on the scale of section 6.1: 0 to 100 with one decimal.
    public static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// Younger than `maxAgeMinutes`, and not dated more than 60 seconds ahead.
    public func isFresh(now: Date, maxAgeMinutes: Int) -> Bool {
        let age = now.timeIntervalSince(readAt)
        return age >= -60 && age < Double(maxAgeMinutes) * 60
    }

    /// The reading without any stored use that is not a percent from 0 to 100. Such a value would
    /// hold a window at that use, because stored use never goes down.
    func sanitized() -> Reading {
        func valid(_ p: Double?) -> Bool { p.map { $0.isFinite && $0 >= 0 && $0 <= 100 } ?? true }
        var out = self
        out.windows = windows.filter { valid($0.value.usedPercent) }
        if let f = fable,
            !(valid(f.usedPercent) && valid(f.weeklyUsedPercentAtRead)
                && valid(f.upToPercentOfWeekly) && valid(f.guaranteedRoomPercentOfCap))
        {
            out.fable = nil
        }
        return out
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import Foundation

extension KeyedEncodingContainer {
    /// Encodes `null` for a missing value, so the key is always present in the document.
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}

/// One usage window of a status row (docs/ARCHITECTURE.md section 10.1).
public struct WindowStatus: Encodable, Equatable, Sendable {
    public var usedPercent: Double?
    public var resetsAt: Date?
    /// `probe`, `estimate` or `none`.
    public var source: String
    public var readAt: Date?

    public static let none = WindowStatus(
        usedPercent: nil, resetsAt: nil, source: "none", readAt: nil)

    private enum CodingKeys: String, CodingKey { case usedPercent, resetsAt, source, readAt }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(usedPercent, forKey: .usedPercent)
        try c.encodeNullable(resetsAt, forKey: .resetsAt)
        try c.encode(source, forKey: .source)
        try c.encodeNullable(readAt, forKey: .readAt)
    }
}

/// The Fable meter of a status row. With `source` `probe` only `usedPercent` and `resetsAt` are
/// set; with `estimate` only the two bounds are.
public struct FableStatus: Encodable, Equatable, Sendable {
    public var usedPercent: Double?
    public var guaranteedLeftPercentOfCap: Double?
    public var possibleLeftPercentOfCap: Double?
    public var resetsAt: Date?
    public var source: String

    private enum CodingKeys: String, CodingKey {
        case usedPercent, guaranteedLeftPercentOfCap, possibleLeftPercentOfCap, resetsAt, source
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(usedPercent, forKey: .usedPercent)
        try c.encodeNullable(guaranteedLeftPercentOfCap, forKey: .guaranteedLeftPercentOfCap)
        try c.encodeNullable(possibleLeftPercentOfCap, forKey: .possibleLeftPercentOfCap)
        try c.encodeNullable(resetsAt, forKey: .resetsAt)
        try c.encode(source, forKey: .source)
    }
}

public struct SessionStatus: Encodable, Equatable, Sendable {
    /// The first 8 characters of the session id.
    public var id: String
    public var name: String?

    private enum CodingKeys: String, CodingKey { case id, name }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeNullable(name, forKey: .name)
    }
}

/// Sessions running on an account. With `unknown` true the session records could not be read, so
/// `count` is null and `sessions` is empty.
public struct InUseStatus: Encodable, Equatable, Sendable {
    public var count: Int?
    public var sessions: [SessionStatus]
    public var unknown: Bool

    public static let unknownValue = InUseStatus(count: nil, sessions: [], unknown: true)

    private enum CodingKeys: String, CodingKey { case count, sessions, unknown }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(count, forKey: .count)
        try c.encode(sessions, forKey: .sessions)
        if unknown { try c.encode(true, forKey: .unknown) }
    }
}

/// An error or warning as it appears in a status row: a code and a scrubbed text.
public struct StatusIssue: Encodable, Equatable, Sendable {
    public var code: String
    public var text: String
}

public struct LimitedStatus: Encodable, Equatable, Sendable {
    /// `weekly`, `fable` or `fiveHour`.
    public var window: String
    public var since: Date
    public var until: Date?

    private enum CodingKeys: String, CodingKey { case window, since, until }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(window, forKey: .window)
        try c.encode(since, forKey: .since)
        try c.encodeNullable(until, forKey: .until)
    }
}

public struct ReserveStatus: Encodable, Equatable, Sendable {
    public var linePercent: Double
    public var marginPercent: Int
    public var launchAllowed: Bool
    public var daysLeft: Double?

    private enum CodingKeys: String, CodingKey {
        case linePercent, marginPercent, launchAllowed, daysLeft
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(linePercent, forKey: .linePercent)
        try c.encode(marginPercent, forKey: .marginPercent)
        try c.encode(launchAllowed, forKey: .launchAllowed)
        try c.encodeNullable(daysLeft, forKey: .daysLeft)
    }
}

/// One account of `status --json`.
public struct AccountStatus: Encodable, Equatable, Sendable {
    public var label: String
    public var email: String?
    public var role: String
    public var kind: String
    public var fullLogin: Bool
    public var configDir: String?
    public var accountKey: String
    public var endingSoon: Bool
    public var linked: Bool?
    public var state: String
    public var stateSince: Date?
    public var limited: LimitedStatus?
    public var error: StatusIssue?
    public var warnings: [StatusIssue]
    public var planTier: String?
    public var weekly: WindowStatus
    public var fable: FableStatus
    public var fiveHour: WindowStatus?
    public var readingsAge: Int?
    public var inUse: InUseStatus
    public var endsAt: String?
    public var loginExpiresAt: Date?
    public var loginExpiresSource: String?
    public var reserve: ReserveStatus?

    private enum CodingKeys: String, CodingKey {
        case label, email, role, kind, fullLogin, configDir, accountKey, endingSoon, linked, state,
            stateSince, limited, error, warnings, planTier, weekly, fable, fiveHour, readingsAge,
            inUse, endsAt, loginExpiresAt, loginExpiresSource, reserve
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encodeNullable(email, forKey: .email)
        try c.encode(role, forKey: .role)
        try c.encode(kind, forKey: .kind)
        try c.encode(fullLogin, forKey: .fullLogin)
        try c.encodeNullable(configDir, forKey: .configDir)
        try c.encode(accountKey, forKey: .accountKey)
        try c.encode(endingSoon, forKey: .endingSoon)
        try c.encodeNullable(linked, forKey: .linked)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(stateSince, forKey: .stateSince)
        try c.encodeNullable(limited, forKey: .limited)
        try c.encodeNullable(error, forKey: .error)
        try c.encode(warnings, forKey: .warnings)
        try c.encodeNullable(planTier, forKey: .planTier)
        try c.encode(weekly, forKey: .weekly)
        try c.encode(fable, forKey: .fable)
        try c.encodeNullable(fiveHour, forKey: .fiveHour)
        try c.encodeNullable(readingsAge, forKey: .readingsAge)
        try c.encode(inUse, forKey: .inUse)
        try c.encodeNullable(endsAt, forKey: .endsAt)
        try c.encodeNullable(loginExpiresAt, forKey: .loginExpiresAt)
        try c.encodeNullable(loginExpiresSource, forKey: .loginExpiresSource)
        try c.encodeNullable(reserve, forKey: .reserve)
    }
}

/// The account `pick` would choose with no leases, and why.
public struct NextChoice: Encodable, Equatable, Sendable {
    public var label: String?
    public var reason: String

    private enum CodingKeys: String, CodingKey { case label, reason }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(label, forKey: .label)
        try c.encode(reason, forKey: .reason)
    }
}

public struct NextStatus: Encodable, Equatable, Sendable {
    public var all: NextChoice
    public var fable: NextChoice
}

/// `status --json` and `state/status.json` (docs/ARCHITECTURE.md section 10.1).
public struct StatusDocument: Encodable, Equatable, Sendable {
    public static let currentSchema = 1

    public var generatedAt: Date
    /// One banner for the whole setup, such as `settings_changed`.
    public var banner: StatusIssue?
    public var accounts: [AccountStatus]
    public var next: NextStatus

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, banner, accounts, next
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchema, forKey: .schemaVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encodeNullable(banner, forKey: .banner)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(next, forKey: .next)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

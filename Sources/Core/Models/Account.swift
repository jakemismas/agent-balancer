import Foundation

/// The three account kinds and two roles of docs/ARCHITECTURE.md section 4A.1. Stored as plain
/// strings so a bad value gives a clear message from the validator instead of a decode failure.
public enum Kind {
    public static let login = "login"
    public static let token = "token"
    public static let folder = "folder"
    public static let all = [login, token, folder]
}

public enum Role {
    public static let main = "main"
    public static let pool = "pool"
    public static let all = [main, pool]
}

public struct ReservePoint: Codable, Equatable, Sendable {
    public var daysLeft: Int
    public var maxUsedPercent: Int

    public init(daysLeft: Int, maxUsedPercent: Int) {
        self.daysLeft = daysLeft
        self.maxUsedPercent = maxUsedPercent
    }
}

public struct Reserve: Codable, Equatable, Sendable {
    public var points: [ReservePoint]
    public var marginPercent: Int
    public var allowAbove90: Bool?

    public init(points: [ReservePoint], marginPercent: Int, allowAbove90: Bool? = nil) {
        self.points = points
        self.marginPercent = marginPercent
        self.allowAbove90 = allowAbove90
    }

    /// 5 days 50, 2 days 90, margin 5.
    public static let standard = Reserve(
        points: [
            ReservePoint(daysLeft: 5, maxUsedPercent: 50),
            ReservePoint(daysLeft: 2, maxUsedPercent: 90),
        ], marginPercent: 5)

    public var summary: String {
        let pts = points.map { "\($0.daysLeft) days \($0.maxUsedPercent)" }.joined(separator: ", ")
        return "\(pts), margin \(marginPercent)"
    }
}

/// Per-account Fable options (docs/ARCHITECTURE.md section 7.1).
public struct AccountFable: Codable, Equatable, Sendable {
    public var allowLaunches: Bool

    public init(allowLaunches: Bool = true) {
        self.allowLaunches = allowLaunches
    }
}

public struct Account: Codable, Equatable, Sendable {
    public var label: String
    public var kind: String
    public var role: String
    public var email: String?
    public var expectedPlanTier: String?
    /// A random id, no secret. A label removed and added again never mixes with the old one.
    public var accountKey: String
    public var reserve: Reserve?
    public var endsAt: String?
    public var endingSoon: Bool?
    public var fable: AccountFable?
    /// When the account's current token was saved, as an ISO 8601 time. Token accounts only. The
    /// estimate of the token's end counts from it.
    public var tokenCreatedAt: String?
    /// Usage windows, by their reading names, that the user says this plan has no limit on.
    public var noLimit: [String]?

    public init(
        label: String, kind: String, role: String, email: String? = nil,
        expectedPlanTier: String? = nil, accountKey: String = Account.makeKey(),
        reserve: Reserve? = nil, endsAt: String? = nil, endingSoon: Bool? = nil,
        fable: AccountFable? = nil, tokenCreatedAt: String? = nil, noLimit: [String]? = nil
    ) {
        self.label = label
        self.kind = kind
        self.role = role
        self.email = email
        self.expectedPlanTier = expectedPlanTier
        self.accountKey = accountKey
        self.reserve = reserve
        self.endsAt = endsAt
        self.endingSoon = endingSoon
        self.fable = fable
        self.tokenCreatedAt = tokenCreatedAt
        self.noLimit = noLimit
    }

    public static func makeKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
        }
        .joined()
    }
}

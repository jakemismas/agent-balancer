import Foundation

/// The one seam every account kind implements. This file is the only place that branches on kind.
public protocol AccountKindHandler: Sendable {
    var kind: String { get }

    /// The sign-in state of one account: its errors and warnings, plus what it read.
    func check(account: Account, runner: ClaudeRunner, now: Date) -> AccountCheck
}

public struct AccountCheck: Sendable {
    public var issues: [Issue]
    public var planTier: String?
    public var loginExpiresAt: Date?
    public var signedIn: Bool

    public init(
        issues: [Issue] = [], planTier: String? = nil, loginExpiresAt: Date? = nil,
        signedIn: Bool = false
    ) {
        self.issues = issues
        self.planTier = planTier
        self.loginExpiresAt = loginExpiresAt
        self.signedIn = signedIn
    }

    public var hasError: Bool { issues.contains { $0.severity == .error } }
}

public enum AccountKinds {
    /// The handler for a kind this version implements, or nil for one that arrives later.
    public static func handler(for kind: String) -> AccountKindHandler? {
        switch kind {
        case Kind.login: return LoginKind()
        default: return nil
        }
    }
}

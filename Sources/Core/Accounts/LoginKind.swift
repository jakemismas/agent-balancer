import Foundation

/// The `login` kind: the login Claude Code already stores for the default folder.
public struct LoginKind: AccountKindHandler {
    public let kind = Kind.login
    static let expiryWarningDays = 7.0

    public init() {}

    public func check(account: Account, runner: ClaudeRunner, now: Date) -> AccountCheck {
        switch AuthStatusReader.read(runner: runner) {
        case .failed(let issue):
            return AccountCheck(issues: [issue])
        case .status(let status):
            return Self.evaluate(status, account: account, now: now)
        }
    }

    /// Maps a reading to the codes of docs/ARCHITECTURE.md section 9 for a login account.
    public static func evaluate(_ status: AuthStatus, account: Account, now: Date) -> AccountCheck {
        guard status.loggedIn else {
            return AccountCheck(
                issues: [
                    Issue(
                        .loginRejected, .error,
                        "Login rejected. Run `claude` and sign in again, then run `agent-balancer doctor`."
                    )
                ])
        }
        var check = AccountCheck(
            planTier: status.planTier, loginExpiresAt: status.loginExpiresAt, signedIn: true)
        if let expected = account.email, let actual = status.email,
            expected.lowercased() != actual.lowercased()
        {
            check.issues.append(
                Issue(.wrongAccount, .error, "Folder is logged in as another account."))
        }
        if let expected = account.expectedPlanTier, status.planTier != expected {
            let actual = status.planTier ?? "unknown"
            check.issues.append(
                Issue(
                    .planChanged, .error,
                    "Plan is \(Display.safe(actual, limit: 40)), expected \(Display.safe(expected, limit: 40))."
                ))
        }
        if let expires = status.loginExpiresAt {
            let days = expires.timeIntervalSince(now) / 86_400
            if days <= expiryWarningDays {
                check.issues.append(
                    Issue(.loginExpiring, .warning, "Login expires \(shortDate(expires))."))
            }
        }
        return check
    }

    public static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

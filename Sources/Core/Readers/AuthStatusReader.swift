import Foundation

/// The fields of `claude auth status` the tool maps. Nothing else is kept.
public struct AuthStatus: Equatable, Sendable {
    public var loggedIn: Bool
    public var email: String?
    public var planTier: String?
    public var subscriptionType: String?
    public var loginExpiresAt: Date?
    public var configDirectory: String?

    public init(
        loggedIn: Bool, email: String? = nil, planTier: String? = nil,
        subscriptionType: String? = nil, loginExpiresAt: Date? = nil, configDirectory: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.email = email
        self.planTier = planTier
        self.subscriptionType = subscriptionType
        self.loginExpiresAt = loginExpiresAt
        self.configDirectory = configDirectory
    }
}

public enum AuthReadResult: Sendable {
    case status(AuthStatus)
    case failed(Issue)
}

public enum AuthStatusReader {
    /// Maps one `auth status` JSON document. Returns nil when the text is not a JSON object or
    /// carries no `loggedIn` flag.
    public static func parse(_ text: String) -> AuthStatus? {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let loggedIn = object["loggedIn"] as? Bool
        else { return nil }
        func string(_ key: String) -> String? {
            guard let s = object[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        return AuthStatus(
            loggedIn: loggedIn, email: string("email"), planTier: string("planTier"),
            subscriptionType: string("subscriptionType"),
            loginExpiresAt: date(object["loginExpiresAt"]),
            configDirectory: string("configDirectory"))
    }

    /// ISO 8601 text, or a number of seconds or milliseconds since 1970.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let plain = ISO8601DateFormatter()
            if let d = plain.date(from: text) { return d }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text)
        }
        if let number = value as? Double {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        return nil
    }

    /// Runs `claude auth status` for a folder (nil is the default folder). Exit 1 with JSON reads
    /// as logged out, not as a failed check.
    public static func read(
        runner: ClaudeRunner, configDir: URL? = nil, timeout: TimeInterval = 60
    ) -> AuthReadResult {
        let output: RunOutput
        do {
            output = try runner.run(
                arguments: ["auth", "status", "--json"], configDir: configDir, timeout: timeout)
        } catch let error as ToolError {
            return .failed(Issue(.checkFailed, .error, "Check failed: \(error.message)"))
        } catch {
            return .failed(Issue(.checkFailed, .error, "Check failed: claude could not run."))
        }
        if output.timedOut {
            return .failed(
                Issue(
                    .checkFailed, .error,
                    "Check failed: auth status timed out after \(Int(timeout)) s."))
        }
        guard var status = parse(output.stdout) else {
            return .failed(
                Issue(
                    .checkFailed, .error,
                    "Check failed: auth status gave output that is not JSON (exit \(output.status))."
                ))
        }
        if output.status != 0 { status.loggedIn = false }
        return .status(status)
    }
}

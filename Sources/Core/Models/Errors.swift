import Foundation

/// Error and warning codes of the states table (docs/ARCHITECTURE.md section 9).
public enum StateCode: String, Codable, Sendable {
    case loginRejected = "login_rejected"
    case wrongAccount = "wrong_account"
    case duplicateLogin = "duplicate_login"
    case settingsChanged = "settings_changed"
    case planChanged = "plan_changed"
    case accountEnded = "account_ended"
    case checkFailed = "check_failed"
    case limited
    case fableLimited = "fable_limited"
    case loginExpiring = "login_expiring"
    case tokenMissing = "token_missing"
    case notLinked = "not_linked"
    case possibleDuplicate = "possible_duplicate"
    case keyInSettings = "key_in_settings"
    case stale
    /// A live session names a launch file that is gone. A count only: no event, no path.
    case launchFileMissing = "launch_file_missing"
}

public enum Severity: String, Sendable {
    case error
    case warning
}

/// One error or warning on an account or on the setup, with scrubbed text.
public struct Issue: Equatable, Sendable {
    public let code: StateCode
    public let severity: Severity
    public let text: String

    public init(_ code: StateCode, _ severity: Severity, _ text: String) {
        self.code = code
        self.severity = severity
        self.text = text
    }
}

/// A failure with a message that is safe to print as is.
public struct ToolError: Error, LocalizedError, Equatable, Sendable {
    public let code: StateCode?
    public let message: String

    public init(_ message: String, code: StateCode? = nil) {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }
}

public enum Messages {
    public static let chatShellRefusal =
        "Run this in your own terminal, outside a Claude Code session."
    public static let hookRecordMissing =
        "Hook record missing. Run `agent-balancer link --accept-source-change` in Terminal."
    public static let settingsChanged =
        "Settings changed. Run `agent-balancer link --accept-source-change` in Terminal."
    public static let keyInSettings =
        "Settings carry an API key or key helper. Token accounts are skipped."
    public static let notSetUp = "Setup has not run. Run `agent-balancer init`."

    /// The `token_missing` text, the same for a token file that is absent, not private or does
    /// not parse (docs/ARCHITECTURE.md section 9).
    public static func tokenMissing(_ label: String) -> String {
        "No token saved. Run `agent-balancer login \(Display.safe(label, limit: 32))` in Terminal."
    }
}

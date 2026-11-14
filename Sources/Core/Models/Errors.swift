import Foundation

/// Error and warning codes of the states table (docs/ARCHITECTURE.md section 9).
public enum StateCode: String, Codable, Sendable, CaseIterable {
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
    /// A consent command asked for a typed answer where no person can type one.
    public static let terminalRequired =
        "Applying needs an interactive terminal. Run this in your own terminal and type the label (or `accept`) when asked. Nothing was changed."
    public static let chatShellRefusal =
        "Run this in your own terminal, outside a Claude Code session."

    /// `remove` of the main account where no person is at a terminal, such as from the menu app.
    public static func removeMainNeedsTerminal(_ label: String) -> String {
        let safe = Display.safe(label, limit: 32)
        return
            "'\(safe)' is the main account. Removing it needs your own terminal: run `agent-balancer remove \(safe)` in Terminal. Nothing was changed."
    }
    public static let hookRecordMissing =
        "Hook record missing. Run `agent-balancer link --accept-source-change` in Terminal."
    public static let settingsChanged =
        "Settings changed. Run `agent-balancer link --accept-source-change` in Terminal."
    /// The same two texts when a folder account is affected too: `--all` covers every linked folder.
    public static let hookRecordMissingAll =
        "Hook record missing. Run `agent-balancer link --accept-source-change --all` in Terminal."
    public static let settingsChangedAll =
        "Settings changed. Run `agent-balancer link --accept-source-change --all` in Terminal."
    /// `run` found no verdict that matches the settings file as it is now.
    public static let settingsNotChecked =
        "Settings changed since the last check. Run `agent-balancer doctor` in Terminal."
    public static let keyInSettings =
        "Settings carry an API key or key helper. Token accounts are skipped."
    public static let notSetUp = "Setup has not run. Run `agent-balancer init`."

    public static func notLinked(_ label: String) -> String {
        "Settings not shared. Run `agent-balancer link \(Display.safe(label, limit: 32))` in Terminal."
    }

    public static func linkBroken(_ label: String) -> String {
        "A shared link is broken. Run `agent-balancer link --repair \(Display.safe(label, limit: 32))` in Terminal. If repair refuses, fix the item it names, in the default folder or in the account folder, then run it again."
    }

    public static let oneAccountPerFolder =
        "Never sign a different account into a folder that already has chats. Add a new folder for the new account instead."

    /// `login --browser` for a folder whose expected email fails `ConfigValidator.isPlainEmail`.
    public static func emailNotPlain(_ label: String) -> String {
        "The expected email of '\(Display.safe(label, limit: 32))' cannot be passed to claude safely. Fix it with `agent-balancer config set`."
    }

    /// The `wrong_account` text, and the one step that fixes it.
    public static let wrongAccount = "Folder is logged in as another account."
    public static let signExpectedBackIn =
        "Sign the expected account back in to this folder. Do not relabel the folder."

    public static let trustStep =
        "Open `claude` once in each project folder on that account, so the folder is trusted there."
    public static let notCarriedOver =
        "MCP servers and plugins do not carry over to a folder account. Add them in that folder."

    /// The `token_missing` text, the same for a token file that is absent, not private or does
    /// not parse (docs/ARCHITECTURE.md section 9).
    public static func tokenMissing(_ label: String) -> String {
        "No token saved. Run `agent-balancer login \(Display.safe(label, limit: 32))` in Terminal."
    }
}

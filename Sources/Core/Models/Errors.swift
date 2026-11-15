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
    /// The default folder's settings path is a link to nothing, which no reader can clear.
    public static let settingsLinkGoesNowhere =
        "The default folder's settings file is a link that goes nowhere. Repair the link or remove it, then run `agent-balancer doctor` in Terminal."
    /// The default folder's settings path is a folder or another entry that is not a file.
    public static let settingsNotAFile =
        "The default folder's settings file is not a file. Replace it with a file or remove it, then run `agent-balancer doctor` in Terminal."
    /// A link change whose settings verdict failed or changed after the typed approval.
    public static let settingsMovedAfterApproval =
        "The default folder's settings changed after you approved, so nothing was changed."
    public static let keyInSettings =
        "Settings carry an API key or key helper. Every account is skipped."
    public static let notSetUp = "Setup has not run. Run `agent-balancer init`."

    public static func notLinked(_ label: String) -> String {
        "Settings not shared. Run `agent-balancer link \(Display.safe(label, limit: 32))` in Terminal."
    }

    public static func linkBroken(_ label: String) -> String {
        "A shared link is broken. Run `agent-balancer link --repair \(Display.safe(label, limit: 32))` in Terminal. If repair refuses, fix the item it names, in the default folder or in the account folder, then run it again."
    }

    public static let oneAccountPerFolder =
        "Never sign a different account into a folder that already has chats. Add a new folder for the new account instead."

    /// `login` over a folder sign-in its last probe found rejected, when the run cannot show that
    /// it signed the folder in again.
    public static func signInNotRenewed(_ label: String) -> String {
        let safe = Display.safe(label, limit: 32)
        return
            "This run did not show a new sign-in, so the probe's rejection stands. Run `agent-balancer login \(safe) --browser`, or `agent-balancer refresh --label \(safe) --force` once it is signed in."
    }

    /// `login --browser` for a folder whose expected email fails `ConfigValidator.isPlainEmail`.
    public static func emailNotPlain(_ label: String) -> String {
        "The expected email of '\(Display.safe(label, limit: 32))' cannot be passed to claude safely. Fix it with `agent-balancer config set`."
    }

    /// The `wrong_account` text, and the one step that fixes it.
    public static let wrongAccount = "Folder is logged in as another account."
    /// A sign-in that reports no email cannot be matched to the account's expected email.
    public static let signInEmailMissing =
        "Check failed: the sign-in reported no email, so it could not be confirmed as this account."
    /// A login or folder account that holds no email cannot be checked against its sign-in.
    public static let emailNotRecorded =
        "Check failed: no email is recorded for this account, so its sign-in cannot be confirmed."
    public static let signExpectedBackIn =
        "Sign the expected account back in to this folder. Do not relabel the folder."
    /// The same step for a login account, the default folder's own sign-in.
    public static let signExpectedBackInLogin =
        "Run claude and sign the expected account back in."

    /// `uninstall` with a data folder that is a link, which it never follows.
    public static let uninstallDataFolderIsALink = uninstallFolderIsALink(
        "The data folder", "~/.agent-balancer")
    /// `uninstall` with something other than a folder where the data folder belongs.
    public static let uninstallDataFolderIsNotAFolder = uninstallFolderIsNotAFolder(
        "~/.agent-balancer")
    /// `uninstall` with a data folder that another user owns.
    public static let uninstallDataFolderIsNotYours =
        "The data folder `~/.agent-balancer` belongs to another user, so `uninstall` cannot check what the tool made there. Nothing was removed. Run `agent-balancer uninstall` as that user."

    /// `uninstall` with a link where a folder of the tool belongs, which it never follows.
    /// `place` is the folder's path as the person types it.
    public static func uninstallFolderIsALink(_ subject: String, _ place: String) -> String {
        "\(subject) `\(place)` is a link, and `uninstall` never follows one, so it cannot check what the tool made. Nothing was removed. Move the folder it points to back in place of the link, or delete the link if that folder is gone, then run `agent-balancer uninstall` again."
    }

    /// `uninstall` with something other than a folder or a link where a folder of the tool
    /// belongs.
    public static func uninstallFolderIsNotAFolder(_ place: String) -> String {
        "`\(place)` is not a folder, and the tool only ever makes a folder there, so `uninstall` cannot check it. Nothing was removed. Check what it is and move it away, then run `agent-balancer uninstall` again."
    }

    /// Why `uninstall` refuses `entry` where the folder `place` in the data folder belongs, or nil
    /// when it is missing or a real folder of the user's that passes the folder checks.
    public static func uninstallRefusal(
        _ subject: String, _ place: String, _ entry: NoFollowWriter.PlaceEntry
    ) -> String? {
        switch entry {
        case .missing, .folder:
            return nil
        case .link:
            return uninstallFolderIsALink(subject, place)
        case .notFolder:
            return uninstallFolderIsNotAFolder(place)
        case .notYours:
            return
                "\(subject) `\(place)` belongs to another user, so `uninstall` cannot check what the tool made in it. Nothing was removed. Move it out of `~/.agent-balancer`, then run `agent-balancer uninstall` again."
        case .problem(let problem):
            return uninstallFolderRefused(subject, place, problem)
        }
    }

    /// `uninstall` with a folder of the user's that fails the folder checks. `place` is the
    /// folder's path as the person types it.
    public static func uninstallFolderRefused(
        _ subject: String, _ place: String, _ problem: NoFollowWriter.FolderProblem
    ) -> String {
        let what =
            problem == .widerThanPrivate ? "is wider than 0700" : "cannot be opened or searched"
        return
            "\(subject) `\(place)` \(what), so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod 700 \(place)`, then run `agent-balancer uninstall` again."
    }

    public static let trustStep =
        "Open `claude` once in each project folder on that account, so the folder is trusted there."
    public static let notCarriedOver =
        "MCP servers and plugins do not carry over to a folder account. Add them in that folder."

    /// The `token_missing` text, the same for a token file that is absent, not private or does
    /// not parse (docs/ARCHITECTURE.md section 9).
    public static func tokenMissing(_ label: String) -> String {
        "No token saved. Run `agent-balancer login \(Display.safe(label, limit: 32))` in Terminal."
    }

    /// The `login_rejected` text of a probe that got an auth error: what a token account's status
    /// row shows unless the account is marked ending soon, and what `run` refuses such an account
    /// with.
    public static let probeLoginRejected =
        "Login rejected. Sign in to this account again, then run `agent-balancer refresh`."
}

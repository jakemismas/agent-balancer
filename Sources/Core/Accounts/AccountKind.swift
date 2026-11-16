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
    /// `Account.emailDigest` of the account the check was made for, also when it read no status.
    public var emailDigest: String?

    public init(
        issues: [Issue] = [], planTier: String? = nil, loginExpiresAt: Date? = nil,
        signedIn: Bool = false, emailDigest: String? = nil
    ) {
        self.issues = issues
        self.planTier = planTier
        self.loginExpiresAt = loginExpiresAt
        self.signedIn = signedIn
        self.emailDigest = emailDigest
    }

    public var hasError: Bool { issues.contains { $0.severity == .error } }
}

extension Account {
    /// What a sign-in check of this account is bound to: a digest of its account key and its
    /// expected email, lowercased as the check compares it, so the email itself is never stored.
    public var emailDigest: String {
        HookRecord.sha256(accountKey + "\u{0}" + (email?.lowercased() ?? ""))
    }
}

public enum AccountKinds {
    /// The handler for a kind this version implements, or nil for one that arrives later.
    public static func handler(for kind: String) -> AccountKindHandler? {
        switch kind {
        case Kind.login: return LoginKind()
        case Kind.folder: return FolderKind()
        default: return nil
        }
    }
}

/// What a probe of one account adds to the plain probe form of section 6.2.
public struct ProbeContext: Sendable {
    /// Arguments after the plain form. For a token account, `--settings <token file path>`.
    public var extraArguments: [String]
    /// The folder for `CLAUDE_CONFIG_DIR`, or nil to leave it unset.
    public var configDir: URL?
    /// True when the reading cache calls its `afterProbe` hook for this account.
    public var callsAfterProbeHook: Bool

    public init(
        extraArguments: [String] = [], configDir: URL? = nil, callsAfterProbeHook: Bool = false
    ) {
        self.extraArguments = extraArguments
        self.configDir = configDir
        self.callsAfterProbeHook = callsAfterProbeHook
    }
}

extension AccountKinds {
    /// How one account is probed, by kind. A kind this version does not probe throws.
    public static func probeContext(for account: Account, context: ToolContext) throws
        -> ProbeContext
    {
        switch account.kind {
        case Kind.login: return ProbeContext()
        case Kind.token: return try TokenKind.probeContext(account: account, context: context)
        case Kind.folder:
            guard FolderPaths.state(context: context, label: account.label) == .ready else {
                throw ToolError(
                    "Account '\(Display.safe(account.label))': its folder is missing or is a link.",
                    code: .checkFailed)
            }
            return ProbeContext(
                configDir: try FolderPaths.configDir(context: context, label: account.label))
        default:
            throw ToolError(
                "Account '\(Display.safe(account.label))': this kind is not probed in this version.",
                code: .checkFailed)
        }
    }
}

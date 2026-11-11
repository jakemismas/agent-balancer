import Foundation

/// A code and a scrubbed text, as kept in `state/current.json`.
public struct IssueRecord: Codable, Equatable, Sendable {
    public var code: String
    public var text: String

    init(_ issue: Issue) {
        code = issue.code.rawValue
        text = issue.text
    }
}

/// What the tool last saw of one account: its state, since when, and what it needs to tell a
/// change from a repeat. It holds labels, codes, times and scrubbed texts only.
public struct CurrentEntry: Codable, Equatable, Sendable {
    public var accountKey: String
    public var state: String
    public var code: String?
    public var since: Date
    public var limitedWindow: String?
    public var limitedSince: Date?
    public var limitedUntil: Date?
    public var lastReadingAt: Date?
    /// The last error from a sign-in check (`auth status`).
    public var authError: IssueRecord?
    /// The last error from a probe.
    public var probeError: IssueRecord?
    public var planTier: String?
    public var loginExpiresAt: Date?
    /// An account marked `endingSoon` whose plan tier dropped. It stays set until the mark is off.
    public var endedByPlan: Bool
    /// The expiry date a `login_expiring` event was written for.
    public var expiringNotified: String?
    public var historyAt: Date?
    public var historySignature: String?
    /// The other label the last duplicate check of a token account matched, from the
    /// `afterProbe` hook. It stays until the account's next probe checks again.
    public var possibleDuplicateOf: String?
}

/// What the default folder's settings showed the last time a command allowed to read them did.
public struct SettingsMemory: Codable, Equatable, Sendable {
    /// `missing` (no hook record), `changed` (a recorded hook is gone), or nil.
    public var issue: String?
    public var carriesKey: Bool

    public init(issue: String? = nil, carriesKey: Bool = false) {
        self.issue = issue
        self.carriesKey = carriesKey
    }
}

/// `state/current.json`.
public struct CurrentFile: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion: Int = CurrentFile.currentSchema
    public var settings: SettingsMemory?
    /// By label.
    public var accounts: [String: CurrentEntry] = [:]
    public var prunedAt: Date?

    public init() {}

    static let stateNames: Set<String> = ["ok", "limited", "error", "ended"]
    static let windowNames: Set<String> = ["weekly", "fiveHour"]

    /// False when a label or a value that later reaches a terminal, an event or a status field is
    /// not one the tool could have written. Such a file is a damaged record.
    var isSound: Bool {
        for (label, entry) in accounts {
            guard ConfigValidator.isValidLabel(label), Self.stateNames.contains(entry.state),
                entry.code.map({ StateCode(rawValue: $0) != nil }) ?? true,
                entry.limitedWindow.map(Self.windowNames.contains) ?? true,
                entry.planTier.map(AuthStatusReader.isPlainTier) ?? true,
                entry.expiringNotified.map(ConfigValidator.isValidDate) ?? true,
                entry.possibleDuplicateOf.map(ConfigValidator.isValidLabel) ?? true,
                [entry.authError, entry.probeError].allSatisfy({
                    $0.map { StateCode(rawValue: $0.code) != nil } ?? true
                })
            else { return false }
        }
        return true
    }
}

/// A sign-in check of one account (`auth status`), reduced to what the status needs.
public struct AuthObservation: Sendable {
    public var error: Issue?
    public var planTier: String?
    public var loginExpiresAt: Date?
    public var signedIn: Bool

    public init(error: Issue?, planTier: String?, loginExpiresAt: Date?, signedIn: Bool) {
        self.error = error
        self.planTier = planTier
        self.loginExpiresAt = loginExpiresAt
        self.signedIn = signedIn
    }

    public init(_ check: AccountCheck) {
        self.init(
            error: check.issues.first { $0.severity == .error }, planTier: check.planTier,
            loginExpiresAt: check.loginExpiresAt, signedIn: check.signedIn)
    }
}

/// The result of a probe of one account. A nil error means the probe worked.
public struct ProbeObservation: Sendable {
    public var error: Issue?

    public init(error: Issue?) {
        self.error = error
    }
}

public struct SettingsObservation: Sendable {
    public var issue: String?
    public var carriesKey: Bool

    public init(issue: String?, carriesKey: Bool) {
        self.issue = issue
        self.carriesKey = carriesKey
    }
}

/// What the command that triggers a rebuild saw this time. Anything it did not look at is carried
/// over from `state/current.json`.
public struct StatusObservations: Sendable {
    public var auth: [String: AuthObservation] = [:]
    public var probe: [String: ProbeObservation] = [:]
    public var settings: SettingsObservation?
    /// Labels whose token was replaced by the command that triggers this rebuild.
    public var tokenReplaced: Set<String> = []
    /// What the duplicate check found for each token account a probe of this command read.
    public var duplicates: [String: DuplicateCheck] = [:]

    public init(
        auth: [String: AuthObservation] = [:], probe: [String: ProbeObservation] = [:],
        settings: SettingsObservation? = nil
    ) {
        self.auth = auth
        self.probe = probe
        self.settings = settings
    }

    /// The probes of a refresh, by label.
    public mutating func add(_ results: [AccountRefresh]) {
        for result in results {
            // Only a probe that ran says anything; a stored or fresh reading leaves it unobserved.
            switch result.status {
            case .failed(let issue): probe[result.label] = ProbeObservation(error: issue)
            case .probed: probe[result.label] = ProbeObservation(error: nil)
            case .fresh, .usedStored: break
            }
            if result.duplicate != .notRun { duplicates[result.label] = result.duplicate }
        }
    }
}

/// The state of one account worked out from its reading and what was observed, and the rule that
/// turns a change of it into an event (docs/ARCHITECTURE.md sections 9 and 10.3).
enum Transitions {
    struct Input {
        var account: Account
        var reading: Reading?
        var entry: CurrentEntry
        var settings: SettingsMemory
        var duplicateOf: String?
        var possibleDuplicateOf: String? = nil
        var tokenUsable: Bool
        var tokenModified: Date?
        var config: Config
        var now: Date
    }

    struct Evaluation {
        var state: String
        var error: Issue?
        var warnings: [Issue]
        var limitedWindow: String?
        var limitedUntil: Date?
        var loginExpiresAt: Date?
        var loginExpiresSource: String?
    }

    static let tokenLifeDays = 365.0

    static func clean(_ text: String) -> String {
        Display.safe(Scrubber.scrubText(text), limit: 200)
    }

    /// The entry with this run's observations folded in. The state fields are not touched.
    static func observed(
        _ previous: CurrentEntry?, account: Account, auth: AuthObservation?,
        probe: ProbeObservation?, duplicate: DuplicateCheck = .notRun, now: Date
    ) -> CurrentEntry {
        var entry =
            previous
            ?? CurrentEntry(
                accountKey: account.accountKey, state: "ok", code: nil, since: now,
                endedByPlan: false)
        entry.accountKey = account.accountKey
        if let auth {
            entry.authError = auth.error.map {
                IssueRecord(Issue($0.code, $0.severity, clean($0.text)))
            }
            if auth.signedIn {
                entry.planTier = auth.planTier
                entry.loginExpiresAt = auth.loginExpiresAt
                if entry.probeError?.code == StateCode.loginRejected.rawValue {
                    entry.probeError = nil
                }
                if account.endingSoon == true, let expected = account.expectedPlanTier,
                    auth.planTier != expected
                {
                    entry.endedByPlan = true
                }
            }
        }
        if let probe {
            entry.probeError = probe.error.map {
                IssueRecord(Issue($0.code, $0.severity, clean($0.text)))
            }
            if probe.error == nil && entry.authError?.code == StateCode.loginRejected.rawValue {
                entry.authError = nil
            }
        }
        switch duplicate {
        case .notRun: break
        case .clear: entry.possibleDuplicateOf = nil
        case .sameAs(let other): entry.possibleDuplicateOf = other
        }
        if account.kind != Kind.token { entry.possibleDuplicateOf = nil }
        if account.endingSoon != true { entry.endedByPlan = false }
        return entry
    }

    static func evaluate(_ input: Input) -> Evaluation {
        let account = input.account
        let entry = input.entry
        let config = input.config
        let now = input.now
        let ending = account.endingSoon == true

        var errors: [Issue] = []
        func add(_ code: StateCode, _ text: String) {
            errors.append(Issue(code, .error, clean(text)))
        }
        for record in [entry.authError, entry.probeError].compactMap({ $0 }) {
            guard let code = StateCode(rawValue: record.code) else { continue }
            if code == .planChanged && ending { continue }
            if code == .loginRejected && ending {
                add(
                    code,
                    "Login rejected, or the plan has ended. Sign in again in Terminal; if it will not sign in, the plan has ended."
                )
            } else {
                add(code, record.text)
            }
        }
        if let issue = input.settings.issue {
            add(
                .settingsChanged,
                issue == "missing" ? Messages.hookRecordMissing : Messages.settingsChanged)
        }
        if account.kind == Kind.token && !input.tokenUsable {
            add(.tokenMissing, Messages.tokenMissing(account.label))
        }
        if let other = input.duplicateOf {
            add(
                .duplicateLogin,
                "Logged in as the same account as \(other). Log one folder into its own account.")
        }
        let order: [StateCode] = [
            .loginRejected, .settingsChanged, .tokenMissing, .wrongAccount, .duplicateLogin,
            .planChanged, .checkFailed,
        ]
        errors.sort {
            (order.firstIndex(of: $0.code) ?? order.count)
                < (order.firstIndex(of: $1.code) ?? order.count)
        }

        var warnings: [Issue] = []
        var expires: Date?
        var source: String?
        var threshold = 7.0
        if account.kind == Kind.token {
            if input.tokenUsable,
                let start = TokenKind.createdAt(account, fileModified: input.tokenModified)
            {
                expires = start.addingTimeInterval(tokenLifeDays * 86_400)
                source = "estimate"
            }
            threshold = 14
        } else if let at = entry.loginExpiresAt {
            expires = at
            source = "auth"
        }
        if let expires, expires.timeIntervalSince(now) / 86_400 <= threshold {
            warnings.append(
                Issue(.loginExpiring, .warning, "Login expires \(LoginKind.shortDate(expires))."))
        }

        let limitedAt = Double(config.picker.limitedAtPercent)
        var over: [(String, WindowReading)] = []
        if let w = input.reading?.sevenDay, w.usedPercent >= limitedAt {
            over.append(("weekly", w))
        }
        if let w = input.reading?.fiveHour, w.usedPercent >= limitedAt {
            over.append(("fiveHour", w))
        }
        let limit = over.max {
            ($0.1.resetsAt ?? .distantPast) < ($1.1.resetsAt ?? .distantPast)
        }

        if let fable = input.reading?.fable, fable.source == ReadingSource.probe,
            let used = fable.usedPercent, used >= limitedAt
        {
            warnings.append(
                Issue(
                    .fableLimited, .warning,
                    "Fable limited until \(Picker.shortTime(fable.resetsAt))."))
        }
        if account.kind == Kind.token, let other = input.possibleDuplicateOf {
            warnings.append(
                Issue(.possibleDuplicate, .warning, clean(TokenKind.duplicateText(other))))
        }
        if input.settings.carriesKey {
            warnings.append(Issue(.keyInSettings, .warning, Messages.keyInSettings))
        }
        if let read = input.reading?.readAt {
            let limitSeconds = Double(config.refresh.backgroundMinutes) * 120
            let age = now.timeIntervalSince(read)
            if age > limitSeconds {
                warnings.append(Issue(.stale, .warning, "Last read \(ageText(age)) ago."))
            }
        }

        var state = "ok"
        var error: Issue?
        if let end = Picker.endsAtEnd(account.endsAt), now >= end {
            state = "ended"
            error = Issue(.accountEnded, .error, "Account ended.")
        } else if let rejected = errors.first(where: { $0.code == .loginRejected }) {
            state = "error"
            error = rejected
        } else if entry.endedByPlan && ending {
            state = "ended"
            error = Issue(.accountEnded, .error, "Account ended.")
        } else if let first = errors.first {
            state = "error"
            error = first
        } else if limit != nil {
            state = "limited"
        }
        return Evaluation(
            state: state, error: error, warnings: warnings, limitedWindow: limit?.0,
            limitedUntil: limit?.1.resetsAt, loginExpiresAt: expires, loginExpiresSource: source)
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 120 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours) h" : "\(hours / 24) days"
    }

    /// The one event for an account whose state changed this rebuild, or nil.
    static func event(
        previous: CurrentEntry?, account: Account, evaluation e: Evaluation, now: Date
    ) -> EventDraft? {
        let before = previous?.state ?? "ok"
        let beforeCode = (before == "error" || before == "ended") ? previous?.code : nil
        let afterCode = e.error?.code.rawValue
        func draft(
            _ type: String, code: String? = nil, window: String? = nil, resetsAt: Date? = nil,
            text: String
        ) -> EventDraft {
            EventDraft(
                label: account.label, accountKey: account.accountKey, type: type, code: code,
                window: window, resetsAt: resetsAt, notBefore: previous?.lastReadingAt, text: text)
        }
        if let error = e.error {
            guard afterCode != beforeCode else { return nil }
            return draft(EventType.error, code: afterCode, text: error.text)
        }
        if let beforeCode {
            return draft(EventType.recovered, text: "Recovered from \(beforeCode).")
        }
        if e.state == "limited" && before != "limited" {
            return draft(
                EventType.limited, window: e.limitedWindow, resetsAt: e.limitedUntil,
                text: "Limited until \(Picker.shortTime(e.limitedUntil)).")
        }
        if e.state != "limited" && before == "limited" {
            return draft(
                EventType.limitCleared, window: previous?.limitedWindow,
                resetsAt: previous?.limitedUntil, text: "Limit cleared.")
        }
        return nil
    }
}

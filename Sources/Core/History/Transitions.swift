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
/// change from a repeat. It holds labels, codes, times, scrubbed texts and a digest
/// (`emailDigest`), never an email.
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
    /// What the last sign-in check that read a status saw (`SignInSeen`), or nil before one.
    public var signInCheck: String?
    /// `Account.emailDigest` of the account that check was made for. While the account's own
    /// digest differs, as after a change of its email, the check stands for nothing.
    public var emailDigest: String?
}

/// What a sign-in check (`auth status`) saw of an account's sign-in.
public enum SignInSeen: String, CaseIterable, Sendable {
    /// The expected account, signed in in the account's own folder (any account when none is
    /// expected).
    case signedIn = "signed_in"
    /// No account signed in.
    case signedOut = "signed_out"
    /// Another account, signed in in the account's own folder (`wrong_account`).
    case otherAccount = "other_account"
    /// An account signed in, but the check could not confirm it is in the account's own folder,
    /// or could not confirm it as the expected account because the sign-in reported no email.
    case notConfirmed = "not_confirmed"
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
                entry.signInCheck.map({ SignInSeen(rawValue: $0) != nil }) ?? true,
                entry.emailDigest.map(Self.isDigest) ?? true,
                [entry.authError, entry.probeError].allSatisfy({
                    $0.map { StateCode(rawValue: $0.code) != nil } ?? true
                })
            else { return false }
        }
        return true
    }

    /// 64 lowercase hex digits, the only digest shape the tool writes.
    static func isDigest(_ text: String) -> Bool {
        text.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }
}

/// A sign-in check of one account (`auth status`), reduced to what the status needs.
public struct AuthObservation: Sendable {
    public var error: Issue?
    public var planTier: String?
    public var loginExpiresAt: Date?
    public var signedIn: Bool
    /// `Account.emailDigest` of the account the check was made for. Nil counts as made for the
    /// account the rebuild folds it into.
    public var emailDigest: String?
    /// True for the check `login` makes once it completed a new sign-in of the folder.
    public var newSignIn: Bool

    public init(
        error: Issue?, planTier: String?, loginExpiresAt: Date?, signedIn: Bool,
        emailDigest: String? = nil, newSignIn: Bool = false
    ) {
        self.error = error
        self.planTier = planTier
        self.loginExpiresAt = loginExpiresAt
        self.signedIn = signedIn
        self.emailDigest = emailDigest
        self.newSignIn = newSignIn
    }

    public init(_ check: AccountCheck) {
        self.init(
            error: check.issues.first { $0.severity == .error }, planTier: check.planTier,
            loginExpiresAt: check.loginExpiresAt, signedIn: check.signedIn,
            emailDigest: check.emailDigest)
    }

    /// What the check saw of the sign-in, or nil when it read no status (it could not run, or
    /// its answer could not be read), which says nothing about the sign-in.
    public var seen: SignInSeen? {
        switch (signedIn, error?.code) {
        case (false, .loginRejected?): return .signedOut
        case (false, _): return nil
        case (true, .checkFailed?): return .notConfirmed
        case (true, .wrongAccount?): return .otherAccount
        case (true, _): return .signedIn
        }
    }
}

/// The result of a probe of one account. A nil error means the probe worked.
public struct ProbeObservation: Sendable {
    public var error: Issue?
    /// For a probe that worked, how new the reading it stored is. It is kept in memory only.
    public var readAt: ReadTime?

    /// How new the reading of a probe that worked is.
    public enum ReadTime: Equatable, Sendable {
        /// The probe stored a reading of this time.
        case at(Date)
        /// A Fable probe stored a reading after the fresh one of this time it ran over; the
        /// refresh result does not carry the time of its own.
        case after(Date)
    }

    public init(error: Issue?, readAt: ReadTime? = nil) {
        self.error = error
        self.readAt = readAt
    }

    /// True when the probe worked and its reading is newer than a stored reading of `seen`, or
    /// than none when `seen` is nil. A probe whose reading time is not known never is.
    func worked(after seen: Date?) -> Bool {
        guard error == nil, let readAt else { return false }
        guard let seen else { return true }
        switch readAt {
        case .at(let time): return time > seen
        // The Fable reading may share this time's second, so only a newer time shows it newer.
        case .after(let time): return time > seen
        }
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
            // Only a probe that ran says anything; a stored or fresh reading, or a probe that never
            // began, leaves it unobserved.
            switch result.status {
            case .failed(let issue): probe[result.label] = ProbeObservation(error: issue)
            case .probed(let reading):
                probe[result.label] = ProbeObservation(error: nil, readAt: .at(reading.readAt))
            case .fresh, .usedStored, .notStarted: break
            }
            // A Fable probe runs last, so its rejection, or its working where no plain probe ran,
            // is the account's last probe; any other Fable failure says nothing on the sign-in.
            if case .failed(let issue) = result.fable, issue.code == .loginRejected {
                probe[result.label] = ProbeObservation(error: issue)
            } else if case .fresh(let reading) = result.status, result.fable == .probed {
                probe[result.label] = ProbeObservation(error: nil, readAt: .after(reading.readAt))
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
        /// What the link manifest says about a folder account. Nil for every other kind.
        var folder: FolderFacts? = nil
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

    /// How a row's errors rank: the row shows the first one it has. An end date that has passed
    /// shows `account_ended` over all of them.
    static let errorOrder: [StateCode] = [
        .loginRejected, .settingsChanged, .notLinked, .tokenMissing, .wrongAccount,
        .duplicateLogin, .planChanged, .checkFailed,
    ]

    static func clean(_ text: String) -> String {
        Display.safe(Scrubber.scrubText(text), limit: 200)
    }

    /// Codes from a sign-in check or a probe that say the expected sign-in is gone, not
    /// confirmed, or another account's.
    static let signInDoubted: Set<String> = [
        StateCode.loginRejected.rawValue, StateCode.checkFailed.rawValue,
        StateCode.wrongAccount.rawValue,
    ]

    /// The plan tier the status row carries: the one the last sign-in check that placed the
    /// expected sign-in recorded, and none while a current check result says it is gone,
    /// unconfirmed or another account's. An ended row hides those codes, so the row's tier alone
    /// must already say it.
    static func shownTier(_ entry: CurrentEntry) -> String? {
        let doubted = [entry.authError, entry.probeError].contains {
            $0.map { signInDoubted.contains($0.code) } ?? false
        }
        return doubted ? nil : entry.planTier
    }

    /// The entry with this run's observations folded in. The state fields are not touched.
    /// `storedReadAt` is the time of the account's stored reading as this rebuild read it.
    static func observed(
        _ previous: CurrentEntry?, account: Account, auth: AuthObservation?,
        probe: ProbeObservation?, duplicate: DuplicateCheck = .notRun, storedReadAt: Date? = nil,
        now: Date
    ) -> CurrentEntry {
        var entry =
            previous
            ?? CurrentEntry(
                accountKey: account.accountKey, state: "ok", code: nil, since: now,
                endedByPlan: false)
        entry.accountKey = account.accountKey
        let digest = account.emailDigest
        if let auth {
            entry.authError = auth.error.map {
                IssueRecord(Issue($0.code, $0.severity, clean($0.text)))
            }
            // The tier is the evidence of the expected sign-in, so only a check that placed that
            // sign-in here, for the email the account has now, keeps it or feeds the plan and
            // expiry; another account's tier never stands for this one.
            let placed = auth.seen == .signedIn && (auth.emailDigest ?? digest) == digest
            entry.planTier = placed ? auth.planTier : nil
            if let seen = auth.seen {
                entry.signInCheck = seen.rawValue
                entry.emailDigest = auth.emailDigest ?? digest
            }
            if placed {
                entry.loginExpiresAt = auth.loginExpiresAt
                // A check that saw only the old sign-in leaves a probe's rejection standing.
                if auth.newSignIn, entry.probeError?.code == StateCode.loginRejected.rawValue {
                    entry.probeError = nil
                }
                if account.endingSoon == true, let expected = account.expectedPlanTier,
                    auth.planTier != expected
                {
                    entry.endedByPlan = true
                }
            }
        }
        // Only a probe that works stores a reading, so a stored one newer than the latest the
        // status had seen ends a probe's rejection, whichever rebuild reads it first.
        if let storedReadAt, entry.probeError?.code == StateCode.loginRejected.rawValue,
            storedReadAt > (entry.lastReadingAt ?? .distantPast)
        {
            entry.probeError = nil
        }
        if let probe {
            // A probe that fails for another reason says nothing new about the sign-in, and one
            // whose reading the status had already seen may be older than the rejection, so only
            // a probe that works with a newer reading ends a probe's rejection.
            let stands =
                entry.probeError?.code == StateCode.loginRejected.rawValue
                && !probe.worked(after: entry.lastReadingAt)
            if !stands {
                entry.probeError = probe.error.map {
                    IssueRecord(Issue($0.code, $0.severity, clean($0.text)))
                }
            }
            if probe.error == nil && entry.authError?.code == StateCode.loginRejected.rawValue {
                entry.authError = nil
            }
        }
        // A check counts only for the email it was made for, so a changed email, by any means,
        // leaves no tier, expiry or `signed_in` until a check of the new one.
        if entry.emailDigest != digest {
            entry.planTier = nil
            entry.loginExpiresAt = nil
            if entry.signInCheck == SignInSeen.signedIn.rawValue { entry.signInCheck = nil }
            entry.emailDigest = nil
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
        let missingRecord = input.settings.issue == "missing"
        if account.kind == Kind.folder, let facts = input.folder {
            switch facts.verdict {
            case .notLinked: add(.notLinked, Messages.notLinked(account.label))
            case .broken: add(.settingsChanged, Messages.linkBroken(account.label))
            case .ok:
                // A folder that shares the settings link is hit by a hook change like every other
                // account; one that shares none has no hooks to lose.
                if input.settings.issue != nil, facts.sharesSettings {
                    add(
                        .settingsChanged,
                        missingRecord ? Messages.hookRecordMissingAll : Messages.settingsChangedAll)
                }
            }
        } else if input.settings.issue != nil {
            add(
                .settingsChanged,
                missingRecord ? Messages.hookRecordMissing : Messages.settingsChanged)
        }
        if account.kind == Kind.token && !input.tokenUsable {
            add(.tokenMissing, Messages.tokenMissing(account.label))
        }
        if let other = input.duplicateOf {
            add(
                .duplicateLogin,
                "Logged in as the same account as \(other). Log one folder into its own account.")
        }
        let order = errorOrder
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

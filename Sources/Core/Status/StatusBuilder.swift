import Foundation

/// What `StatusBuilder.build` works out: the document, the new `state/current.json`, and what the
/// history step must append.
struct StatusBuild {
    var document: StatusDocument
    var current: CurrentFile
    var events: [EventDraft]
    var history: [(label: String, line: HistoryLine, priorAt: Date?, priorSignature: String?)]
}

/// What the builder needs to know about one token account's file, from `lstat` and a shape check.
struct TokenInfo: Sendable {
    var usable: Bool
    var modified: Date?
}

/// Merges readings, sign-in checks and in-use sessions into the status document, and rebuilds
/// `state/status.json` (docs/ARCHITECTURE.md sections 4, 10.1 and 13).
public enum StatusBuilder {
    // MARK: Pure build

    static func build(
        config: Config, readings: [String: Reading], previous: CurrentFile,
        observations: StatusObservations, sessions: SessionsSnapshot, tokens: [String: TokenInfo],
        launchExists: (LaunchRef) -> Bool, now: Date
    ) -> StatusBuild {
        var current = CurrentFile()
        current.prunedAt = previous.prunedAt
        current.settings =
            observations.settings.map { SettingsMemory(issue: $0.issue, carriesKey: $0.carriesKey) }
            ?? previous.settings
        let settings = current.settings ?? SettingsMemory()

        var events: [EventDraft] = []
        var history: [(label: String, line: HistoryLine, priorAt: Date?, priorSignature: String?)] =
            []
        var rows: [AccountStatus] = []
        var inputs: [PickInput] = []

        // An entry follows its account key, so a renamed label keeps its history.
        let keys = Set(config.accounts.map(\.accountKey))
        var byKey: [String: (label: String, entry: CurrentEntry)] = [:]
        for (label, entry) in previous.accounts { byKey[entry.accountKey] = (label, entry) }
        for (key, old) in byKey.sorted(by: { $0.value.label < $1.value.label })
        where !keys.contains(key) {
            // This key was read back from current.json, not from the config.
            events.append(
                EventDraft(
                    label: old.label, accountKey: Scrubber.scrubText(key),
                    type: EventType.accountRemoved, code: nil,
                    window: nil, resetsAt: nil, notBefore: old.entry.lastReadingAt,
                    text: "Account removed."))
        }

        var emails: [String: [String]] = [:]
        for account in config.accounts {
            if let email = account.email?.lowercased(), !email.isEmpty {
                emails[email, default: []].append(account.label)
            }
        }

        var live: [String: [LiveSession]] = [:]
        let loginLabel = config.loginAccount?.label
        for session in sessions.live {
            var labels = Set(session.refs.map(\.label))
            if labels.isEmpty, let loginLabel { labels = [loginLabel] }
            for label in labels { live[label, default: []].append(session) }
        }
        var missing: [String: Int] = [:]
        for session in sessions.live {
            for label in Set(session.refs.filter { !launchExists($0) }.map(\.label)) {
                missing[label, default: 0] += 1
            }
        }

        let retention = config.history.retentionDays
        for account in config.accounts {
            let known = byKey[account.accountKey]?.entry
            let reading = readings[account.label]
            let entry = Transitions.observed(
                known, account: account, auth: observations.auth[account.label],
                probe: observations.probe[account.label], now: now)
            let token = tokens[account.label]
            let duplicate = emails[account.email?.lowercased() ?? ""].flatMap { group in
                group.count > 1 ? group.first { $0 != account.label } : nil
            }
            var evaluation = Transitions.evaluate(
                Transitions.Input(
                    account: account, reading: reading, entry: entry, settings: settings,
                    duplicateOf: duplicate, tokenUsable: token?.usable ?? false,
                    tokenModified: token?.modified, config: config, now: now))
            if let count = missing[account.label], count > 0 {
                let text =
                    count == 1
                    ? "1 live session names a launch file that is gone."
                    : "\(count) live sessions name a launch file that is gone."
                evaluation.warnings.append(Issue(.launchFileMissing, .warning, text))
            }

            if known == nil {
                events.append(
                    EventDraft(
                        label: account.label, accountKey: account.accountKey,
                        type: EventType.accountAdded, code: nil, window: nil, resetsAt: nil,
                        notBefore: nil, text: "Account added."))
            }
            var drafted = Transitions.event(
                previous: known, account: account, evaluation: evaluation, now: now)

            var next = entry
            let code = evaluation.error?.code.rawValue
            let sawFirstReading = known?.lastReadingAt == nil && reading != nil
            if known == nil || known?.state != evaluation.state || known?.code != code
                || (sawFirstReading && evaluation.state == "ok")
            {
                next.since = now
            }
            next.state = evaluation.state
            next.code = code
            if evaluation.state == "limited" {
                next.limitedWindow = evaluation.limitedWindow
                next.limitedUntil = evaluation.limitedUntil
                next.limitedSince = known?.state == "limited" ? (known?.limitedSince ?? now) : now
            } else {
                next.limitedWindow = nil
                next.limitedUntil = nil
                next.limitedSince = nil
            }
            next.lastReadingAt = reading?.readAt ?? known?.lastReadingAt
            if drafted == nil, let expires = evaluation.loginExpiresAt,
                evaluation.warnings.contains(where: { $0.code == .loginExpiring })
            {
                let day = Self.day(expires)
                if day != entry.expiringNotified {
                    drafted = EventDraft(
                        label: account.label, accountKey: account.accountKey,
                        type: EventType.loginExpiring, code: nil, window: nil, resetsAt: nil,
                        notBefore: known?.lastReadingAt,
                        text: "Login expires \(LoginKind.shortDate(expires)).")
                    next.expiringNotified = day
                }
            }
            if let drafted { events.append(drafted) }

            if let reading, retention > 0 {
                let line = Self.historyLine(account: account, reading: reading, state: next.state)
                let changedState = known?.state != next.state
                let quiet =
                    next.historyAt.map { now.timeIntervalSince($0) < ReadingHistory.minimumGap }
                    ?? false
                if line.signature != next.historySignature && (changedState || !quiet) {
                    history.append((account.label, line, next.historyAt, next.historySignature))
                    next.historyAt = now
                    next.historySignature = line.signature
                }
            }
            current.accounts[account.label] = next

            let sessionsHere = (live[account.label] ?? []).sorted { $0.id < $1.id }
            let inUse =
                sessions.clean
                ? InUseStatus(
                    count: sessionsHere.count,
                    sessions: sessionsHere.map {
                        SessionStatus(
                            id: Display.safe(String($0.id.prefix(8)), limit: 8), name: $0.name)
                    }, unknown: false) : .unknownValue
            let row = Self.row(
                account: account, config: config, reading: reading, entry: next,
                evaluation: evaluation, inUse: inUse, now: now,
                showSince: !(next.state == "ok" && next.lastReadingAt == nil))
            rows.append(row)

            var skip: String?
            if let error = evaluation.error { skip = error.text }
            var forPicker = reading
            forPicker?.readAt = now
            inputs.append(PickInput(account: account, reading: forPicker, skip: skip))
        }

        let all = Picker.decide(
            inputs: inputs, config: config, model: .other, openLeases: [:], now: now)
        let fable = Picker.decide(
            inputs: inputs, config: config, model: .fable, openLeases: [:], now: now)
        func choice(_ d: PickDecision) -> NextChoice {
            NextChoice(
                label: d.chosen.map { config.accounts[$0].label }, reason: d.reason)
        }
        var banner: StatusIssue?
        if let issue = settings.issue {
            banner = StatusIssue(
                code: StateCode.settingsChanged.rawValue,
                text: issue == "missing" ? Messages.hookRecordMissing : Messages.settingsChanged)
        }
        let document = StatusDocument(
            generatedAt: now, banner: banner, accounts: rows,
            next: NextStatus(all: choice(all), fable: choice(fable)))
        return StatusBuild(document: document, current: current, events: events, history: history)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func historyLine(account: Account, reading: Reading, state: String) -> HistoryLine {
        func window(_ w: WindowReading?) -> HistoryWindow? {
            w.map {
                HistoryWindow(usedPercent: Reading.round1($0.usedPercent), resetsAt: $0.resetsAt)
            }
        }
        var fable: HistoryWindow?
        if let f = reading.fable, f.source == ReadingSource.probe {
            fable = HistoryWindow(usedPercent: f.usedPercent, resetsAt: f.resetsAt)
        }
        return HistoryLine(
            accountKey: account.accountKey, at: reading.readAt, source: reading.source,
            state: state, weekly: window(reading.sevenDay), fiveHour: window(reading.fiveHour),
            fable: fable)
    }

    static func row(
        account: Account, config: Config, reading: Reading?, entry: CurrentEntry,
        evaluation e: Transitions.Evaluation, inUse: InUseStatus, now: Date, showSince: Bool
    ) -> AccountStatus {
        func window(_ w: WindowReading?, source: String) -> WindowStatus? {
            w.map {
                WindowStatus(
                    usedPercent: Reading.round1($0.usedPercent), resetsAt: $0.resetsAt,
                    source: source, readAt: $0.readAt)
            }
        }
        let source = reading?.source ?? "none"
        let weekly = window(reading?.sevenDay, source: source) ?? .none
        var fable = FableStatus(
            usedPercent: nil, guaranteedLeftPercentOfCap: nil, possibleLeftPercentOfCap: nil,
            resetsAt: nil, source: "none")
        if let f = reading?.fable, f.source == ReadingSource.probe, let used = f.usedPercent {
            fable = FableStatus(
                usedPercent: Reading.round1(used), guaranteedLeftPercentOfCap: nil,
                possibleLeftPercentOfCap: nil, resetsAt: f.resetsAt, source: "probe")
        } else if let w = reading?.sevenDay {
            let estimate = FableReading.estimate(
                weeklyUsedPercent: w.usedPercent,
                capPercentOfWeekly: config.fable.capPercentOfWeekly)
            fable = FableStatus(
                usedPercent: nil,
                guaranteedLeftPercentOfCap: estimate.guaranteedRoomPercentOfCap,
                possibleLeftPercentOfCap: 100, resetsAt: nil, source: "estimate")
        }

        var limited: LimitedStatus?
        if e.state == "limited", let name = entry.limitedWindow {
            limited = LimitedStatus(
                window: name, since: entry.limitedSince ?? now, until: entry.limitedUntil)
        }
        var reserve: ReserveStatus?
        if account.role == Role.main {
            let spec = account.reserve ?? Reserve.standard
            let days = reading?.sevenDay?.resetsAt.map { $0.timeIntervalSince(now) / 86_400 }
            let line = Picker.reserveLine(spec, daysLeft: days)
            let used = reading?.sevenDay?.usedPercent
            reserve = ReserveStatus(
                linePercent: Reading.round1(line), marginPercent: spec.marginPercent,
                launchAllowed: used.map { $0 + Double(spec.marginPercent) <= line } ?? false,
                daysLeft: days.map { (($0 * 10).rounded()) / 10 })
        }
        return AccountStatus(
            label: account.label, email: account.email, role: account.role, kind: account.kind,
            fullLogin: account.kind != Kind.token, configDir: nil, accountKey: account.accountKey,
            endingSoon: account.endingSoon == true, linked: nil, state: e.state,
            stateSince: showSince ? entry.since : nil, limited: limited,
            error: e.error.map { StatusIssue(code: $0.code.rawValue, text: $0.text) },
            warnings: e.warnings.map { StatusIssue(code: $0.code.rawValue, text: $0.text) },
            planTier: account.kind == Kind.login ? entry.planTier : nil, weekly: weekly,
            fable: fable, fiveHour: window(reading?.fiveHour, source: source),
            readingsAge: reading.map { max(0, Int(now.timeIntervalSince($0.readAt))) },
            inUse: inUse, endsAt: account.endsAt, loginExpiresAt: e.loginExpiresAt,
            loginExpiresSource: e.loginExpiresSource, reserve: reserve)
    }

    // MARK: Rebuild

    static let currentName = "current.json"
    static let statusName = "status.json"
    static let lockName = "history.lock"
    static let lockWaitSeconds: TimeInterval = 30

    /// Rebuilds `state/status.json`. Under `locks/history.lock`, taken before any reading, lease or
    /// config file is read and held until `status.json` is renamed into place, it appends to the
    /// readings history and the events record, then writes `current.json` and `status.json`.
    /// Returns nil when the lock stayed held. A failure of the history step is logged and never
    /// stops the document from being written.
    @discardableResult
    public static func rebuild(
        context: ToolContext, observations: StatusObservations = StatusObservations(),
        now: Date = Date(), lockWait: TimeInterval? = nil
    ) throws -> StatusDocument? {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard
            let lock = try writer.acquireLock(
                folders: Layout.locksFolders, name: lockName, wait: lockWait ?? lockWaitSeconds)
        else {
            Self.log(context, "status rebuild skipped: the history lock stayed held")
            return nil
        }
        defer { lock.release() }

        let config = try ConfigStore(context: context).loadRequired()
        let store = ReadingStore(context: context)
        var readings: [String: Reading] = [:]
        for account in config.accounts {
            if let reading = try? store.load(label: account.label) {
                readings[account.label] = reading
            }
        }
        var tokens: [String: TokenInfo] = [:]
        for account in config.accounts where account.kind == Kind.token {
            let facts = try? TokenPaths.facts(context: context, label: account.label)
            tokens[account.label] = TokenInfo(
                usable: (facts?.isPrivate ?? false)
                    && TokenStore.isUsable(context: context, label: account.label),
                modified: facts?.modified)
        }
        let reader = NoFollowReader(root: context.dataRoot)
        var previous = CurrentFile()
        if let data = try? reader.read(folders: Layout.stateFolders, name: currentName) {
            if let file = try? EventLog.decoder().decode(CurrentFile.self, from: data),
                file.schemaVersion == CurrentFile.currentSchema, file.isSound
            {
                previous = file
            } else {
                Self.log(context, "state/current.json did not parse and was started over")
            }
        }
        let sessions = SessionsReader.read(context: context)
        let built = build(
            config: config, readings: readings, previous: previous, observations: observations,
            sessions: sessions, tokens: tokens,
            launchExists: { LaunchFiles.exists(context: context, ref: $0) }, now: now)

        var current = built.current
        let events = EventLog(context: context)
        // The transitions live in current.json; keeping the old file when the events could not be
        // saved lets the next rebuild detect them again instead of losing them.
        var eventsSaved = true
        do {
            for note in try events.append(built.events, now: now) { Self.log(context, note) }
        } catch {
            eventsSaved = false
            Self.log(context, "events step failed: \((error as? ToolError)?.message ?? "unknown")")
        }
        let history = ReadingHistory(context: context)
        // A label whose line could not be saved keeps its old signature, so the next rebuild
        // appends the line again.
        for item in built.history {
            do {
                if try history.append(item.line, label: item.label) {
                    Self.log(context, "cut a last history line that did not parse")
                }
            } catch {
                current.accounts[item.label]?.historyAt = item.priorAt
                current.accounts[item.label]?.historySignature = item.priorSignature
                Self.log(
                    context,
                    "history append failed for \(item.label): \((error as? ToolError)?.message ?? "unknown")"
                )
            }
        }
        do {
            let due = current.prunedAt.map { now.timeIntervalSince($0) >= 86_400 } ?? true
            if due && eventsSaved {
                try events.prune(retentionDays: config.history.retentionDays, now: now)
                try history.prune(retentionDays: config.history.retentionDays, now: now)
                current.prunedAt = now
            }
        } catch {
            Self.log(context, "history step failed: \((error as? ToolError)?.message ?? "unknown")")
        }
        if eventsSaved {
            try writer.put(
                try EventLog.encoder().encode(current) + Data([0x0A]),
                folders: Layout.stateFolders, name: currentName)
        }
        try writer.put(
            try StatusDocument.encoder().encode(built.document) + Data([0x0A]),
            folders: Layout.stateFolders, name: statusName)
        return built.document
    }

    /// Rebuilds after a command's own work is done. A failure is logged and never changes the
    /// command's output or exit code.
    public static func rebuildQuietly(
        context: ToolContext, observations: StatusObservations = StatusObservations()
    ) {
        do {
            try rebuild(context: context, observations: observations)
        } catch {
            Self.log(
                context, "status rebuild failed: \((error as? ToolError)?.message ?? "unknown")")
        }
    }

    /// One scrubbed line in `logs/agent-balancer.log`.
    static func log(_ context: ToolContext, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = stamp + " " + Display.safe(Scrubber.scrubText(message), limit: 300) + "\n"
        try? NoFollowWriter(root: context.dataRoot).append(
            Data(line.utf8), folders: ["logs"], name: "agent-balancer.log")
    }
}

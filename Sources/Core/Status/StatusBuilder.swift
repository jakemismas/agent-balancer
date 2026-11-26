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
    /// The text for a token that is not usable for more than a missing file
    /// (`TokenStore.blockedText`), shown in place of the `token_missing` text.
    var blocked: String? = nil
}

/// What the status shows for one folder account: the manifest verdict and the folder as `~` text.
struct FolderInfo: Sendable {
    var facts: FolderFacts
    var display: String
}

/// Merges readings, sign-in checks and in-use sessions into the status document, and rebuilds
/// `state/status.json` (docs/ARCHITECTURE.md sections 4, 10.1 and 13).
public enum StatusBuilder {
    // MARK: Pure build

    static func build(
        config: Config, readings: [String: Reading], previous: CurrentFile,
        observations: StatusObservations, sessions: SessionsSnapshot, tokens: [String: TokenInfo],
        launchExists: (LaunchRef) -> Bool, launchUnchecked: (LaunchRef) -> Bool = { _ in false },
        now: Date, folders: [String: FolderInfo] = [:], marks: [String: RejectionRecord] = [:]
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
            // A session in an account's own folder counts toward that account.
            if let owner = session.folderLabel {
                labels = [owner]
            } else if labels.isEmpty, let loginLabel {
                labels = [loginLabel]
            }
            for label in labels { live[label, default: []].append(session) }
        }
        var missing: [String: Int] = [:]
        // A launch file `lstat` cannot check may hold a token, so it is never counted as gone.
        var unchecked: [String: Int] = [:]
        for session in sessions.live {
            var gone = Set<String>()
            var hidden = Set<String>()
            for ref in session.refs where !launchExists(ref) {
                if launchUnchecked(ref) { hidden.insert(ref.label) } else { gone.insert(ref.label) }
            }
            for label in gone { missing[label, default: 0] += 1 }
            for label in hidden { unchecked[label, default: 0] += 1 }
        }

        let retention = config.history.retentionDays
        for account in config.accounts {
            var known = byKey[account.accountKey]?.entry
            let reading = readings[account.label]
            // A new token's first check that worked, kept apart because its own rebuild saved no
            // state, ends the rejection recorded before it, as that rebuild would have.
            if let mark = marks[account.label], mark.accountKey == account.accountKey,
                known?.probeError?.code == StateCode.loginRejected.rawValue
            {
                known?.probeError = nil
                known?.lastReadingAt = reading?.readAt ?? mark.at
            }
            let probe = observations.probe(for: account)
            let entry = Transitions.observed(
                known, account: account, auth: observations.auth[account.label],
                probe: probe, duplicate: observations.duplicate(for: account),
                storedReadAt: reading?.readAt,
                newToken: observations.newToken.contains(account.label), now: now)
            let token = tokens[account.label]
            let duplicate = emails[account.email?.lowercased() ?? ""].flatMap { group in
                group.count > 1 ? group.first { $0 != account.label } : nil
            }
            var evaluation = Transitions.evaluate(
                Transitions.Input(
                    account: account, reading: reading, entry: entry, settings: settings,
                    duplicateOf: duplicate,
                    possibleDuplicateOf: entry.possibleDuplicateOf.flatMap { other in
                        config.account(other) == nil ? nil : other
                    },
                    tokenUsable: token?.usable ?? false, tokenBlocked: token?.blocked,
                    tokenModified: token?.modified, config: config, now: now,
                    folder: folders[account.label]?.facts))
            if let count = missing[account.label], count > 0 {
                let text =
                    count == 1
                    ? "1 live session names a launch file that is gone."
                    : "\(count) live sessions name a launch file that is gone."
                evaluation.warnings.append(Issue(.launchFileMissing, .warning, text))
            }
            if let count = unchecked[account.label], count > 0 {
                let sessions = count == 1 ? "1 live session names" : "\(count) live sessions name"
                let text =
                    sessions
                    + " a launch file that cannot be checked. Run `agent-balancer doctor` in Terminal."
                evaluation.warnings.append(Issue(.launchFileUnchecked, .warning, text))
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
            // The old sign-in's limit went with its reading; it did not clear.
            if drafted?.type == EventType.limitCleared,
                observations.readingDropped.contains(account.label)
            {
                drafted = nil
            }

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
            let seen = known?.lastReadingAt
            next.lastReadingAt = reading?.readAt ?? seen
            if probe?.error?.code == .loginRejected {
                // Dated now with no usable reading, never before a reading the status had seen.
                let second = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
                next.lastReadingAt = max(reading?.readAt ?? second, seen ?? .distantPast)
            } else if next.probeError?.code == StateCode.loginRejected.rawValue, let seen {
                // An older reading, put back or read after a clock change, never dates it earlier.
                next.lastReadingAt = max(next.lastReadingAt ?? seen, seen)
            }
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
            if observations.tokenReplaced.contains(account.label) {
                events.append(
                    EventDraft(
                        label: account.label, accountKey: account.accountKey,
                        type: EventType.tokenReplaced, code: nil, window: nil, resetsAt: nil,
                        notBefore: known?.lastReadingAt, text: "Token replaced."))
            }

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
                evaluation: evaluation, inUse: inUse, now: now, folder: folders[account.label],
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
            // `--all` is named only when a linked folder account is hit too.
            let folderHit = config.accounts.contains {
                $0.kind == Kind.folder && folders[$0.label]?.facts.verdict == .ok
                    && folders[$0.label]?.facts.sharesSettings == true
            }
            let missing = issue == "missing"
            banner = StatusIssue(
                code: StateCode.settingsChanged.rawValue,
                text: folderHit
                    ? (missing ? Messages.hookRecordMissingAll : Messages.settingsChangedAll)
                    : (missing ? Messages.hookRecordMissing : Messages.settingsChanged))
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
        evaluation e: Transitions.Evaluation, inUse: InUseStatus, now: Date,
        folder: FolderInfo? = nil, showSince: Bool
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
            fullLogin: account.kind != Kind.token, configDir: folder?.display,
            accountKey: account.accountKey, endingSoon: account.endingSoon == true,
            linked: folder.map { $0.facts.verdict == .ok }, state: e.state,
            stateSince: showSince ? entry.since : nil, limited: limited,
            error: e.error.map { StatusIssue(code: $0.code.rawValue, text: $0.text) },
            warnings: e.warnings.map { StatusIssue(code: $0.code.rawValue, text: $0.text) },
            planTier: account.kind == Kind.token ? nil : Transitions.shownTier(entry),
            weekly: weekly,
            fable: fable, fiveHour: window(reading?.fiveHour, source: source),
            readingsAge: reading.map { max(0, Int(now.timeIntervalSince($0.readAt))) },
            inUse: inUse, endsAt: account.endsAt, loginExpiresAt: e.loginExpiresAt,
            loginExpiresSource: e.loginExpiresSource, reserve: reserve,
            signInCheck: account.kind == Kind.folder ? entry.signInCheck : nil,
            noLimit: account.noLimit)
    }

    // MARK: Rebuild

    static let currentName = "current.json"
    static let statusName = "status.json"
    static let lockName = "history.lock"
    static let lockWaitSeconds: TimeInterval = 30

    /// Rebuilds `state/status.json`. Under `locks/history.lock`, taken before any reading, lease or
    /// config file is read and held until `status.json` is renamed into place, it appends to the
    /// readings history and the events record, then writes `current.json` and `status.json`.
    /// Returns nil, saving nothing, when that lock stayed held, or when `locks/token-records.lock`,
    /// taken right after it to read the token records, stayed held or
    /// `state/token-checks.json` could not be read. It takes that lock again only to save the
    /// token records and `current.json`; when it stays held then, or that file cannot be read,
    /// the rebuild saves neither. A failure of the history step is logged and never stops the
    /// document from being written.
    @discardableResult
    public static func rebuild(
        context: ToolContext, observations: StatusObservations = StatusObservations(),
        now: Date = Date(), lockWait: TimeInterval? = nil
    ) throws -> StatusDocument? {
        try rebuilt(context: context, observations: observations, now: now, lockWait: lockWait)?
            .document
    }

    /// `rebuild`, with whether it saved `state/current.json`. `afterRecordsRead` runs once the
    /// token records are read and their lock is let go, before anything else is read; tests
    /// stall a rebuild there.
    static func rebuilt(
        context: ToolContext, observations: StatusObservations, now: Date, lockWait: TimeInterval?,
        afterRecordsRead: () -> Void = {}
    ) throws -> (document: StatusDocument, savedState: Bool)? {
        try NoFollowWriter.run(context.dataRoot, rebuildPlan(context: context)) {
            try rebuiltSteps(
                context: context, observations: observations, now: now, lockWait: lockWait,
                afterRecordsRead: afterRecordsRead)
        }
    }

    /// The token records as a rebuild read them at its start: the kept new-token checks, and
    /// the durable rejections, nil when that file could not be read.
    struct RecordsRead {
        var checks: [String: RejectionRecord]
        var rejections: [String: RejectionRecord]?
    }

    private static func rebuiltSteps(
        context: ToolContext, observations: StatusObservations, now: Date, lockWait: TimeInterval?,
        afterRecordsRead: () -> Void
    ) throws -> (document: StatusDocument, savedState: Bool)? {
        let writer = NoFollowWriter(root: context.dataRoot)
        let wait = lockWait ?? lockWaitSeconds
        guard
            let lock = try writer.acquireLock(
                folders: Layout.locksFolders, name: lockName, wait: wait)
        else {
            Self.log(context, "status rebuild skipped: the history lock stayed held")
            return nil
        }
        defer { lock.release() }
        // The token records also change outside this lock, as a probe's rejection or a new
        // token's check is kept, so their own lock is held only while they are read here and
        // saved at the end, and a rebuild that stalls in between does not hold up those writes.
        guard let read = try readRecords(context: context, writer: writer, wait: wait) else {
            return nil
        }
        afterRecordsRead()

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
            let usable =
                (facts?.isPrivate ?? false)
                && TokenStore.isUsable(context: context, label: account.label)
            let blocked =
                usable ? nil : TokenStore.blockedText(context: context, label: account.label)
            tokens[account.label] = TokenInfo(
                usable: usable, modified: facts?.modified, blocked: blocked)
        }
        let reader = NoFollowReader(root: context.dataRoot)
        let marks = read.checks
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
        var folders: [String: FolderInfo] = [:]
        for account in config.accounts where account.kind == Kind.folder {
            guard let dir = try? FolderPaths.configDir(context: context, label: account.label)
            else { continue }
            folders[account.label] = FolderInfo(
                facts: Verifier.linkFacts(context: context, label: account.label),
                display: context.display(dir))
        }
        // One read of each launch file, so a file that changes between two reads is never gone.
        var presences: [LaunchRef: LaunchFiles.Presence] = [:]
        func presence(_ ref: LaunchRef) -> LaunchFiles.Presence {
            if let seen = presences[ref] { return seen }
            let found = LaunchFiles.presence(context: context, ref: ref)
            presences[ref] = found
            return found
        }
        let built = build(
            config: config, readings: readings, previous: previous, observations: observations,
            sessions: sessions, tokens: tokens,
            launchExists: { presence($0) == .there },
            launchUnchecked: { presence($0) == .unchecked },
            now: now, folders: folders, marks: marks)

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
                let written = try history.append(item.line, label: item.label)
                if written.dropped > 0 {
                    Self.log(context, Self.droppedText(written.dropped, label: item.label))
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
            // A prune time ahead of the clock means the clock moved back, which pruning survives.
            let due =
                current.prunedAt.map {
                    now.timeIntervalSince($0) >= 86_400 || $0 > now.addingTimeInterval(60)
                } ?? true
            // Only a five-hour or weekly reset time at most 270 seconds before a reading's own time
            // bounds how far ahead that reading can be dated, so never from the clock alone or
            // another reading (docs/ARCHITECTURE.md section 13).
            let bounded = readings.values.filter { reading in
                // Earlier versions checked only the stored minute, up to 30 s after the time given.
                let earliest = reading.readAt.addingTimeInterval(-(ResetBounds.slack - 30))
                let resets: [Date] = [reading.fiveHour?.resetsAt, reading.sevenDay?.resetsAt]
                    .compactMap { $0 }
                return resets.contains { $0 >= earliest }
            }
            let days = config.history.retentionDays
            // With 0 days a prune uses no cutoff, so it does not wait for such a reading.
            let newest: Date? = days == 0 ? now : bounded.map(\.readAt).max()
            if due && eventsSaved, let newest {
                let from = min(now, newest)
                try events.prune(retentionDays: days, now: from) { count in
                    Self.log(context, Self.droppedText(count, label: nil))
                }
                try history.prune(retentionDays: days, now: from) { label, count in
                    Self.log(context, Self.droppedText(count, label: label))
                }
                current.prunedAt = now
            }
        } catch {
            Self.log(context, "history step failed: \((error as? ToolError)?.message ?? "unknown")")
        }
        let savedState: Bool
        if let records = try writer.acquireLock(
            folders: Layout.locksFolders, name: recordsLockName, wait: wait)
        {
            defer { records.release() }
            savedState = try saveRecords(
                context: context, read: read, config: config, current: current,
                observations: observations, eventsSaved: eventsSaved)
        } else {
            Self.log(context, "token records step skipped: the token records lock stayed held")
            savedState = false
        }
        try writer.put(
            try StatusDocument.encoder().encode(built.document) + Data([0x0A]),
            folders: Layout.stateFolders, name: statusName)
        return (built.document, savedState)
    }

    /// Reads the kept new-token checks and the durable rejections under the records lock, then
    /// lets it go. Nil, logged, when that lock stayed held or the checks file could not be read:
    /// state saved without a kept check folded lets a later fold end a newer rejection.
    private static func readRecords(
        context: ToolContext, writer: NoFollowWriter, wait: TimeInterval
    ) throws -> RecordsRead? {
        guard
            let records = try writer.acquireLock(
                folders: Layout.locksFolders, name: recordsLockName, wait: wait)
        else {
            Self.log(context, "status rebuild skipped: the token records lock stayed held")
            return nil
        }
        defer { records.release() }
        let reader = NoFollowReader(root: context.dataRoot)
        let checks = loadRecords(reader, name: checksName)
        guard checks.sound else {
            Self.log(context, "status rebuild skipped: state/token-checks.json could not be read")
            return nil
        }
        let rejections = loadRecords(reader, name: rejectionsName)
        return RecordsRead(
            checks: checks.file.tokens, rejections: rejections.sound ? rejections.file.tokens : nil)
    }

    /// Under the records lock, saves the durable rejections, clears the kept checks this rebuild
    /// folded and saves `current.json`, and says whether it saved that file. A record another
    /// command kept after the rebuild read the records stays as it is: that command's probe or
    /// check came after every one the rebuild saw.
    private static func saveRecords(
        context: ToolContext, read: RecordsRead, config: Config, current: CurrentFile,
        observations: StatusObservations, eventsSaved: Bool
    ) throws -> Bool {
        let writer = NoFollowWriter(root: context.dataRoot)
        let reader = NoFollowReader(root: context.dataRoot)
        let checks = loadRecords(reader, name: checksName)
        guard checks.sound else {
            Self.log(
                context, "token records step skipped: state/token-checks.json could not be read")
            return false
        }
        var settled = Set(checks.file.tokens.filter { read.checks[$0.key] != $0.value }.keys)
        let rejections = loadRecords(reader, name: rejectionsName)
        if rejections.sound {
            let before = read.rejections ?? [:]
            let found = rejections.file.tokens
            settled.formUnion(Set(before.keys).union(found.keys).filter { before[$0] != found[$0] })
        }
        let folded = read.checks.filter {
            config.account($0.key)?.accountKey == $0.value.accountKey
        }
        recordRejections(
            context: context, config: config, current: current, observations: observations,
            marked: Set(folded.keys), settled: settled)
        guard eventsSaved else { return false }
        // Only the checks this rebuild folded go, and with the state that holds them.
        var left = checks.file
        for (label, mark) in read.checks where left.tokens[label] == mark {
            left.tokens[label] = nil
        }
        let clears = left.tokens.count < checks.file.tokens.count
        if clears {
            do {
                try writer.put(
                    try EventLog.encoder().encode(left) + Data([0x0A]),
                    folders: Layout.stateFolders, name: checksName)
            } catch {
                Self.log(
                    context,
                    "token checks step failed: \((error as? ToolError)?.message ?? "unknown")")
                return false
            }
        }
        do {
            try writer.put(
                try EventLog.encoder().encode(current) + Data([0x0A]),
                folders: Layout.stateFolders, name: currentName)
        } catch {
            // Nothing else writes the checks while the lock is held, so they go back as read.
            if clears {
                try? writer.put(
                    try EventLog.encoder().encode(checks.file) + Data([0x0A]),
                    folders: Layout.stateFolders, name: checksName)
            }
            throw error
        }
        return true
    }

    /// True while a probe's rejection of the sign-in of `account` stands, as `state/current.json`
    /// records it. A file that cannot be read, or that holds another account under the label,
    /// gives false.
    public static func probeFoundSignInRejected(context: ToolContext, account: Account) -> Bool {
        probeRejection(context: context, account: account) != nil
    }

    static let rejectionsName = "token-rejections.json"
    /// Each token account's new token whose first check worked while the rebuild that records
    /// that check saved no `current.json`; the first rebuild that reads it and saves that file
    /// folds and drops it.
    static let checksName = "token-checks.json"
    static let recordsLockName = "token-records.lock"

    /// What keeping a rejection or a new token's check does under the data folder, beside a
    /// token account's check (`Refresher.checkPlan`).
    static var tokenRecordTargets: [NoFollowWriter.Target] {
        [
            .file(Layout.locksFolders, recordsLockName, [.lock]),
            .file(Layout.stateFolders, currentName, [.read]),
            .file(Layout.stateFolders, rejectionsName, [.read, .replace]),
            .file(Layout.stateFolders, checksName, [.read, .replace]),
            .folder(Layout.stateFolders, [.create]),
        ]
    }

    struct RejectionRecord: Codable, Equatable {
        var accountKey: String
        var at: Date
    }

    struct RejectionsFile: Codable {
        var schemaVersion = 1
        var tokens: [String: RejectionRecord] = [:]
    }

    /// A records file and whether it read as one: a file that is missing reads as empty and
    /// sound, one that cannot be read or decoded as empty and not sound.
    static func loadRecords(_ reader: NoFollowReader, name: String) -> (
        file: RejectionsFile, sound: Bool
    ) {
        let data: Data?
        do {
            data = try reader.read(folders: Layout.stateFolders, name: name)
        } catch {
            return (RejectionsFile(), false)
        }
        guard let data else { return (RejectionsFile(), true) }
        guard let file = try? EventLog.decoder().decode(RejectionsFile.self, from: data),
            file.schemaVersion == 1
        else { return (RejectionsFile(), false) }
        return (file, true)
    }

    /// Writes a token account's probe rejection to the durable record at once, under the records
    /// lock and without the history lock, dated as the rebuild that records it would date it.
    /// Returns whether the record keeps the token out afterwards.
    @discardableResult
    public static func keepRejection(context: ToolContext, account: Account) -> Bool {
        guard account.kind == Kind.token else { return false }
        return TerminateGate.shared.recording {
            let writer = NoFollowWriter(root: context.dataRoot)
            guard
                let lock = try? writer.acquireLock(
                    folders: Layout.locksFolders, name: recordsLockName, wait: lockWaitSeconds)
            else { return false }
            defer { lock.release() }
            let reader = NoFollowReader(root: context.dataRoot)
            let loaded = loadRecords(reader, name: rejectionsName)
            // A record that cannot be read already keeps every token account out.
            guard loaded.sound else { return true }
            var file = loaded.file
            // Never before a reading the status had seen for this token: a kept new token's
            // check stands for the readings before it.
            var seen: Date?
            if let mark = loadRecords(reader, name: checksName).file.tokens[account.label],
                mark.accountKey == account.accountKey
            {
                seen = mark.at
            } else if let data = try? reader.read(folders: Layout.stateFolders, name: currentName),
                let state = try? EventLog.decoder().decode(CurrentFile.self, from: data),
                state.schemaVersion == CurrentFile.currentSchema, state.isSound,
                let entry = state.accounts[account.label], entry.accountKey == account.accountKey
            {
                seen = entry.lastReadingAt
            }
            let stored = try? ReadingStore(context: context).load(label: account.label)
            let second = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let at = max(stored?.readAt ?? second, seen ?? .distantPast)
            if let known = file.tokens[account.label], known.accountKey == account.accountKey,
                known.at >= at
            {
                return true
            }
            file.tokens[account.label] = RejectionRecord(accountKey: account.accountKey, at: at)
            guard let data = try? EventLog.encoder().encode(file),
                (try? writer.put(
                    data + Data([0x0A]), folders: Layout.stateFolders, name: rejectionsName))
                    != nil
            else { return false }
            return true
        }
    }

    /// Keeps a new token's first check that worked for the next rebuild that saves
    /// `current.json`, when the one that recorded it saved none, and ends the durable record of
    /// the rejection before it. Runs under the label's probe lock, so no later probe comes first.
    @discardableResult
    public static func markNewToken(context: ToolContext, account: Account, at: Date) -> Bool {
        guard account.kind == Kind.token else { return false }
        return TerminateGate.shared.recording {
            let writer = NoFollowWriter(root: context.dataRoot)
            guard
                let lock = try? writer.acquireLock(
                    folders: Layout.locksFolders, name: recordsLockName, wait: lockWaitSeconds)
            else { return false }
            defer { lock.release() }
            let reader = NoFollowReader(root: context.dataRoot)
            var marks = loadRecords(reader, name: checksName).file
            marks.tokens[account.label] = RejectionRecord(accountKey: account.accountKey, at: at)
            guard let data = try? EventLog.encoder().encode(marks),
                (try? writer.put(
                    data + Data([0x0A]), folders: Layout.stateFolders, name: checksName)) != nil
            else { return false }
            // Written after the mark, so while a mark stands every durable record postdates it.
            let loaded = loadRecords(reader, name: rejectionsName)
            var file = loaded.file
            if loaded.sound, file.tokens[account.label]?.accountKey == account.accountKey {
                file.tokens[account.label] = nil
                if let data = try? EventLog.encoder().encode(file) {
                    try? writer.put(
                        data + Data([0x0A]), folders: Layout.stateFolders, name: rejectionsName)
                }
            }
            return true
        }
    }

    /// Keeps token rejections in a file of their own, so deleting or damaging `current.json` does
    /// not make a rejected account eligible again. A label leaves the file only on positive
    /// evidence: a stored reading newer than the one the rejection saw, a new sign-in seen by a
    /// check, a new token's first probe that worked, a changed account key, or the account's
    /// removal. An entry rebuilt from nothing is never such evidence. Runs under the records
    /// lock; a record of a label whose kept new-token check this rebuild folded came after it,
    /// and the record of a `settled` label, which another command changed after the rebuild read
    /// the records, stays as it is.
    static func recordRejections(
        context: ToolContext, config: Config, current: CurrentFile,
        observations: StatusObservations, marked: Set<String> = [], settled: Set<String> = []
    ) {
        let reader = NoFollowReader(root: context.dataRoot)
        var file = RejectionsFile()
        if let data = try? reader.read(folders: Layout.stateFolders, name: rejectionsName),
            let old = try? EventLog.decoder().decode(RejectionsFile.self, from: data),
            old.schemaVersion == 1
        {
            file = old
        }
        // The record of the last rebuild, when it can be trusted: a rejection it showed and this
        // rebuild's entry no longer shows was ended by a check or probe seen by the status.
        var previous: CurrentFile?
        if let data = try? reader.read(folders: Layout.stateFolders, name: currentName),
            let old = try? EventLog.decoder().decode(CurrentFile.self, from: data),
            old.schemaVersion == CurrentFile.currentSchema, old.isSound
        {
            previous = old
        }
        let before = file.tokens
        for label in Array(file.tokens.keys)
        where !settled.contains(label)
            && !config.accounts.contains(where: { $0.label == label && $0.kind == Kind.token })
        {
            file.tokens[label] = nil
        }
        for account in config.accounts
        where account.kind == Kind.token && !settled.contains(account.label) {
            if let record = file.tokens[account.label], record.accountKey != account.accountKey {
                file.tokens[account.label] = nil
            }
            guard let entry = current.accounts[account.label],
                entry.accountKey == account.accountKey
            else { continue }
            let known = file.tokens[account.label]
            if entry.probeError?.code == StateCode.loginRejected.rawValue {
                let at = entry.lastReadingAt ?? .distantPast
                if known == nil || at > known!.at {
                    file.tokens[account.label] = RejectionRecord(
                        accountKey: account.accountKey, at: at)
                }
            } else if let known {
                let newerReading = entry.lastReadingAt.map { $0 > known.at } ?? false
                let newSignIn = observations.auth[account.label]?.newSignIn ?? false
                let newToken =
                    observations.newToken.contains(account.label)
                    && observations.probe(for: account)?.worked(after: nil) == true
                let ended =
                    !marked.contains(account.label)
                    && previous?.accounts[account.label].map {
                        $0.accountKey == account.accountKey
                            && $0.probeError?.code == StateCode.loginRejected.rawValue
                    } ?? false
                if newerReading || newSignIn || newToken || ended {
                    file.tokens[account.label] = nil
                }
            }
        }
        let unchanged =
            before.mapValues { [$0.accountKey, "\($0.at.timeIntervalSince1970)"] }
            == file.tokens.mapValues { [$0.accountKey, "\($0.at.timeIntervalSince1970)"] }
        if unchanged { return }
        if let data = try? EventLog.encoder().encode(file) {
            try? NoFollowWriter(root: context.dataRoot).put(
                data + Data([0x0A]), folders: Layout.stateFolders, name: rejectionsName)
        }
    }

    /// While a probe's rejection of the token or sign-in of `account` stands, the time that counts
    /// as the latest stored reading it saw (`Date.distantPast` for none). `state/current.json`
    /// and the durable rejection file both answer, and either one's rejection stands. A durable
    /// file that is there but cannot be read counts as a rejection (`distantFuture`). Nil
    /// otherwise.
    public static func probeRejection(context: ToolContext, account: Account) -> Date? {
        let reader = NoFollowReader(root: context.dataRoot)
        var found: Date?
        if let data = try? reader.read(folders: Layout.stateFolders, name: currentName),
            let file = try? EventLog.decoder().decode(CurrentFile.self, from: data),
            file.schemaVersion == CurrentFile.currentSchema, file.isSound,
            let entry = file.accounts[account.label], entry.accountKey == account.accountKey,
            entry.probeError?.code == StateCode.loginRejected.rawValue
        {
            found = entry.lastReadingAt ?? .distantPast
        }
        guard account.kind == Kind.token else { return found }
        let data: Data?
        do {
            data = try reader.read(folders: Layout.stateFolders, name: rejectionsName)
        } catch {
            return .distantFuture
        }
        guard let data else { return found }
        guard let file = try? EventLog.decoder().decode(RejectionsFile.self, from: data),
            file.schemaVersion == 1
        else { return .distantFuture }
        guard let record = file.tokens[account.label], record.accountKey == account.accountKey
        else { return found }
        return max(found ?? .distantPast, record.at)
    }

    /// What a status rebuild does under the data folder (`rebuilt`): it opens the history lock
    /// and the token records lock; reads the config and the files it writes again; reads the
    /// stored readings and the token files; writes `current.json`, `status.json`, the token
    /// rejections and the new token checks over what is in `state/`, rewrites or adds lines to
    /// the events record and each history file there now, and sets a damaged events record aside
    /// and starts the history of a label that has none as new files; and adds lines to the log.
    /// Its other reads, whether the launch file a session
    /// record names is there and whether a folder account's links are intact, answer without a
    /// refusal for a folder the checks refuse and change nothing, so they are not in the plan.
    static func rebuildPlan(context: ToolContext) -> NoFollowWriter.Plan {
        typealias Target = NoFollowWriter.Target
        let history = (try? ReadingHistory(context: context).labels()) ?? []
        let targets: [Target] =
            [
                .file(Layout.locksFolders, lockName, [.lock]),
                .file([], ConfigStore.fileName, [.read]),
                .folder(Layout.readingsFolders, [.open]),
                .folder(TokenPaths.folders, [.open]),
                .file(Layout.stateFolders, currentName, [.read, .replace]),
                .file(Layout.stateFolders, statusName, [.replace]),
                .file(Layout.stateFolders, rejectionsName, [.read, .replace]),
                .file(Layout.locksFolders, recordsLockName, [.lock]),
                .file(Layout.stateFolders, checksName, [.read, .replace]),
                .file(
                    Layout.stateFolders, EventLog.fileName, [.read, .replace, .append],
                    readLimit: EventLog.readLimit),
                .folder(Layout.stateFolders, [.create]),
                .folder(ReadingHistory.folders, [.create]),
            ]
            + history.sorted().map {
                Target.file(
                    ReadingHistory.folders, ReadingHistory.fileName($0),
                    [.read, .replace, .append], readLimit: ReadingHistory.readLimit)
            }
            + [.file(Layout.logsFolders, Layout.logName, [.append])]
        return NoFollowWriter.Plan(step: "status rebuild", targets: targets)
    }

    /// Throws the refusal the status rebuild would meet, from the checks of its plan
    /// (`rebuildPlan`), so a folder account's `login` proves the rebuild that records its sign-in
    /// before `claude` starts.
    public static func requireRebuildable(context: ToolContext) throws {
        try NoFollowWriter(root: context.dataRoot).require(rebuildPlan(context: context))
    }

    /// Rebuilds after a command's own work is done. A failure is logged and never changes the
    /// command's output or exit code. Returns whether `state/current.json` was saved.
    @discardableResult
    public static func rebuildQuietly(
        context: ToolContext, observations: StatusObservations = StatusObservations()
    ) -> Bool {
        NoFollowWriter.run(context.dataRoot, rebuildPlan(context: context)) {
            do {
                return try rebuilt(
                    context: context, observations: observations, now: Date(), lockWait: nil)?
                    .savedState ?? false
            } catch {
                Self.log(
                    context,
                    "status rebuild failed: \((error as? ToolError)?.message ?? "unknown")")
                return false
            }
        }
    }

    /// The log line for lines a rewrite dropped because they did not parse: a count, never their
    /// text. A nil label means the events record.
    static func droppedText(_ count: Int, label: String?) -> String {
        let lines = count == 1 ? "1 line" : "\(count) lines"
        let file = label.map { "the history of \($0)" } ?? "the events record"
        return "dropped \(lines) that did not parse from \(file)"
    }

    /// One scrubbed line in `logs/agent-balancer.log`.
    static func log(_ context: ToolContext, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = stamp + " " + Display.safe(Scrubber.scrubText(message), limit: 300) + "\n"
        try? NoFollowWriter(root: context.dataRoot).append(
            Data(line.utf8), folders: Layout.logsFolders, name: Layout.logName)
    }
}

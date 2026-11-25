import Foundation

/// The model name a Fable probe passes to `--model`.
extension ProbeForm {
    public static let fableModel = "fable"
}

/// When a refresh runs the Fable probe (docs/ARCHITECTURE.md section 4A.6).
public enum FableMode: Equatable, Sendable {
    /// Once a day per account, counting only a probe whose result was taken. What `refresh` does.
    case daily
    /// Never. A pick that is not for Fable.
    case none
    /// A pick for Fable: once a day, and also when all-models use has risen by
    /// `fable.recheckAfterWeeklyRisePercent` since the Fable reading, or the Fable window has reset.
    case forPick
}

public enum RefreshStatus: Equatable, Sendable {
    /// A new reading was stored.
    case probed(Reading)
    /// The stored reading is younger than `picker.maxReadingAgeMinutes`.
    case fresh(Reading)
    /// The account's lock stayed held until the deadline; the stored reading stands.
    case usedStored(Reading)
    case failed(Issue)
    /// A pick's deadline passed before this account's probe began, so nothing was read and
    /// nothing is observed; the stored reading, if any, stands.
    case notStarted
}

public enum FableRefreshStatus: Equatable, Sendable {
    case notRun
    case probed
    case failed(Issue)
}

/// What the duplicate check of docs/ARCHITECTURE.md section 4A.4 found after the probes of one
/// refresh. It runs in the reading cache's `afterProbe` hook, so only a token account probe that
/// gave a reading runs it.
public enum DuplicateCheck: Equatable, Sendable {
    case notRun
    case clear
    /// Both reset times equal those of the account with this label.
    case sameAs(String)

    /// The `possible_duplicate` warning, or nil.
    public var issue: Issue? {
        guard case .sameAs(let other) = self else { return nil }
        return Issue(.possibleDuplicate, .warning, TokenKind.duplicateText(other))
    }
}

private final class DuplicateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = DuplicateCheck.notRun
    var value: DuplicateCheck {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

public struct AccountRefresh: Equatable, Sendable {
    public var label: String
    public var status: RefreshStatus
    public var fable: FableRefreshStatus
    public var duplicate: DuplicateCheck = .notRun

    public var failed: Bool {
        if case .failed = status { return true }
        if case .failed = fable { return true }
        return false
    }
}

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: AccountRefresh] = [:]
    func set(_ index: Int, _ value: AccountRefresh) {
        lock.lock()
        items[index] = value
        lock.unlock()
    }
    func slots(count: Int) -> [AccountRefresh?] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<count).map { items[$0] }
    }
}

/// Hands each account's index to one probe thread, starting at `first` and going on in list order
/// from the top after the last, until every account is taken or it is closed.
private final class AccountQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private let first: Int
    private var taken = 0
    private var closed = false

    init(count: Int, first: Int) {
        self.count = count
        self.first = first
    }

    func next() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, taken < count else { return nil }
        taken += 1
        return (first + taken - 1) % count
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

/// The accounts a probe began for before the refresh closed at its deadline. Once it is closed,
/// no probe begins, plain or Fable.
private final class Begun: @unchecked Sendable {
    private let lock = NSLock()
    private var indexes: Set<Int> = []
    private var closed = false

    /// Notes that a probe of `index` begins, or returns false once the refresh is closed.
    func begin(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        indexes.insert(index)
        return true
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func contains(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexes.contains(index)
    }
}

/// Each account's result as its refresh ends, and the plain step before its Fable probe, for a
/// caller that goes on while probes still run: a pick that waits for its lock after its deadline,
/// or a `refresh` that records each result as it comes. Once closed it takes none, and a Fable
/// probe that ends after that is not counted as tried, so the next Fable pick or refresh runs it.
public final class RefreshWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [String: AccountRefresh] = [:]
    private var order: [String] = []
    private var closed = false
    private let onResult: (@Sendable (AccountRefresh) -> Void)?

    /// `onResult` hears each result it takes, on the thread of that account's probe.
    public init(onResult: (@Sendable (AccountRefresh) -> Void)? = nil) {
        self.onResult = onResult
    }

    /// Takes `result` unless closed, and says whether it did.
    func take(_ result: AccountRefresh) -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        if latest[result.label] == nil { order.append(result.label) }
        latest[result.label] = result
        lock.unlock()
        onResult?(result)
        return true
    }

    /// The latest result of each account taken so far.
    public func results() -> [AccountRefresh] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { latest[$0] }
    }

    /// The latest result of each account taken so far. It takes none after this.
    public func close() -> [AccountRefresh] {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return order.compactMap { latest[$0] }
    }
}

/// Runs the probes of `refresh`: one account lock per account, a fresh probe folder per probe,
/// readings only from the probe.
public struct Refresher: Sendable {
    public let context: ToolContext
    public let config: Config
    public var store: ReadingStore
    /// Seconds to wait for another probe of the same account. Defaults to the probe timeout plus
    /// a margin, the longest a held lock should last.
    public var lockWaitSeconds: TimeInterval
    /// The time source. Tests replace it.
    public var clock: @Sendable () -> Date = { Date() }
    /// The newest time the tool recorded before this refresher's probes began
    /// (`Upkeep.newestRecorded`), which the probe folder cleanup judges ages by.
    public var recorded: Date?
    private let runner: ClaudeRunner
    private let writer: NoFollowWriter

    static let fableInterval: TimeInterval = 86_400

    /// The most probes one refresh runs at once (docs/ARCHITECTURE.md section 6.4). Each probe is
    /// a `claude` process, so a long account list must not start them all together.
    public static let maxProbesAtOnce = 8

    /// The index a refresh starts at. A new one each time, so with more slow accounts than probe
    /// threads the same accounts are not always the ones left waiting. Tests replace it.
    var firstAccount: @Sendable (_ count: Int) -> Int = { Int.random(in: 0..<$0) }

    public init(context: ToolContext, config: Config, store: ReadingStore? = nil) {
        self.context = context
        self.config = config
        self.store = store ?? ReadingStore(context: context)
        self.runner = ClaudeRunner(context: context)
        self.writer = NoFollowWriter(root: context.dataRoot)
        self.lockWaitSeconds = Double(config.probe.timeoutSeconds) + 5
        self.recorded = Upkeep.newestRecorded(
            context: context, labels: config.accounts.map(\.label))
    }

    /// Refreshes the given accounts at the same time, at most `maxProbesAtOnce` of them at once;
    /// the rest wait for a free thread, in list order from `firstAccount`. Two probes of one
    /// account wait for each other. With a `deadline` (seconds) it returns when that has passed,
    /// and no probe, plain or Fable, begins after it: an account whose plain probe is running is
    /// reported `check_failed`; one whose probe has not begun, still waiting for a thread or for
    /// its lock, is `notStarted`; one whose Fable probe is running is reported by its plain step,
    /// a fresh reading or a finished plain probe. A running probe is left to end on its own, and
    /// `watch` takes its result when it ends. `forced` names labels probed even when their
    /// reading is fresh. `reprobe` names labels where a probe's rejection of the sign-in stands,
    /// each with the time the status counts as the latest stored reading it saw
    /// (`StatusBuilder.probeRejection`): such an account is probed even when its reading is
    /// fresh, but not once a newer one is stored, which only a probe that worked can do.
    public func refresh(
        accounts: [Account], force: Bool, forced: Set<String> = [], fable: FableMode = .daily,
        deadline: TimeInterval? = nil, reprobe: [String: Date] = [:], watch: RefreshWatch? = nil
    ) -> [AccountRefresh] {
        let results = Results()
        let begun = Begun()
        let queue = AccountQueue(
            count: accounts.count, first: accounts.isEmpty ? 0 : firstAccount(accounts.count))
        let done = DispatchGroup()
        // Threads of their own: concurrentPerform may run blocking probes one at a time.
        for _ in 0..<min(Self.maxProbesAtOnce, accounts.count) {
            done.enter()
            Thread {
                while let index = queue.next() {
                    let account = accounts[index]
                    results.set(
                        index,
                        refresh(
                            account: account, force: force || forced.contains(account.label),
                            fable: fable, rejectedAt: reprobe[account.label],
                            begin: { begun.begin(index) },
                            report: {
                                results.set(index, $0)
                                _ = watch?.take($0)
                            }, finish: { watch?.take($0) ?? true }))
                }
                done.leave()
            }.start()
        }
        if let deadline {
            if done.wait(timeout: .now() + max(0, deadline)) == .timedOut {
                queue.close()
                begun.close()
            }
        } else {
            done.wait()
        }
        let missed = Issue(.checkFailed, .error, "Check failed: the refresh missed the deadline.")
        return results.slots(count: accounts.count).enumerated().map { index, value in
            if let value { return value }
            // Only a probe that ran says anything about the account.
            return AccountRefresh(
                label: accounts[index].label,
                status: begun.contains(index) ? .failed(missed) : .notStarted, fable: .notRun)
        }
    }

    /// The reading cache with its `afterProbe` hook set to the duplicate check, which writes what
    /// it found into `box`. A hook the caller set still runs first.
    private func storeWithDuplicateCheck(into box: DuplicateBox) -> ReadingStore {
        var store = self.store
        let caller = store.afterProbe
        let base = self.store
        let accounts = config.accounts
        let clock = self.clock
        store.afterProbe = { label, reading in
            caller(label, reading)
            var readings = [label: reading]
            for other in accounts where other.label != label {
                if let stored = try? base.load(label: other.label) {
                    readings[other.label] = stored
                }
            }
            let other = TokenKind.possibleDuplicate(
                of: label, accounts: accounts, readings: readings, now: clock())
            box.value = other.map(DuplicateCheck.sameAs) ?? .clear
        }
        return store
    }

    /// `finish` hears the result as the account's refresh ends, before the account's lock is let go
    /// when a probe ran.
    public func refresh(
        account: Account, force: Bool, fable mode: FableMode = .daily,
        finish: (AccountRefresh) -> Void = { _ in }
    ) -> AccountRefresh {
        refresh(
            account: account, force: force, fable: mode, rejectedAt: nil, begin: { true },
            report: { _ in },
            finish: {
                finish($0)
                return true
            })
    }

    /// `finish` hears the account's result once, as it ends, and says whether a caller took it;
    /// only a Fable probe whose result was taken counts as tried.
    private func refresh(
        account: Account, force: Bool, fable mode: FableMode, rejectedAt: Date?,
        begin: () -> Bool, report: (AccountRefresh) -> Void,
        finish: (AccountRefresh) -> Bool
    ) -> AccountRefresh {
        var finished = false
        let result = steps(
            account: account, force: force, fable: mode, rejectedAt: rejectedAt, begin: begin,
            report: report
        ) {
            finished = true
            return finish($0)
        }
        if !finished { _ = finish(result) }
        return result
    }

    /// `begin` runs just before each probe, plain or Fable; when it returns false that probe does
    /// not run. `report` hears the plain result before a Fable probe begins, and `finish` the
    /// result once the probes have ended, while the account's lock is still held. `rejectedAt` is
    /// the account's `reprobe` time, if any.
    private func steps(
        account: Account, force: Bool, fable mode: FableMode, rejectedAt: Date?,
        begin: () -> Bool, report: (AccountRefresh) -> Void,
        finish: (AccountRefresh) -> Bool
    ) -> AccountRefresh {
        NoFollowWriter.run(context.dataRoot, checkPlan(account: account)) {
            checkSteps(
                account: account, force: force, fable: mode, rejectedAt: rejectedAt, begin: begin,
                report: report, finish: finish)
        }
    }

    private func checkSteps(
        account: Account, force: Bool, fable mode: FableMode, rejectedAt: Date?,
        begin: () -> Bool, report: (AccountRefresh) -> Void,
        finish: (AccountRefresh) -> Bool
    ) -> AccountRefresh {
        // A stored reading newer than the time the status counts as the latest one it saw came
        // from a probe that worked since, so the freshness rule holds again.
        func probeAgain(_ stored: Reading) -> Bool {
            rejectedAt.map { stored.readAt <= $0 } ?? false
        }
        let duplicate = DuplicateBox()
        let store = storeWithDuplicateCheck(into: duplicate)
        func failed(_ issue: Issue) -> AccountRefresh {
            AccountRefresh(
                label: account.label, status: .failed(issue), fable: .notRun,
                duplicate: duplicate.value)
        }
        let probe: ProbeContext
        do {
            probe = try AccountKinds.probeContext(for: account, context: context)
        } catch let error as ToolError {
            return failed(Issue(error.code ?? .checkFailed, .error, error.message))
        } catch {
            return failed(Issue(.checkFailed, .error, "Check failed: the account is not ready."))
        }

        let maxAge = config.picker.maxReadingAgeMinutes
        do {
            var now = clock()
            let early = try store.load(label: account.label)
            if !force, let early, early.isFresh(now: now, maxAgeMinutes: maxAge),
                !fableDue(early, now: now, mode: mode), !probeAgain(early)
            {
                return AccountRefresh(label: account.label, status: .fresh(early), fable: .notRun)
            }
            guard
                let lock = try writer.acquireLock(
                    folders: Layout.locksFolders, name: Layout.lockName(account.label),
                    wait: lockWaitSeconds)
            else {
                if let early {
                    return AccountRefresh(
                        label: account.label, status: .usedStored(early), fable: .notRun)
                }
                return failed(
                    Issue(
                        .checkFailed, .error,
                        "Check failed: another probe of this account is still running."))
            }
            defer { lock.release() }
            // A command that changes the sign-in a label stands for holds this lock while it does.
            guard Self.registryStillHolds(account, context: context) else {
                return AccountRefresh(label: account.label, status: .notStarted, fable: .notRun)
            }

            // Another caller may have finished a probe while this one waited for the lock.
            now = clock()
            var stored = try store.load(label: account.label)
            var status: RefreshStatus
            if !force, let current = stored, current.isFresh(now: now, maxAgeMinutes: maxAge),
                !probeAgain(current)
            {
                status = .fresh(current)
            } else {
                guard begin() else {
                    return AccountRefresh(label: account.label, status: .notStarted, fable: .notRun)
                }
                switch runProbe(account: account, probe: probe, fable: false) {
                case .failed(let issue): status = .failed(issue)
                case .reading(let reading):
                    // The clock read that dated the reading decides its merge: a later read, set
                    // back, would keep a passed reset time under a reading dated after it.
                    let merged = try store.record(
                        reading, label: account.label, callsHook: probe.callsAfterProbeHook,
                        fable: config.fable, now: reading.readAt)
                    stored = merged
                    status = .probed(merged)
                }
            }

            var fableStatus = FableRefreshStatus.notRun
            var plainFailed = false
            if case .failed = status { plainFailed = true }
            now = clock()
            if !plainFailed, let current = stored,
                fableDue(current, now: now, mode: mode)
            {
                let plain = AccountRefresh(
                    label: account.label, status: status, fable: .notRun,
                    duplicate: duplicate.value)
                // A Fable probe still running at a deadline leaves the plain result to stand.
                report(plain)
                guard begin() else { return plain }
                let tried = now
                switch runProbe(account: account, probe: probe, fable: true) {
                case .failed(let issue): fableStatus = .failed(issue)
                case .reading(let reading):
                    // A Fable reply the store refuses fails only the Fable probe; the plain
                    // reading saved above stands. As for the plain one, the reply's own time
                    // decides the merge, so a reset time that passed during the probe is not held.
                    do {
                        try store.record(
                            reading, label: account.label, callsHook: probe.callsAfterProbeHook,
                            fable: config.fable, now: reading.readAt)
                        fableStatus = .probed
                    } catch let error as ToolError where error.code == .checkFailed {
                        fableStatus = .failed(Issue(.checkFailed, .error, error.message))
                    }
                }
                let result = AccountRefresh(
                    label: account.label, status: status, fable: fableStatus,
                    duplicate: duplicate.value)
                // Counted once its result is taken, so one cut off unheard is not put off a day.
                if finish(result) { try? store.noteFableAttempt(label: account.label, at: tried) }
                return result
            }
            let result = AccountRefresh(
                label: account.label, status: status, fable: fableStatus,
                duplicate: duplicate.value)
            // Heard before the lock is let go, so no later probe of the account comes first.
            _ = finish(result)
            return result
        } catch let error as ToolError {
            return failed(Issue(error.code ?? .checkFailed, .error, error.message))
        } catch {
            return failed(Issue(.checkFailed, .error, "Check failed: a file could not be used."))
        }
    }

    /// What a check of `account` does under the data folder (`steps`): it reads the config and
    /// the stored reading, opens the account's probe lock, makes its probe folder in `probe/` and
    /// removes it, as each probe does with its own, and writes the reading over the stored one;
    /// it also opens the token folder for a token account, or the account's folders for a folder
    /// account. The token file it reads is the one the token save makes in that folder, a new
    /// file the save's own plan proves the reader can open there.
    func checkPlan(account: Account) -> NoFollowWriter.Plan {
        var targets: [NoFollowWriter.Target] = [
            .file([], ConfigStore.fileName, [.read]),
            .file(Layout.locksFolders, Layout.lockName(account.label), [.lock]),
            .scratch(Layout.probeFolders, prefix: Layout.probeFolderPrefix, staleAfter: staleAfter),
            .file(Layout.readingsFolders, Layout.readingName(account.label), [.read, .replace]),
        ]
        if account.kind == Kind.token {
            targets.append(.folder(TokenPaths.folders, [.open]))
        } else if account.kind == Kind.folder {
            targets.append(.folder(FolderPaths.folders(label: account.label), [.open]))
        }
        var plan = NoFollowWriter.Plan(step: "check", targets: targets)
        plan.judgedAt = Upkeep.judgedAt(now: Date(), recorded: recorded)
        return plan
    }

    /// Seconds after which a probe folder left behind is another probe's no longer.
    private var staleAfter: TimeInterval {
        Double(max(config.probe.timeoutSeconds, config.fable.probeTimeoutSeconds))
    }

    /// A Fable probe runs when `fable.probe` is on, a reading is stored and the last Fable probe
    /// was more than a day ago. `--force` does not lift this limit, because a Fable probe costs
    /// cents rather than fractions of one.
    func fableDue(_ stored: Reading, now: Date) -> Bool {
        fableDue(stored, now: now, mode: .daily)
    }

    /// Seconds between two Fable probes that the weekly-rise rule asks for.
    static let fableRiseCooldown: TimeInterval = 600

    func fableDue(_ stored: Reading, now: Date, mode: FableMode) -> Bool {
        guard config.fable.probe, mode != .none else { return false }
        guard let last = stored.fableProbedAt else { return true }
        // A time ahead of the clock would otherwise block the probe until that time.
        if last > now.addingTimeInterval(60) { return true }
        if now.timeIntervalSince(last) >= Self.fableInterval { return true }
        guard mode == .forPick, now.timeIntervalSince(last) >= Self.fableRiseCooldown,
            let fable = stored.fable, fable.source == ReadingSource.probe
        else { return false }
        if let reset = fable.resetsAt, reset <= now { return true }
        if let weekly = stored.sevenDay?.usedPercent, let at = fable.weeklyUsedPercentAtRead,
            weekly - at >= Double(config.fable.recheckAfterWeeklyRisePercent)
        {
            return true
        }
        return false
    }

    /// False when a saved registry no longer holds `account` under its label: the same account
    /// key, kind and email, the email compared without letter case. With no registry saved there
    /// is nothing to compare with, and one that cannot be read counts as changed.
    static func registryStillHolds(_ account: Account, context: ToolContext) -> Bool {
        let saved: Config?
        do {
            saved = try ConfigStore(context: context).load()
        } catch {
            return false
        }
        guard let saved else { return true }
        guard let current = saved.account(account.label) else { return false }
        return isSameAccount(current, account)
    }

    /// True when two registry entries of one label stand for the same account: the same account
    /// key, kind and email, the email compared without letter case.
    static func isSameAccount(_ a: Account, _ b: Account) -> Bool {
        a.accountKey == b.accountKey && a.kind == b.kind
            && a.email?.lowercased() == b.email?.lowercased()
    }

    /// The first error that says a login or folder account is not signed in as its own account, or
    /// nil. Other kinds have no sign-in to check.
    static func identityIssue(account: Account, runner: ClaudeRunner, now: Date) -> Issue? {
        guard [Kind.login, Kind.folder].contains(account.kind),
            let handler = AccountKinds.handler(for: account.kind)
        else { return nil }
        let codes: [StateCode] = [.wrongAccount, .loginRejected, .checkFailed]
        return handler.check(account: account, runner: runner, now: now).issues.first {
            $0.severity == .error && codes.contains($0.code)
        }
    }

    /// A probe bound to the account's sign-in: it is checked just before the probe and again after
    /// it, and a reading made while the sign-in was another account's is dropped.
    private func runProbe(account: Account, probe: ProbeContext, fable: Bool)
        -> ProbeReadResult
    {
        if let issue = Self.identityIssue(account: account, runner: runner, now: clock()) {
            return .failed(issue)
        }
        let result = runProbeUnchecked(account: account, probe: probe, fable: fable)
        guard case .reading = result else { return result }
        if let issue = Self.identityIssue(account: account, runner: runner, now: clock()) {
            return .failed(issue)
        }
        return result
    }

    private func runProbeUnchecked(account: Account, probe: ProbeContext, fable: Bool)
        -> ProbeReadResult
    {
        let timeout = fable ? config.fable.probeTimeoutSeconds : config.probe.timeoutSeconds
        let folder: String
        let lock: FileLock
        do {
            // Another probe's folder is aged against the tool's own records, not the clock alone.
            (folder, lock) = try writer.makeLockedScratchFolder(
                parent: Layout.probeFolders, prefix: Layout.probeFolderPrefix,
                staleAfter: staleAfter, judgedAt: Upkeep.judgedAt(now: Date(), recorded: recorded))
        } catch let error as ToolError {
            return .failed(Issue(.checkFailed, .error, "Check failed: \(error.message)"))
        } catch {
            return .failed(Issue(.checkFailed, .error, "Check failed: no probe folder."))
        }
        defer {
            writer.removeScratchFolder(
                parent: Layout.probeFolders, name: folder, prefix: Layout.probeFolderPrefix)
            lock.release()
        }
        let cwd = context.dataRoot.appendingPathComponent("probe", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)

        let arguments =
            ProbeForm.arguments(
                model: fable ? ProbeForm.fableModel : "haiku",
                budgetUsd: fable ? String(format: "%.2f", config.fable.probeBudgetUsd) : "0.05",
                safeMode: config.probe.safeMode) + probe.extraArguments
        let output: RunOutput
        do {
            output = try runner.run(
                arguments: arguments, configDir: probe.configDir, timeout: Double(timeout),
                passProxyEnv: config.probe.passProxyEnv, workingDirectory: cwd,
                environment: .probe)
        } catch let error as ToolError {
            return .failed(Issue(error.code ?? .checkFailed, .error, error.message))
        } catch {
            return .failed(Issue(.checkFailed, .error, "Check failed: claude could not run."))
        }
        if let issue = ProbeForm.failure(for: output) { return .failed(issue) }
        let finished = clock()
        let parsed = ProbeReader.parse(
            output.stdout,
            readAt: Date(timeIntervalSince1970: floor(finished.timeIntervalSince1970)))
        if case .failed(var issue) = parsed, output.status != 0, issue.code == .checkFailed {
            let shown = Display.safe(String(output.stderr.prefix(200)))
            if !shown.isEmpty {
                issue = Issue(.checkFailed, .error, issue.text + " " + shown)
                return .failed(issue)
            }
        }
        return parsed
    }
}

import Foundation

/// The model name a Fable probe passes to `--model`.
extension ProbeForm {
    public static let fableModel = "fable"
}

public enum RefreshStatus: Equatable, Sendable {
    /// A new reading was stored.
    case probed(Reading)
    /// The stored reading is younger than `picker.maxReadingAgeMinutes`.
    case fresh(Reading)
    /// The account's lock stayed held until the deadline; the stored reading stands.
    case usedStored(Reading)
    case failed(Issue)
}

public enum FableRefreshStatus: Equatable, Sendable {
    case notRun
    case probed
    case failed(Issue)
}

public struct AccountRefresh: Equatable, Sendable {
    public var label: String
    public var status: RefreshStatus
    public var fable: FableRefreshStatus

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
    func ordered(count: Int) -> [AccountRefresh] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<count).compactMap { items[$0] }
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
    private let runner: ClaudeRunner
    private let writer: NoFollowWriter

    static let fableInterval: TimeInterval = 86_400

    public init(context: ToolContext, config: Config, store: ReadingStore? = nil) {
        self.context = context
        self.config = config
        self.store = store ?? ReadingStore(context: context)
        self.runner = ClaudeRunner(context: context)
        self.writer = NoFollowWriter(root: context.dataRoot)
        self.lockWaitSeconds = Double(config.probe.timeoutSeconds) + 5
    }

    /// Refreshes the given accounts at the same time. Different accounts never wait for each
    /// other; two probes of one account do.
    public func refresh(accounts: [Account], force: Bool) -> [AccountRefresh] {
        let results = Results()
        let done = DispatchGroup()
        // A thread per account: concurrentPerform may run blocking probes one at a time.
        for (index, account) in accounts.enumerated() {
            done.enter()
            Thread {
                results.set(index, refresh(account: account, force: force))
                done.leave()
            }.start()
        }
        done.wait()
        return results.ordered(count: accounts.count)
    }

    public func refresh(account: Account, force: Bool) -> AccountRefresh {
        func failed(_ issue: Issue) -> AccountRefresh {
            AccountRefresh(label: account.label, status: .failed(issue), fable: .notRun)
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
                !fableDue(early, now: now)
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

            // Another caller may have finished a probe while this one waited for the lock.
            now = clock()
            var stored = try store.load(label: account.label)
            var status: RefreshStatus
            if !force, let current = stored, current.isFresh(now: now, maxAgeMinutes: maxAge) {
                status = .fresh(current)
            } else {
                switch runProbe(account: account, probe: probe, fable: false) {
                case .failed(let issue): status = .failed(issue)
                case .reading(let reading):
                    let merged = try store.record(
                        reading, label: account.label, callsHook: probe.callsAfterProbeHook,
                        fable: config.fable, now: clock())
                    stored = merged
                    status = .probed(merged)
                }
            }

            var fableStatus = FableRefreshStatus.notRun
            var plainFailed = false
            if case .failed = status { plainFailed = true }
            now = clock()
            if !plainFailed, let current = stored, fableDue(current, now: now) {
                try store.noteFableAttempt(label: account.label, at: now)
                switch runProbe(account: account, probe: probe, fable: true) {
                case .failed(let issue): fableStatus = .failed(issue)
                case .reading(let reading):
                    try store.record(
                        reading, label: account.label, callsHook: probe.callsAfterProbeHook,
                        fable: config.fable, now: now)
                    fableStatus = .probed
                }
            }
            return AccountRefresh(label: account.label, status: status, fable: fableStatus)
        } catch let error as ToolError {
            return failed(Issue(error.code ?? .checkFailed, .error, error.message))
        } catch {
            return failed(Issue(.checkFailed, .error, "Check failed: a file could not be used."))
        }
    }

    /// A Fable probe runs when `fable.probe` is on, a reading is stored and the last Fable probe
    /// was more than a day ago. `--force` does not lift this limit, because a Fable probe costs
    /// cents rather than fractions of one.
    func fableDue(_ stored: Reading, now: Date) -> Bool {
        guard config.fable.probe else { return false }
        guard let last = stored.fableProbedAt else { return true }
        // A time ahead of the clock would otherwise block the probe until that time.
        if last > now.addingTimeInterval(60) { return true }
        return now.timeIntervalSince(last) >= Self.fableInterval
    }

    private func runProbe(account: Account, probe: ProbeContext, fable: Bool)
        -> ProbeReadResult
    {
        let timeout = fable ? config.fable.probeTimeoutSeconds : config.probe.timeoutSeconds
        let stale = Double(max(config.probe.timeoutSeconds, config.fable.probeTimeoutSeconds))
        let folder: String
        do {
            folder = try writer.makeScratchFolder(
                parent: Layout.probeFolders, prefix: Layout.probeFolderPrefix, staleAfter: stale)
        } catch let error as ToolError {
            return .failed(Issue(.checkFailed, .error, "Check failed: \(error.message)"))
        } catch {
            return .failed(Issue(.checkFailed, .error, "Check failed: no probe folder."))
        }
        defer {
            writer.removeScratchFolder(
                parent: Layout.probeFolders, name: folder, prefix: Layout.probeFolderPrefix)
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

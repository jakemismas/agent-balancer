import ArgumentParser
import Core
import Foundation

struct RefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Read each account's usage with a one-turn probe and store the reading.",
        discussion:
            "A reading younger than picker.maxReadingAgeMinutes is kept without a plain probe, except for an account whose sign-in a probe found rejected, as the status records it, which is probed again; while fable.probe is on, its default, the daily Fable probe still runs on a fresh reading. It also checks the sign-in of each login and folder account whose probe did not fail, with `claude auth status`, which spends no usage."
    )

    @Option(name: .long, help: "Refresh only this account.")
    var label: String?

    @Flag(name: .long, help: "Probe even when the stored reading is still fresh.")
    var force = false

    func run() throws {
        let context = ToolContext.current()
        let config = try ConfigStore(context: context).loadRequired()
        // Read before this run's probes record anything, so a clock that moved forward ages
        // nothing by itself.
        let recorded = Upkeep.newestRecorded(
            context: context, labels: config.accounts.map(\.label))
        var accounts = config.accounts
        if let label {
            guard let one = config.account(label) else {
                throw ToolError("No account is labelled '\(Display.safe(label))'.")
            }
            accounts = [one]
        }
        guard !accounts.isEmpty else {
            // `doctor` sends people here to delete a write's leftovers, with or without accounts.
            Self.upkeep(context, config, recorded)
            print("No accounts to refresh.")
            return
        }

        // A sign-in check that sees the old sign-in leaves a probe's rejection standing, so such
        // an account is probed again even while its reading is fresh. The rest keep the
        // freshness rule.
        var rejected: [String: Date] = [:]
        for account in accounts {
            if let at = StatusBuilder.probeRejection(context: context, account: account) {
                rejected[account.label] = at
            }
        }
        let recorder = ProbeRecorder(context: context)
        var refresher = Refresher(context: context, config: config)
        refresher.recorded = recorded
        let results = refresher.refresh(
            accounts: accounts, force: force, reprobe: rejected,
            watch: RefreshWatch(onResult: { recorder.record($0) }))
        var failed = false
        for result in results {
            let name = Display.safe(result.label)
            switch result.status {
            case .probed(let reading): print("\(name): \(Self.summary(reading, prefix: "read"))")
            case .fresh(let reading): print("\(name): \(Self.summary(reading, prefix: "fresh"))")
            case .usedStored(let reading):
                print("\(name): \(Self.summary(reading, prefix: "busy, kept stored"))")
            case .failed(let issue):
                print("\(name): " + Shared.line(issue))
            case .notStarted:
                print("\(name): not checked: the account changed while the check waited")
            }
            switch result.fable {
            case .notRun: break
            case .probed: print("\(name): fable meter read")
            case .failed(let issue): print("\(name): fable " + Shared.line(issue))
            }
            if result.failed { failed = true }
        }
        Self.upkeep(context, config, recorded)
        var observations = StatusObservations()
        observations.add(recorder.unrecorded(results))
        // What the probes found is recorded however the refresh ends, after any plan is saved.
        defer { Shared.rebuildStatus(context, observations: observations) }
        // Every refresh checks the sign-in, which costs no usage, so a sign-in that is back clears
        // a check's `login_rejected` without waiting for the reading to age.
        var tiers: [String: (tier: String, emailDigest: String?)] = [:]
        let runner = ClaudeRunner(context: context)
        for account in accounts where account.kind == Kind.login || account.kind == Kind.folder {
            guard let outcome = results.first(where: { $0.label == account.label }),
                !outcome.failed, let handler = AccountKinds.handler(for: account.kind)
            else { continue }
            let check = handler.check(account: account, runner: runner, now: Date())
            let observation = AuthObservation(check)
            observations.auth[account.label] = observation
            // Only the first check that placed the expected sign-in in its own folder fixes the
            // plan; a later one that sees another plan reports `plan_changed`, as `status` does.
            if account.expectedPlanTier == nil, observation.seen == .signedIn,
                let tier = check.planTier
            {
                tiers[account.label] = (tier, check.emailDigest)
            }
        }
        try Shared.recordExpectedTiers(context: context, tiers: tiers)
        if failed { throw ExitCode.failure }
    }

    /// Runs the launch file upkeep and says which of the writer's temporary files that may hold a
    /// token it could not delete, or, when it did not run, why and which ones are still there.
    static func upkeep(_ context: ToolContext, _ config: Config, _ recorded: Date?) {
        let pass = Upkeep.runLocked(context: context, config: config, recorded: recorded)
        for text in (pass.notRun.map { [$0] } ?? []) + pass.temporariesLeft {
            // The tool's own text, so a list of files in one prints whole.
            print("Warning: " + Display.safe(text, limit: Int.max))
        }
    }

    static func summary(_ reading: Reading, prefix: String) -> String {
        func percent(_ window: WindowReading?) -> String {
            window.map { String(format: "%.1f%%", $0.usedPercent) } ?? "n/a"
        }
        return
            "\(prefix) (5 hour \(percent(reading.fiveHour)), week \(percent(reading.sevenDay)))"
    }
}

/// Records what each account's probes found in the status as its refresh ends, so a refresh that
/// is ended early, as the menu ends one past its timeout, keeps what its finished probes found.
private final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let context: ToolContext
    private var recorded: [String: AccountRefresh] = [:]

    init(context: ToolContext) {
        self.context = context
    }

    func record(_ result: AccountRefresh) {
        var observations = StatusObservations()
        observations.add([result])
        // A rebuild that saved no `state/current.json` leaves the result to the refresh's last one.
        guard !observations.probe.isEmpty,
            StatusBuilder.rebuildQuietly(context: context, observations: observations)
        else { return }
        lock.lock()
        recorded[result.label] = result
        lock.unlock()
    }

    /// The results the status does not hold yet in their last form.
    func unrecorded(_ results: [AccountRefresh]) -> [AccountRefresh] {
        lock.lock()
        defer { lock.unlock() }
        return results.filter { recorded[$0.label] != $0 }
    }
}

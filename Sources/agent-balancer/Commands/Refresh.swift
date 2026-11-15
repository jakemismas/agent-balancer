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
        var accounts = config.accounts
        if let label {
            guard let one = config.account(label) else {
                throw ToolError("No account is labelled '\(Display.safe(label))'.")
            }
            accounts = [one]
        }
        guard !accounts.isEmpty else {
            // `doctor` sends people here to delete a write's leftovers, with or without accounts.
            Upkeep.runLocked(context: context, config: config)
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
        let results = Refresher(context: context, config: config)
            .refresh(accounts: accounts, force: force, reprobe: rejected)
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
                print("\(name): not checked, the refresh ran out of time")
            }
            switch result.fable {
            case .notRun: break
            case .probed: print("\(name): fable meter read")
            case .failed(let issue): print("\(name): fable " + Shared.line(issue))
            }
            if result.failed { failed = true }
        }
        Upkeep.runLocked(context: context, config: config)
        var observations = StatusObservations()
        observations.add(results)
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

    static func summary(_ reading: Reading, prefix: String) -> String {
        func percent(_ window: WindowReading?) -> String {
            window.map { String(format: "%.1f%%", $0.usedPercent) } ?? "n/a"
        }
        return
            "\(prefix) (5 hour \(percent(reading.fiveHour)), week \(percent(reading.sevenDay)))"
    }
}

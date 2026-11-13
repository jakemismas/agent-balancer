import ArgumentParser
import Core
import Foundation

struct RefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Read each account's usage with a one-turn probe and store the reading.")

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

        let results = Refresher(context: context, config: config)
            .refresh(accounts: accounts, force: force)
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
        // The first refresh after a sign-in fixes the plan the account is expected to keep.
        var tiers: [String: String] = [:]
        let runner = ClaudeRunner(context: context)
        for account in accounts
        where account.expectedPlanTier == nil
            && (account.kind == Kind.login || account.kind == Kind.folder)
        {
            guard let outcome = results.first(where: { $0.label == account.label }),
                !outcome.failed, let handler = AccountKinds.handler(for: account.kind)
            else { continue }
            let check = handler.check(account: account, runner: runner, now: Date())
            observations.auth[account.label] = AuthObservation(check)
            if check.signedIn, !check.issues.contains(where: { $0.code == .wrongAccount }),
                let tier = check.planTier
            {
                tiers[account.label] = tier
            }
        }
        try Shared.recordExpectedTiers(context: context, tiers: tiers)
        Shared.rebuildStatus(context, observations: observations)
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

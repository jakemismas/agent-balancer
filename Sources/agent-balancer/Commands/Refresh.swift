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

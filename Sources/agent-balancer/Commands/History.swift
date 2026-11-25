import ArgumentParser
import Core
import Foundation

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "Show each account's readings over time.")

    @Flag(name: .long, help: "Print the answer as JSON.")
    var json = false

    @Option(name: .long, help: "Only this account.")
    var label: String?

    @Option(name: .long, help: "Only readings since this time or span. The default is 24h.")
    var since: String?

    @Option(name: .long, help: "At most this many readings per account, from 1 to 1000.")
    var limit: Int?

    func run() throws {
        let context = try ToolContext.current()
        let config = try ConfigStore(context: context).load()
        let answer = try ReadingHistory(context: context).answer(
            HistoryQuery(label: label, since: since, limit: limit), config: config)
        if json {
            print(String(decoding: try StatusDocument.encoder().encode(answer), as: UTF8.self))
            return
        }
        for account in answer.accounts {
            print("\(Display.safe(account.label)): \(account.readings.count) readings")
            for reading in account.readings {
                let week = reading.weekly?.usedPercent.map { String(format: "%.1f%%", $0) } ?? "n/a"
                let stamp = ISO8601DateFormatter().string(from: reading.at)
                print("  \(stamp) \(Display.safe(reading.state)) week \(week)")
            }
        }
    }
}

import ArgumentParser
import Core
import Foundation

struct EventsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Show what changed since you last looked: limits, errors and recoveries.")

    @Flag(name: .long, help: "Print the answer as JSON.")
    var json = false

    @Option(name: .long, help: "Only events after this number. Use the cursor of the last answer.")
    var after: Int?

    @Option(name: .long, help: "Only events since this time or span, such as 24h.")
    var since: String?

    @Option(name: .long, help: "Only events of this account.")
    var label: String?

    @Option(name: .long, help: "Only events of this type.")
    var type: String?

    @Option(name: .long, help: "At most this many events, from 1 to 1000. The default is 200.")
    var limit: Int?

    func run() throws {
        let context = ToolContext.current()
        let answer = try EventLog(context: context).answer(
            EventsQuery(after: after, since: since, label: label, type: type, limit: limit))
        if json {
            print(String(decoding: try StatusDocument.encoder().encode(answer), as: UTF8.self))
            return
        }
        if answer.events.isEmpty { print("No events.") }
        for event in answer.events {
            let stamp = ISO8601DateFormatter().string(from: event.at)
            print(
                "\(event.seq) \(stamp) \(Display.safe(event.label)) \(Display.safe(event.type)): "
                    + Display.safe(event.text, limit: 300))
        }
        print("cursor: \(answer.cursor)")
    }
}

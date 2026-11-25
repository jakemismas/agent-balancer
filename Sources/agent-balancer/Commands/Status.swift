import ArgumentParser
import Core
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show every account's state, usage, sessions and the next launch.")

    @Flag(name: .long, help: "Print the status document as JSON.")
    var json = false

    @Flag(name: .long, help: "Rebuild from saved readings and start no child process.")
    var cached = false

    func run() throws {
        let context = try ToolContext.current()
        let config = try ConfigStore(context: context).loadRequired()
        var observations = StatusObservations()
        if !cached {
            // Only a login or folder account is checked, with `auth status`. A status never probes
            // and never runs a command for a token account.
            let runner = ClaudeRunner(context: context)
            let now = Date()
            for account in config.accounts
            where account.kind == Kind.login || account.kind == Kind.folder {
                guard let handler = AccountKinds.handler(for: account.kind) else { continue }
                let check = handler.check(account: account, runner: runner, now: now)
                observations.auth[account.label] = AuthObservation(check)
            }
        }
        guard let document = try StatusBuilder.rebuild(context: context, observations: observations)
        else { throw ToolError("status busy: another command is updating the status. Try again.") }
        if json {
            print(String(decoding: try StatusDocument.encoder().encode(document), as: UTF8.self))
        } else {
            Self.printTable(document)
        }
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }

    static func percent(_ window: WindowStatus?) -> String {
        guard let used = window?.usedPercent else { return "n/a" }
        return String(format: "%.1f%%", used)
    }

    static func printTable(_ document: StatusDocument) {
        if let banner = document.banner { print(Display.safe(banner.text, limit: 200)) }
        if document.accounts.isEmpty { print("No accounts are set up.") }
        for a in document.accounts {
            let uses = a.inUse.count.map(String.init) ?? "unknown"
            print(
                "\(Display.safe(a.label)) [\(Display.safe(a.kind)), \(Display.safe(a.role))] "
                    + "\(Display.safe(a.state)) week \(percent(a.weekly)) 5h \(percent(a.fiveHour)) "
                    + "resets \(time(a.weekly.resetsAt)) in use \(uses)")
            if let names = a.noLimit {
                print("  no-limit: \(Display.safe(names.joined(separator: ", ")))")
            }
            if let limited = a.limited {
                print("  limited (\(Display.safe(limited.window))) until \(time(limited.until))")
            }
            if let error = a.error {
                print(
                    "  error \(Display.safe(error.code)): \(Display.safe(error.text, limit: 300))")
            }
            for warning in a.warnings {
                print(
                    "  warning \(Display.safe(warning.code)): \(Display.safe(warning.text, limit: 300))"
                )
            }
        }
        if let label = document.next.all.label {
            print("next: \(Display.safe(label))")
        } else {
            print("next: none")
        }
        if let label = document.next.fable.label {
            print("next for fable: \(Display.safe(label))")
        } else {
            print("next for fable: none")
        }
    }
}

import ArgumentParser
import Core
import Foundation

struct PickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pick",
        abstract: "Choose the account for the next launch and return the recipe to apply.")

    @Flag(name: .long, help: "Print the answer as JSON.")
    var json = false

    @Option(name: .long, help: "The model the launch is for. Only the Fable budget rule uses it.")
    var model: String?

    @Option(name: .long, help: "The caller's own settings as one JSON object.")
    var settings: String?

    @Flag(name: .customLong("full-login"), help: "Offer only accounts with a full login.")
    var fullLogin = false

    @Option(name: .long, help: "How the recipe is applied: typed or launcher.")
    var caller = "typed"

    @Option(name: .long, help: "Leave this account out of the pick. Repeat for more.")
    var exclude: [String] = []

    @Flag(name: .customLong("dry-run"), help: "Decide only. Write no lease and no launch file.")
    var dryRun = false

    func run() throws {
        guard let applyAs = PickCaller(rawValue: caller) else {
            throw ToolError("--caller must be typed or launcher.")
        }
        let context = ToolContext.current()
        let request = PickRequest(
            model: model, settings: settings, fullLogin: fullLogin, caller: applyAs,
            exclude: exclude, dryRun: dryRun)
        let result = try PickService(context: context).pick(request)

        if json {
            let data = try PickResult.encoder().encode(result)
            print(String(decoding: data, as: UTF8.self))
        } else {
            Self.printText(result)
        }
        if !result.picked { throw ExitCode(2) }
    }

    static func printText(_ result: PickResult) {
        if let label = result.label {
            print("account: \(Display.safe(label))")
        } else {
            print("account: none")
        }
        print("reason: \(Display.safe(result.reason, limit: 800))")
        if let prefix = result.launchPrefix, let args = result.launchArgs {
            print("launch prefix: '\(prefix)'")
            print("launch args: \(args)")
        }
        if let args = result.args { print("args: \(args.joined(separator: " "))") }
        if let unset = result.unsetEnv { print("unset env: \(unset.joined(separator: " "))") }
        if result.backgroundOnly { print("background only: use claude --bg") }
        for candidate in result.candidates {
            let mark = candidate.eligible ? "eligible" : "skipped"
            print(
                "  \(Display.safe(candidate.label)): \(mark), \(Display.safe(candidate.reason, limit: 300))"
            )
        }
    }
}

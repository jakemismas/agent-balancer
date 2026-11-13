import ArgumentParser
import Core
import Foundation

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check that a folder account still shares its settings and is signed in.",
        discussion:
            "It checks every link and target, the hooks recorded when you linked, and the login. Without --no-reading it also needs a fresh reading. It prints no settings content."
    )

    @Argument(help: "The label of a folder account.") var label: String

    @Flag(name: .customLong("no-reading"), help: "Skip the check that a reading is fresh enough.")
    var noReading = false

    func run() throws {
        let context = ToolContext.current()
        let config = try ConfigStore(context: context).loadRequired()
        guard ConfigValidator.isValidLabel(label), let account = config.account(label),
            account.kind == Kind.folder
        else {
            throw ToolError("No folder account is labelled '\(Display.safe(label, limit: 32))'.")
        }
        let hooks = HookRecord(context: context)
        let state = hooks.currentState()
        let now = Date()
        let outcome = Verifier.failures(
            context: context, account: account, runner: ClaudeRunner(context: context),
            settingsIssue: state.issue, now: now, stopAtFirst: false)

        var failed = !outcome.failures.isEmpty
        for failure in outcome.failures {
            print(Shared.line(Issue(failure.code, .error, failure.text)))
        }
        if !noReading {
            let reading = try? ReadingStore(context: context).load(label: label)
            let limit = config.picker.maxReadingAgeMinutes
            if let reading, reading.isFresh(now: now, maxAgeMinutes: limit) {
                print("reading: fresh")
            } else {
                failed = true
                print(
                    reading == nil
                        ? "Error stale: no reading yet. Run `agent-balancer refresh --label \(label)`."
                        : "Error stale: the reading is older than \(limit) minutes. Run `agent-balancer refresh --label \(label)`."
                )
            }
        }
        if !failed { print("verify \(Display.safe(label, limit: 32)): passed") }

        var observations = StatusObservations(
            settings: SettingsObservation(issue: state.kind, carriesKey: state.carriesKey))
        if let check = outcome.check { observations.auth[label] = AuthObservation(check) }
        Shared.rebuildStatus(context, observations: observations)
        if failed { throw ExitCode.failure }
    }
}

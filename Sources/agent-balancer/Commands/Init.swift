import ArgumentParser
import Core
import Foundation

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Register the default folder's login as an account and record its hooks.")

    @Option(name: .long, help: "The label for the account. Required when input is not a terminal.")
    var label: String?

    func run() throws {
        let context = ToolContext.current()
        let store = ConfigStore(context: context)
        let existing = try store.load()
        let hadConfig = existing != nil
        var config = existing ?? Config()
        if config.loginAccount != nil {
            throw ToolError("Already set up. Run `agent-balancer doctor` to check it.")
        }

        let runner = ClaudeRunner(context: context)
        let status: AuthStatus
        switch AuthStatusReader.read(runner: runner) {
        case .failed(let issue): throw ToolError(issue.text, code: issue.code)
        case .status(let s): status = s
        }
        guard status.loggedIn else {
            throw ToolError(
                "The default folder is not logged in. Run `claude`, sign in, then run init again.",
                code: .loginRejected)
        }

        let chosen = try resolveLabel()
        guard ConfigValidator.isValidLabel(chosen) else {
            throw ToolError(
                "Label '\(Display.safe(chosen))' is not valid. Use 1 to 32 lowercase letters, digits or hyphens, starting with a letter or digit."
            )
        }
        if config.account(chosen) != nil {
            throw ToolError("Label '\(Display.safe(chosen))' is already used.")
        }

        let hooks = HookRecord(context: context)
        let facts = try hooks.readSettings()

        config.accounts.append(
            Account(
                label: chosen, kind: Kind.login, role: Role.pool, email: status.email,
                expectedPlanTier: status.planTier))
        if !hadConfig { config.probe.safeMode = true }
        try store.save(config, backup: hadConfig)
        try hooks.record(facts)

        print("Registered '\(Display.safe(chosen))' as a login account in the pool.")
        print("Recorded \(facts.hooks.count) hook entries from the default folder.")
        if facts.carriesKey {
            print(Shared.line(Issue(.keyInSettings, .warning, Messages.keyInSettings)))
        }
    }

    private func resolveLabel() throws -> String {
        if let label { return label }
        guard isatty(STDIN_FILENO) != 0 else {
            throw ToolError("--label is required when input is not a terminal.")
        }
        guard let typed = Shared.ask("Label for this account: "), !typed.isEmpty else {
            throw ToolError("A label is required.")
        }
        return typed
    }
}

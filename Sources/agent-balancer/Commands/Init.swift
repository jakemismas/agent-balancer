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
        let existing = try ConfigStore(context: context).load()
        if existing?.loginAccount != nil {
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
        if existing?.account(chosen) != nil {
            throw ToolError("Label '\(Display.safe(chosen))' is already used.")
        }

        let hooks = HookRecord(context: context)
        let facts = try hooks.readSettings()

        let registered = Account(
            label: chosen, kind: Kind.login, role: Role.pool, email: status.email,
            expectedPlanTier: status.planTier)
        // Checked again and saved under the pick lock, so an `add` or `config set` that saves at
        // the same moment is kept.
        try TokenAccounts.setUpConfig(context: context) { current in
            var config = current ?? Config()
            if config.loginAccount != nil {
                throw ToolError("Already set up. Run `agent-balancer doctor` to check it.")
            }
            if config.account(chosen) != nil {
                throw ToolError("Label '\(Display.safe(chosen))' is already used.")
            }
            config.accounts.append(registered)
            if current == nil { config.probe.safeMode = true }
            return config
        }
        try hooks.record(facts)
        var observations = StatusObservations()
        observations.settings = SettingsObservation(issue: nil, carriesKey: facts.carriesKey)
        // Bound to the email it read, so an email changed before the rebuild gets no plan from it.
        observations.auth[chosen] = AuthObservation(
            error: nil, planTier: status.planTier, loginExpiresAt: status.loginExpiresAt,
            signedIn: true, emailDigest: registered.emailDigest)
        Shared.rebuildStatus(context, observations: observations)

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

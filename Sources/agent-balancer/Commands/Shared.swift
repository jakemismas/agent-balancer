import Core
import Foundation

enum Shared {
    /// Records the plan of an account that has none yet, from a check that placed its expected
    /// sign-in. A plan already recorded is never changed, and a check made for another email or
    /// account (`AccountCheck.emailDigest`) records nothing.
    static func recordExpectedTiers(
        context: ToolContext, tiers: [String: (tier: String, emailDigest: String?)]
    ) throws {
        guard !tiers.isEmpty else { return }
        try TokenAccounts.updateConfig(context: context) { config in
            for (label, found) in tiers {
                if let index = config.accounts.firstIndex(where: { $0.label == label }),
                    config.accounts[index].expectedPlanTier == nil,
                    found.emailDigest == config.accounts[index].emailDigest
                {
                    config.accounts[index].expectedPlanTier = found.tier
                }
            }
        }
    }

    /// Consent commands refuse in a chat shell. The message never suggests unsetting a variable.
    static func requireOwnTerminal(_ context: ToolContext) throws {
        if context.inChatShell { throw ToolError(Messages.chatShellRefusal) }
    }

    /// Applying a change needs a person at a terminal to type the answer back.
    static func requireTerminal(
        isTerminal: @Sendable () -> Bool = ConsentTerminal.standardInputIsTerminal
    ) throws {
        try ConsentTerminal.require(isTerminal: isTerminal)
    }

    static func line(_ issue: Issue) -> String {
        let tag = issue.severity == .error ? "Error" : "Warning"
        // Paths and labels only, so the longest folder text, at a 32-character label, prints whole.
        return "\(tag) \(issue.code.rawValue): \(Display.safe(issue.text, limit: 1200))"
    }

    /// Prompts on the terminal and returns the typed line, or nil at end of input.
    static func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }

    /// Ends a command that wrote under the data folder: rebuilds `state/status.json`. A failure is
    /// logged and never changes the command's output or exit code.
    static func rebuildStatus(
        _ context: ToolContext, observations: StatusObservations = StatusObservations()
    ) {
        StatusBuilder.rebuildQuietly(context: context, observations: observations)
    }
}

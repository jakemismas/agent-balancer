import ArgumentParser
import Core
import Foundation

struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add an account to the pool. It writes the registry entry and nothing else.",
        discussion: "A token account gets its token from `agent-balancer login <label>`.")

    @Argument(help: "The label for the account: lowercase letters, digits and hyphens.")
    var label: String

    @Option(name: .long, help: "The account kind. Only token is available in this version.")
    var kind: String = Kind.token

    @Option(name: .long, help: "A note for you: the email of the account. It is never checked.")
    var email: String?

    @Option(name: .long, help: "The last day of the account, like 2026-12-31.")
    var ends: String?

    @Flag(name: .customLong("ending-soon"), help: "Spend this account first.")
    var endingSoon = false

    func run() throws {
        let context = ToolContext.current()
        // Checked and saved under the pick lock, so a concurrent remove cannot drop this entry.
        try TokenAccounts.updateConfig(context: context, backup: true) { config in
            guard ConfigValidator.isValidLabel(label) else {
                throw ToolError(
                    "Label '\(Display.safe(label))' is not valid. Use 1 to 32 lowercase letters, digits or hyphens, starting with a letter or digit."
                )
            }
            guard config.account(label) == nil else {
                throw ToolError("Label '\(Display.safe(label))' is already used.")
            }
            guard kind == Kind.token else {
                throw ToolError(
                    kind == Kind.login
                        ? "A login account comes from `agent-balancer init`."
                        : "Only the token kind is available in this version.")
            }
            // A token file left by an earlier account of this label is never taken over.
            if try TokenPaths.facts(context: context, label: label).exists {
                throw ToolError(
                    "A token file from an earlier account '\(Display.safe(label))' is still saved. Run `agent-balancer remove \(label)` in Terminal first, then add it again."
                )
            }
            if let email, !email.contains("@") || email.contains(" ") {
                throw ToolError("That is not an email address.")
            }
            if let ends, !ConfigValidator.isTodayOrLater(ends) {
                throw ToolError("ends must be today or a later date, like 2026-12-31.")
            }
            config.accounts.append(
                Account(
                    label: label, kind: Kind.token, role: Role.pool, email: email, endsAt: ends,
                    endingSoon: endingSoon ? true : nil))
        }
        print("Added '\(Display.safe(label))' as a token account in the pool.")
        print("Next, run `agent-balancer login \(label)` in Terminal to sign it in.")
        Shared.rebuildStatus(context)
    }
}

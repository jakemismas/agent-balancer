import ArgumentParser
import Core
import Foundation

struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add an account to the pool. It writes the registry entry and nothing else.",
        discussion:
            "A token account gets its token from `agent-balancer login <label>`. A folder account (--kind folder) gets its own config folder, which you link and sign in to yourself."
    )

    @Argument(help: "The label for the account: lowercase letters, digits and hyphens.")
    var label: String

    @Option(name: .long, help: "The account kind: token (the default) or folder.")
    var kind: String = Kind.token

    @Option(name: .long, help: "A note for you: the email of the account. It is never checked.")
    var email: String?

    @Option(name: .long, help: "The last day of the account, like 2026-12-31.")
    var ends: String?

    @Flag(
        name: .customLong("ending-soon"),
        help: "Spend this account first. Use it or --ends, not both.")
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
            guard kind == Kind.token || kind == Kind.folder else {
                throw ToolError(
                    kind == Kind.login
                        ? "A login account comes from `agent-balancer init`."
                        : "The kind must be token or folder.")
            }
            // A token file left by an earlier account of this label is never taken over.
            if try TokenPaths.facts(context: context, label: label).exists {
                throw ToolError(
                    "A token file from an earlier account '\(Display.safe(label))' is still saved. Run `agent-balancer remove \(label)` in Terminal first, then add it again."
                )
            }
            if kind == Kind.folder {
                // The path rules of section 5.2 are checked before anything is created.
                _ = try FolderPaths.configDir(context: context, label: label)
                if FolderPaths.state(context: context, label: label) == .refused {
                    throw ToolError(
                        "The folder for '\(Display.safe(label))' exists and is a link or is not owned by you."
                    )
                }
            }
            if let email, !email.contains("@") || email.contains(" ") {
                throw ToolError("That is not an email address.")
            }
            if let ends, !ConfigValidator.isTodayOrLater(ends) {
                throw ToolError("ends must be today or a later date, like 2026-12-31.")
            }
            if ends != nil, endingSoon {
                throw ToolError(
                    "Use --ends or --ending-soon, not both: an account keeps one end marker.")
            }
            if kind == Kind.folder {
                // An empty folder, private to you. An older one with this name is kept as it is.
                try NoFollowWriter(root: context.dataRoot).prepare(
                    folders: FolderPaths.folders(label: label))
            }
            config.accounts.append(
                Account(
                    label: label, kind: kind, role: Role.pool, email: email, endsAt: ends,
                    endingSoon: endingSoon ? true : nil))
        }
        if kind == Kind.folder {
            let dir = try FolderPaths.configDir(context: context, label: label)
            print("Added '\(Display.safe(label))' as a folder account in the pool.")
            print("Its folder is \(context.display(dir)). Next:")
            print("  1. agent-balancer link \(label)")
            print("  2. agent-balancer login \(label)")
            print("  3. \(Messages.trustStep)")
            print("Note: \(Messages.notCarriedOver)")
            print(Messages.oneAccountPerFolder)
        } else {
            print("Added '\(Display.safe(label))' as a token account in the pool.")
            print("Next, run `agent-balancer login \(label)` in Terminal to sign it in.")
        }
        Shared.rebuildStatus(context)
    }
}

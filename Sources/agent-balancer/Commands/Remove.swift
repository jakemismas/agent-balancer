import ArgumentParser
import Core
import Foundation

struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an account and the files the tool made for it.")

    @Argument(help: "The label of the account.") var label: String

    func run() throws {
        let context = ToolContext.current()
        try Shared.requireOwnTerminal(context)
        let config = try ConfigStore(context: context).loadRequired()
        let index = config.accounts.firstIndex(where: { $0.label == label })
        // With no registry entry, a rerun still finishes a remove that stopped part way.
        let leftovers =
            try index == nil && ConfigValidator.isValidLabel(label)
            && TokenAccounts.hasLeftovers(context: context, label: label)
        guard index != nil || leftovers else {
            throw ToolError("No account is labelled '\(Display.safe(label))'.")
        }
        let kind = index.map { config.accounts[$0].kind }
        let removed = try TokenAccounts.removeAccount(
            context: context, label: label, config: config)
        if index != nil {
            print("Removed '\(Display.safe(label))'.")
        } else {
            print("Removed what was left of '\(Display.safe(label))'.")
        }
        if removed.launchFiles > 0 {
            print("Deleted \(removed.launchFiles) launch files.")
        }
        if removed.launchFilesKept > 0 {
            print(
                "Kept \(removed.launchFilesKept) launch files that a session still names or a recent pick returned. They hold no token and go once nothing needs them."
            )
        }
        if removed.launchEntriesSkipped > 0 {
            print(
                "Left \(removed.launchEntriesSkipped) entries among the launch files alone: the tool did not make them."
            )
        }
        if removed.temporariesLeft > 0 {
            print(
                "Left \(removed.temporariesLeft) temporary entries alone: they could not be deleted or the tool did not make them."
            )
        }
        if removed.tokenFile {
            print("Deleted the token file.")
        }
        if kind == Kind.token || removed.tokenFile {
            print(
                "The token itself may keep working until its year ends, because no way to cancel one is documented."
            )
        }
        Shared.rebuildStatus(context)
    }
}

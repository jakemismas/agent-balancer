import ArgumentParser
import Core
import Foundation

struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an account and the files the tool made for it.")

    @Argument(help: "The label of the account.") var label: String

    func run() throws {
        let context = try ToolContext.current()
        try Shared.requireOwnTerminal(context)
        let config = try ConfigStore(context: context).loadRequired()
        let index = config.accounts.firstIndex(where: { $0.label == label })
        if let index { try Self.requireConsent(config.accounts[index]) }
        // With no registry entry, a rerun still finishes a remove that stopped part way.
        let leftovers =
            try index == nil && ConfigValidator.isValidLabel(label)
            && TokenAccounts.hasLeftovers(context: context, label: label)
        guard index != nil || leftovers else {
            throw ToolError("No account is labelled '\(Display.safe(label))'.")
        }
        let kind = index.map { config.accounts[$0].kind }
        let key = index.map { config.accounts[$0].accountKey }
        var forgot = false
        let removed: TokenAccounts.Removed
        do {
            removed = try TokenAccounts.removeAccount(
                context: context, label: label, config: config,
                keepsRecentPicks: kind != Kind.folder
            ) { fresh in
                // Again under the pick lock, which every registry writer takes, before anything
                // is written.
                let account = fresh?.account(label)
                if let account { try Self.requireConsent(account) }
                // Only another account under the label stops it; a gone entry finishes as
                // leftovers.
                if let account, account.accountKey != key {
                    throw ToolError(
                        "'\(Display.safe(label))' changed while remove waited, so nothing was changed. Run `agent-balancer remove \(Display.safe(label))` again."
                    )
                }
                if kind == Kind.folder {
                    // Forgotten first: a stop part way leaves a folder that counts as not linked,
                    // which fails closed, never one that looks linked after it is added again.
                    let had = try HookRecord(context: context).saveLinks(
                        label: label, entries: [], linked: false)
                    forgot = had.linked || !had.entries.isEmpty
                }
            }
        } catch let error where forgot {
            // A later stop keeps the account, so it says how to record those links again.
            throw ToolError.adding(Self.linksForgottenText(label), to: error)
        }
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
        if kind == Kind.folder {
            let folder = try FolderPaths.configDir(context: context, label: label)
            print(
                "The folder \(context.display(folder)) stays, with its login and the links in it. To delete it, delete that folder yourself. To take the links out first, run `agent-balancer unlink \(label)` before you remove the account."
            )
        }
        if kind == Kind.token || removed.tokenFile {
            print(
                "The token itself may keep working until its year ends, because no way to cancel one is documented."
            )
        }
        Shared.rebuildStatus(context)
    }

    /// What a stop of `remove` adds once it forgot a folder account's links: the account it kept
    /// counts as not linked until `link` records them again.
    static func linksForgottenText(_ label: String) -> String {
        "The links of '\(Display.safe(label))' were forgotten, so the account counts as not linked until `agent-balancer link \(Display.safe(label))` records them again."
    }

    /// Removing the main account takes its reserve away, so it keeps its typed consent: only a
    /// person at a terminal may do it. A pool account needs no terminal.
    static func requireConsent(_ account: Account) throws {
        guard account.role != Role.pool else { return }
        try ConsentTerminal.require(message: Messages.removeMainNeedsTerminal(account.label))
    }
}

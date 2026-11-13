import ArgumentParser
import Core
import Foundation

struct UnlinkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlink",
        abstract: "Remove the links the tool made in a folder account.",
        discussion:
            "A path goes only while it is still a symlink with the recorded target. A file or folder stays. The account then counts as not linked."
    )

    @Argument(help: "The label of a folder account.") var label: String

    func run() throws {
        let context = ToolContext.current()
        try Shared.requireOwnTerminal(context)
        try Shared.requireTerminal()
        let config = try ConfigStore(context: context).loadRequired()
        guard ConfigValidator.isValidLabel(label), let account = config.account(label),
            account.kind == Kind.folder
        else {
            throw ToolError("No folder account is labelled '\(Display.safe(label, limit: 32))'.")
        }
        let hooks = HookRecord(context: context)
        let shown = hooks.linkState(for: label)
        let listed = shown.entries
        print("Links listed for '\(Display.safe(label, limit: 32))': \(listed.count)")
        for entry in listed {
            let name = Display.safe(
                URL(fileURLWithPath: entry.path).lastPathComponent, limit: 64)
            print(
                "  \(name): \(hooks.isIntact(entry) ? "a link made by this tool" : "not the recorded link, it stays")"
            )
        }
        guard Shared.ask("Type the label (\(label)) to remove them: ") == label else {
            throw ToolError("Not confirmed. Nothing was changed.")
        }
        let result = try Linker.removeLinks(context: context, label: label, expecting: shown)
        print(
            "Removed \(result.removed) links. Left \(result.kept) paths that are not the recorded link."
        )
        print("The account now counts as not linked.")
        Shared.rebuildStatus(context)
    }
}

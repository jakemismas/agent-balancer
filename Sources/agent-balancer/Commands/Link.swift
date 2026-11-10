import ArgumentParser
import Core
import Foundation

struct LinkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link", abstract: "Accept a changed hook set for the default folder.")

    @Flag(name: .customLong("accept-source-change"), help: "Re-record the default folder's hooks.")
    var acceptSourceChange = false

    @Argument(help: "Not used until folder accounts arrive.")
    var label: String?

    func run() throws {
        let context = ToolContext.current()
        try Shared.requireOwnTerminal(context)
        guard acceptSourceChange else {
            throw ToolError("Only `link --accept-source-change` is available in this version.")
        }
        if label != nil {
            throw ToolError("Folder accounts are not available yet. Run it with no label.")
        }
        _ = try ConfigStore(context: context).loadRequired()

        let hooks = HookRecord(context: context)
        let facts = try hooks.readSettings()
        let diff = hooks.diff(current: facts)
        if let diff {
            print("Hook entries added: \(diff.added.count)")
            for entry in diff.added { print("  + \(entry.summary)") }
            print("Hook entries removed: \(diff.removed.count)")
            for entry in diff.removed { print("  - \(entry.summary)") }
        } else {
            print("No hook record exists. Current hook entries: \(facts.hooks.count)")
            for entry in facts.hooks { print("  + \(entry.summary)") }
        }
        print("disableAllHooks: \(facts.disableAllHooks ? "present" : "not present")")
        if let diff, diff.isEmpty {
            print("Nothing to accept: the hooks match the record.")
            return
        }
        guard Shared.ask("Type accept to record these hooks: ") == "accept" else {
            throw ToolError("Not accepted. The record is unchanged.")
        }
        try hooks.record(facts)
        print("Recorded \(facts.hooks.count) hook entries.")
    }
}

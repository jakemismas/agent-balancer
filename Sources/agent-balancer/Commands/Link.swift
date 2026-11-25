import ArgumentParser
import Core
import Foundation

struct LinkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Share settings with a folder account, or accept a changed hook set.",
        discussion:
            "`link <label>` lists every link first and makes them only after you type the label back. `link --accept-source-change` re-records the default folder's hooks."
    )

    @Flag(
        name: .customLong("accept-source-change"),
        help: "Re-record the hooks of the default folder, which every account shares.")
    var acceptSourceChange = false

    @Flag(name: .long, help: "With --accept-source-change: cover every linked folder account.")
    var all = false

    @Flag(name: .long, help: "Make a broken or changed link right again.")
    var repair = false

    @Flag(name: .customLong("dry-run"), help: "Print what would change and ask for nothing.")
    var dryRun = false

    @Argument(help: "The label of a folder account.")
    var label: String?

    func run() throws {
        let context = try ToolContext.current()
        try Shared.requireOwnTerminal(context)
        if acceptSourceChange {
            guard !repair else {
                throw ToolError("--repair does not go with --accept-source-change.")
            }
            try acceptHooks(context)
            return
        }
        guard !all else { throw ToolError("--all goes with --accept-source-change.") }
        guard let label else {
            throw ToolError("Name a folder account: `agent-balancer link <label>`.")
        }
        try linkFolder(context, label: label)
    }

    // MARK: Folder links

    private func linkFolder(_ context: ToolContext, label: String) throws {
        let config = try ConfigStore(context: context).loadRequired()
        let plan = try Linker.plan(context: context, config: config, label: label, repair: repair)
        print("Account folder: \(context.display(plan.folder))")
        for item in plan.items {
            let target = item.target.map { context.display(URL(fileURLWithPath: $0)) } ?? "-"
            let resolved =
                item.sourceIsLink ? " (the source is a link, resolved to its real target)" : ""
            print(
                "  \(item.name): \(Self.describe(item.action)); target \(target)\(resolved); now: \(item.destination)"
            )
        }
        let conflicts = plan.conflicts
        if !conflicts.isEmpty {
            for text in conflicts { print("Refused: \(Display.safe(text, limit: 300))") }
            throw ToolError("Nothing was changed.")
        }
        guard plan.changesAnything || !HookRecord(context: context).isLinked(label) else {
            print("Nothing to change: every link is in place.")
            return
        }

        // The verdict a reader saved is used, so this command never opens the default folder's
        // settings. A missing or stale verdict sends the person to a command that reads them.
        let seen = plan.verdict
        if let issue = seen.issue {
            switch issue {
            case Messages.settingsChanged:
                throw ToolError(
                    "The hooks of the default folder changed since they were recorded. Run `agent-balancer link --accept-source-change --all` first."
                )
            case Messages.hookRecordMissing:
                throw ToolError(
                    "No hook record exists for the default folder. Run `agent-balancer link --accept-source-change` first, so the hooks are recorded after you review them."
                )
            default:
                throw ToolError(Messages.settingsNotChecked)
            }
        }
        if dryRun {
            print("Dry run: nothing was changed.")
            return
        }
        try Shared.requireTerminal()
        guard Shared.ask("Type the label (\(label)) to make these changes: ") == label else {
            throw ToolError("Not confirmed. Nothing was changed.")
        }
        let applied = try Linker.apply(context: context, plan: plan)
        print(
            "Linked '\(Display.safe(label, limit: 32))': \(applied.created) made, \(applied.replaced) replaced, \(applied.dropped) removed, \(applied.present) already in place, \(applied.skipped) skipped."
        )
        var observations = StatusObservations(
            settings: SettingsObservation(issue: nil, carriesKey: seen.carriesKey))
        // The folder's sign-in is checked as `status` checks it, so the window reads what the
        // folder holds before it offers Sign in.
        if let account = try? ConfigStore(context: context).loadRequired().account(label),
            account.kind == Kind.folder, let handler = AccountKinds.handler(for: account.kind)
        {
            let check = handler.check(
                account: account, runner: ClaudeRunner(context: context), now: Date())
            observations.auth[label] = AuthObservation(check)
        }
        Shared.rebuildStatus(context, observations: observations)
    }

    private static func describe(_ action: LinkPlan.Action) -> String {
        switch action {
        case .create: return "make the link"
        case .present: return "already linked"
        case .replace: return "replace the link"
        case .drop: return "remove the link, its source is gone"
        case .skipMissing: return "skipped, no source exists"
        case .conflict(let text): return "refused, \(Display.safe(text, limit: 200))"
        }
    }

    // MARK: Hook record

    private func acceptHooks(_ context: ToolContext) throws {
        let config = try ConfigStore(context: context).loadRequired()
        let folders = config.accounts.filter { $0.kind == Kind.folder }
        let hooks = HookRecord(context: context)
        if let label {
            guard let account = config.account(label), account.kind == Kind.folder,
                hooks.isLinked(label)
            else {
                throw ToolError(
                    "'\(Display.safe(label, limit: 32))' is not a linked folder account. With no label, the default folder's record is accepted."
                )
            }
        }
        let facts = try hooks.readSettings()
        let seenRecord = hooks.snapshot()
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
        if !facts.hooksOffEnvNames.isEmpty {
            let names = facts.hooksOffEnvNames.map { Display.safe($0, limit: 64) }
            print("env names that switch hooks off: \(names.joined(separator: ", "))")
        }
        let covered = folders.filter { hooks.isLinked($0.label) && hooks.sharesSettings($0.label) }
        if all || label != nil {
            let names = covered.map { Display.safe($0.label, limit: 32) }
            print(
                "Linked folder accounts that share this record: \(names.isEmpty ? "none" : names.joined(separator: ", "))"
            )
        }
        if let diff, diff.isEmpty {
            print("Nothing to accept: the hooks match the record.")
            return
        }
        if dryRun {
            print("Dry run: nothing was changed.")
            return
        }
        try Shared.requireTerminal()
        guard Shared.ask("Type accept to record these hooks: ") == "accept" else {
            throw ToolError("Not accepted. The record is unchanged.")
        }
        // What is recorded must still be what the person was shown.
        guard try hooks.readSettings() == facts else {
            throw ToolError(
                "The default folder's settings changed after you were shown them, so nothing was recorded. Run `agent-balancer link --accept-source-change` again."
            )
        }
        try hooks.record(facts, ifRecordIs: seenRecord)
        print("Recorded \(facts.hooks.count) hook entries.")
        Shared.rebuildStatus(
            context,
            observations: StatusObservations(
                settings: SettingsObservation(issue: nil, carriesKey: facts.carriesKey)))
    }
}

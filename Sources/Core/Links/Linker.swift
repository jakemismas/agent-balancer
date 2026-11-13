import Foundation

/// What `link` would do for one folder account, worked out without changing anything.
public struct LinkPlan: Sendable {
    public enum Action: Equatable, Sendable {
        /// Make the link.
        case create
        /// Already the exact intended link.
        case present
        /// A link the tool made points at an older target: remove it and make the new one.
        case replace
        /// The source is gone and its recorded link is still ours: remove it.
        case drop
        /// The source does not exist and nothing is recorded: skipped with a note.
        case skipMissing
        /// Something stands in the way. The whole run is refused.
        case conflict(String)
    }

    public struct Item: Sendable {
        public var name: String
        public var isFolder: Bool
        /// The resolved real target, or nil when the source is missing or refused.
        public var target: String?
        /// Whether the source is itself a link that was resolved, for the dry run.
        public var sourceIsLink: Bool
        public var action: Action
        /// What `lstat` shows at the destination now, in words.
        public var destination: String
    }

    public var label: String
    public var folder: URL
    public var items: [Item]
    /// The record of this account the plan was built from. `apply` writes only while it still holds.
    public var state: HookRecord.LinkState

    public var conflicts: [String] {
        items.compactMap { item in
            if case .conflict(let text) = item.action { return "\(item.name): \(text)" }
            return nil
        }
    }

    /// True when applying would change the folder or the manifest.
    public var changesAnything: Bool {
        items.contains { $0.action != .present && $0.action != .skipMissing }
    }
}

/// `link`, `unlink` and `link --repair` for folder accounts (docs/ARCHITECTURE.md sections 5.1 and
/// 5.7). Every link is a one-hop symlink made through the no-follow writer, and a link is removed
/// only while it is still a symlink with the recorded target.
public enum Linker {
    public static func plan(context: ToolContext, config: Config, label: String, repair: Bool)
        throws -> LinkPlan
    {
        guard ConfigValidator.isValidLabel(label), let account = config.account(label) else {
            throw ToolError("No account is labelled '\(Display.safe(label, limit: 32))'.")
        }
        guard account.kind == Kind.folder else {
            throw ToolError("'\(Display.safe(label, limit: 32))' is not a folder account.")
        }
        let folder = try FolderPaths.configDir(context: context, label: label)
        switch FolderPaths.state(context: context, label: label) {
        case .ready: break
        case .missing:
            throw ToolError(
                "The folder of '\(Display.safe(label, limit: 32))' is missing. Run `agent-balancer remove \(label)`, then add it again."
            )
        case .refused:
            throw ToolError(
                "The folder of '\(Display.safe(label, limit: 32))' is a link, or is not owned by you."
            )
        }
        let source = try HookRecord.sharedSource(config: config, context: context)
        let writer = NoFollowWriter(root: context.dataRoot)
        let hooks = HookRecord(context: context)
        let state = hooks.linkState(for: label)
        let recorded = state.entries
        let folders = FolderPaths.folders(label: label)
        let again = "agent-balancer link\(repair ? " --repair" : "") \(label)"

        var items: [LinkPlan.Item] = []
        for shared in SharedItems.all {
            let sourceURL = source.appendingPathComponent(shared.name)
            var item = LinkPlan.Item(
                name: shared.name, isFolder: shared.isFolder, target: nil, sourceIsLink: false,
                action: .skipMissing, destination: "absent")
            let entry = recorded.first {
                URL(fileURLWithPath: $0.path).lastPathComponent == shared.name
            }

            var sourceStatus = stat()
            let sourceExists = lstat(sourceURL.path, &sourceStatus) == 0
            var resolvedTarget: String?
            if sourceExists {
                item.sourceIsLink = (sourceStatus.st_mode & S_IFMT) == S_IFLNK
                let resolution = Self.resolve(sourceURL, isFolder: shared.isFolder)
                resolvedTarget = resolution.target
                if resolution.target == nil {
                    item.action = .conflict(
                        resolution.problem
                            + " Fix \(context.display(sourceURL)) in the default folder, then run `\(again)` again."
                    )
                }
            }
            item.target = resolvedTarget

            // The destination as it is now.
            var destinationNote = "absent"
            var intact = false
            var recordedIntact = false
            if let target = resolvedTarget {
                intact = try writer.hasLink(folders: folders, name: shared.name, target: target)
            }
            if let entry {
                recordedIntact = try writer.hasLink(
                    folders: folders, name: shared.name, target: entry.target)
            }
            if let info = try writer.info(folders: folders, name: shared.name) {
                destinationNote =
                    intact || recordedIntact
                    ? "a link made by this tool"
                    : (info.isRegularFile
                        ? "a file that is not a link" : "something that is not the intended link")
            }
            item.destination = destinationNote

            if case .conflict = item.action {
                items.append(item)
                continue
            }
            if !sourceExists {
                if repair, recordedIntact {
                    item.action = .drop
                } else {
                    item.action = .skipMissing
                }
            } else if intact {
                item.action = .present
            } else if destinationNote == "absent" {
                item.action = .create
            } else if repair, recordedIntact {
                item.action = .replace
            } else if recordedIntact {
                item.action = .conflict(
                    "the link points to an older target. Run `agent-balancer link --repair \(label)`."
                )
            } else {
                item.action = .conflict(
                    "the destination exists and is not the intended link. Move or remove \(context.display(folder.appendingPathComponent(shared.name))) in the account folder, then run `\(again)` again."
                )
            }
            items.append(item)
        }
        return LinkPlan(label: label, folder: folder, items: items, state: state)
    }

    /// The final target of a source that may itself be a link. It must be a regular file or a
    /// folder, as the item says, owned by the user.
    static func resolve(_ url: URL, isFolder: Bool) -> (target: String?, problem: String) {
        guard let real = realpath(url.path, nil) else {
            return (nil, "the source is a link that goes nowhere.")
        }
        defer { free(real) }
        let path = String(cString: real)
        var st = stat()
        guard stat(path, &st) == 0 else { return (nil, "the source cannot be read.") }
        let kind = st.st_mode & S_IFMT
        guard isFolder ? kind == S_IFDIR : kind == S_IFREG else {
            return (
                nil, isFolder ? "the source is not a folder." : "the source is not a regular file."
            )
        }
        guard st.st_uid == getuid() else { return (nil, "the source is not owned by you.") }
        guard FolderPaths.isLinkTargetText(path) else {
            return (nil, "the source path has a character the tool will not record.")
        }
        return (path, "")
    }

    public struct Applied: Equatable, Sendable {
        public var created = 0
        public var replaced = 0
        public var dropped = 0
        public var present = 0
        public var skipped = 0
    }

    /// Makes the planned changes and writes the folder's manifest entries. A plan with a conflict
    /// is refused before anything changes, and so is a plan whose record of this account changed
    /// since it was built (the typed approval was for that plan). The links lock is held from that
    /// check to the save. If a link fails part way, the ones made so far are recorded and the
    /// folder is not marked linked.
    public static func apply(context: ToolContext, plan: LinkPlan) throws -> Applied {
        guard plan.conflicts.isEmpty else {
            throw ToolError("Refused: " + plan.conflicts.joined(separator: " "))
        }
        let writer = NoFollowWriter(root: context.dataRoot)
        let hooks = HookRecord(context: context)
        let folders = FolderPaths.folders(label: plan.label)
        let before = plan.state.entries
        return try hooks.changeLinks(label: plan.label, expecting: plan.state) { save in
            var result = Applied()
            var entries: [LinkEntry] = []

            func entryPath(_ name: String) -> String {
                plan.folder.appendingPathComponent(name).path
            }
            var reached = 0
            do {
                for item in plan.items {
                    reached += 1
                    let old = before.first {
                        URL(fileURLWithPath: $0.path).lastPathComponent == item.name
                    }
                    switch item.action {
                    case .present:
                        result.present += 1
                        if let target = item.target {
                            entries.append(LinkEntry(path: entryPath(item.name), target: target))
                        }
                    case .create:
                        guard let target = item.target else { continue }
                        try writer.makeLink(folders: folders, name: item.name, target: target)
                        entries.append(LinkEntry(path: entryPath(item.name), target: target))
                        result.created += 1
                    case .replace:
                        guard let target = item.target, let old else { continue }
                        _ = hooks.removeLink(old)
                        try writer.makeLink(folders: folders, name: item.name, target: target)
                        entries.append(LinkEntry(path: entryPath(item.name), target: target))
                        result.replaced += 1
                    case .drop:
                        if let old { _ = hooks.removeLink(old) }
                        result.dropped += 1
                    case .skipMissing:
                        result.skipped += 1
                        if let old { entries.append(old) }
                    case .conflict:
                        break
                    }
                }
            } catch {
                // Keep the prior entry of the failed item (if its link still stands) and of every
                // item not yet reached, so their links stay listed for unlink and verify.
                for (index, item) in plan.items.enumerated() where index >= reached - 1 {
                    let old = before.first {
                        URL(fileURLWithPath: $0.path).lastPathComponent == item.name
                    }
                    guard let old else { continue }
                    let stands =
                        (try? writer.hasLink(folders: folders, name: item.name, target: old.target))
                        ?? false
                    if stands { entries.append(old) }
                }
                try? save(entries, false)
                throw error
            }
            try save(entries, true)
            return result
        }
    }

    /// Removes each listed link of one folder account that is still a symlink with the recorded
    /// target, then forgets the account's entries, so it counts as not linked. A path that is a
    /// regular file, a folder or a link elsewhere stays. `expecting` is the record the person was
    /// shown; if it changed since, nothing is removed.
    public static func removeLinks(
        context: ToolContext, label: String, expecting: HookRecord.LinkState
    ) throws -> (removed: Int, kept: Int) {
        guard ConfigValidator.isValidLabel(label) else { throw ToolError("Label is not valid.") }
        let hooks = HookRecord(context: context)
        return try hooks.changeLinks(label: label, expecting: expecting) { save in
            var removed = 0
            var kept = 0
            for entry in expecting.entries {
                if hooks.removeLink(entry) { removed += 1 } else { kept += 1 }
            }
            try save([], false)
            return (removed, kept)
        }
    }
}

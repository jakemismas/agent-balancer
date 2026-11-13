import Foundation

/// `uninstall` (docs/ARCHITECTURE.md section 12): what the tool made, and the removal of it. Every
/// delete goes through the no-follow writer, and the token and launch folders are reached only
/// through `TokenAccounts`. Account folders and logins are never touched except for the links the
/// tool listed.
public enum Uninstall {
    /// The folders of tool data other than tokens, launch files and account folders.
    static let dataFolders = ["state", "logs", "backups", "locks", "probe"]
    static let dataFiles = ["config.json", "links.json"]
    static let accountsFolder = "accounts"

    /// What `uninstall` lists before it asks. Counts only: no name, no path, no content.
    public struct Plan: Equatable, Sendable {
        public var links: Int
        public var linksIntact: Int
        public var hasLinksFile: Bool
        public var tokenFiles: Int
        public var launchFiles: Int
        public var launchFilesNamed: Int
        public var recordsReadable: Bool
        /// Files under `state/`, `state/events.jsonl` and `state/history/` included.
        public var stateFiles: Int
        public var logFiles: Int
        public var backupFiles: Int
        public var hasConfig: Bool

        public var isEmpty: Bool {
            links == 0 && !hasLinksFile && tokenFiles == 0 && launchFiles == 0 && stateFiles == 0
                && logFiles == 0 && backupFiles == 0 && !hasConfig
        }
    }

    /// What the removal did.
    public struct Result: Equatable, Sendable {
        public var linksRemoved = 0
        public var linksKept = 0
        public var tokenFiles = 0
        public var launchFiles = 0
        public var launchFilesKept = 0
        public var otherFiles = 0
        /// Entries the tool did not make, left where they are.
        public var entriesLeft = 0
        public var temporariesLeft = 0
    }

    public static func plan(
        context: ToolContext, leaseMinutes: Int = PickerSettings().leaseMinutes,
        snapshot: SessionsSnapshot? = nil, now: Date = Date()
    ) -> Plan {
        let writer = NoFollowWriter(root: context.dataRoot)
        let hooks = HookRecord(context: context)
        let links = hooks.listedLinks()
        let inventory = TokenAccounts.inventory(
            context: context, leaseMinutes: leaseMinutes, snapshot: snapshot, now: now)
        func present(_ name: String) -> Bool {
            ((try? writer.info(folders: [], name: name)) ?? nil) != nil
        }
        return Plan(
            links: links.count, linksIntact: links.filter(hooks.isIntact).count,
            hasLinksFile: present("links.json"), tokenFiles: inventory.tokenFiles,
            launchFiles: inventory.launchFiles, launchFilesNamed: inventory.launchFilesNamed,
            recordsReadable: inventory.recordsReadable,
            stateFiles: countFiles(writer, ["state"]), logFiles: countFiles(writer, ["logs"]),
            backupFiles: countFiles(writer, ["backups"]), hasConfig: present("config.json"))
    }

    private static func countFiles(_ writer: NoFollowWriter, _ folders: [String], depth: Int = 0)
        -> Int
    {
        guard depth < 6, let names = try? writer.listNames(folders: folders) else { return 0 }
        let sub = Set((try? writer.listFolders(folders: folders)) ?? [])
        return names.reduce(0) {
            $0 + (sub.contains($1) ? countFiles(writer, folders + [$1], depth: depth + 1) : 1)
        }
    }

    /// Removes the tool's own files, in this order: the listed links, the launch and token files
    /// (`TokenAccounts.removeEverything`), then state, logs, backups, locks, probe leftovers, the
    /// link manifest and the config. `accounts/` and anything the tool did not make stay.
    public static func run(
        context: ToolContext, leaseMinutes: Int = PickerSettings().leaseMinutes,
        snapshot: SessionsSnapshot? = nil, now: Date = Date()
    ) throws -> Result {
        var result = Result()
        let writer = NoFollowWriter(root: context.dataRoot)

        let links = HookRecord(context: context).removeListedLinks()
        result.linksRemoved = links.removed
        result.linksKept = links.kept
        // The file may stay (a path that is not a regular file of the user's); it must not claim a link.
        try? HookRecord(context: context).forgetAllLinks()

        let wiped = try TokenAccounts.removeEverything(
            context: context, leaseMinutes: leaseMinutes, snapshot: snapshot, now: now)
        result.tokenFiles = wiped.tokenFiles
        result.launchFiles = wiped.launchFiles
        result.launchFilesKept = wiped.launchFilesKept
        result.entriesLeft += wiped.entriesSkipped
        result.temporariesLeft = wiped.temporariesLeft

        for folder in dataFolders {
            let removed = try removeTree(writer, [folder], depth: 0)
            result.otherFiles += removed.files
            result.entriesLeft += removed.left
            try writer.removeEmptyFolder(parent: [], name: folder)
        }
        for name in dataFiles where try writer.removeOwnRegularFile(folders: [], name: name) {
            result.otherFiles += 1
        }
        return result
    }

    /// Deletes the regular files the user owns under `folders`, then each folder that ends up
    /// empty. A link or any other entry is counted and left alone.
    private static func removeTree(_ writer: NoFollowWriter, _ folders: [String], depth: Int) throws
        -> (files: Int, left: Int)
    {
        var files = 0
        var left = 0
        guard depth < 6 else { return (0, 1) }
        let sub = Set(try writer.listFolders(folders: folders))
        for name in try writer.listNames(folders: folders) {
            if sub.contains(name) {
                let inner = try removeTree(writer, folders + [name], depth: depth + 1)
                files += inner.files
                left += inner.left
                try writer.removeEmptyFolder(parent: folders, name: name)
            } else if try writer.removeOwnRegularFile(folders: folders, name: name) {
                files += 1
            } else {
                left += 1
            }
        }
        return (files, left)
    }
}

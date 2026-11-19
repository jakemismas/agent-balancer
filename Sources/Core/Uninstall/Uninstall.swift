import Foundation

/// `uninstall` (docs/ARCHITECTURE.md section 12): what the tool made, and the removal of it. Every
/// delete goes through the no-follow writer, and the token and launch folders are reached only
/// through `TokenAccounts`. Account folders and logins are never touched except for the links the
/// tool listed.
public enum Uninstall {
    /// The steps of `run`, in the order they happen.
    public enum Step: String, CaseIterable, Sendable {
        case launchFiles, tokenFiles, writerLeftovers, state, logs, backups, probe, links
        case linkRecord, config, locks, dataFolder
    }

    /// What `uninstall` lists before it asks. Counts only: no name, no path, no content.
    public struct Plan: Equatable, Sendable {
        public var links: Int
        public var linksIntact: Int
        public var hasLinksFile: Bool
        public var tokenFiles: Int
        /// The writer's temporary files in the token and launch folders, left by a write that
        /// stopped before its rename, and names of their shape there that cannot be checked. Each
        /// may hold a token.
        public var temporaries: Int
        /// Entries in the token and launch folders named like a token file or a label's launch
        /// folder only in other letter case, such as `Pool-a.json`. On a volume that ignores
        /// case a save writes into such an entry and keeps its spelling, so each may hold a
        /// token. None is opened or deleted.
        public var otherCaseEntries: Int
        /// Entries in the launch folder where a label's folder belongs that are a link, a file or
        /// another user's folder, or that `lstat` cannot check. A launch file with a token may be
        /// behind each, so it may hold one; none is followed or opened.
        public var launchEntriesNotFollowed: Int
        /// How many of `launchEntriesNotFollowed` `lstat` cannot check, such as a label's folder
        /// whose access list denies its owner. The listing gives their count on a line of its own.
        public var launchEntriesUnchecked: Int
        public var launchFiles: Int
        /// Launch files a session record still names; at least this many when `recordsReadable`
        /// is false.
        public var launchFilesNamed: Int
        public var recordsReadable: Bool
        /// False when the lease file is there but cannot be read, so every launch file is kept.
        public var leasesReadable: Bool
        /// The tool's files under `state/`, `state/events.jsonl` and `state/history/` included.
        public var stateFiles: Int
        /// The writer's temporary files under `state/` that a save may still be using
        /// (`mayBeInUse`). They stay until a run finds them a minute old. Not in `stateFiles`.
        public var stateTemporariesInUse: Int
        public var logFiles: Int
        public var backupFiles: Int
        public var probeFiles: Int
        public var lockFiles: Int
        public var hasConfig: Bool
        /// The writer's temporary files directly in the data folder, left by a write of the
        /// config or the link manifest that stopped before its rename. None holds a token.
        public var dataFolderTemporaries: Int
        /// True when the data folder is there with nothing in it.
        public var dataFolderEmpty: Bool

        public var isEmpty: Bool {
            links == 0 && !hasLinksFile && tokenFiles == 0 && temporaries == 0
                && otherCaseEntries == 0 && launchEntriesNotFollowed == 0 && launchFiles == 0
                && stateFiles == 0 && stateTemporariesInUse == 0 && logFiles == 0
                && backupFiles == 0 && probeFiles == 0
                && lockFiles == 0 && !hasConfig && dataFolderTemporaries == 0 && !dataFolderEmpty
        }
    }

    /// What the removal did.
    public struct Result: Equatable, Sendable {
        public var linksRemoved = 0
        public var linksKept = 0
        public var tokenFiles = 0
        /// Token files that could not be deleted. Each still holds its token.
        public var tokenFilesLeft = 0
        public var launchFiles = 0
        public var launchFilesKept = 0
        public var otherFiles = 0
        /// Entries the tool did not make, or could not delete, left where they are.
        public var entriesLeft = 0
        /// The writer's temporary files under `state/` kept because a save may still be using
        /// them. A run deletes each once it is a minute old. They are not in `entriesLeft`.
        public var stateTemporariesKept = 0
        /// The writer's temporary files in the token and launch folders that could not be
        /// deleted. Each may hold a token.
        public var temporariesLeft = 0
        /// Entries named like a token file or a label's launch folder only in other letter case,
        /// left unopened. Each may hold a token. They are not in `entriesLeft`.
        public var otherCaseEntries = 0
        /// Entries in the launch folder where a label's folder belongs that are a link, a file or
        /// another user's folder, or that `lstat` cannot check, never followed. A launch file with
        /// a token may be behind each. They are not in `entriesLeft`.
        public var launchEntriesNotFollowed = 0
        /// How many of `launchEntriesNotFollowed` `lstat` cannot check. The closing text gives
        /// their count on a line of its own.
        public var launchEntriesUnchecked = 0
        /// True when nothing was left in the data folder, so it went too.
        public var dataFolderRemoved = false
    }

    /// What one pass over a folder did: the tool's files it deleted, or with a dry run would
    /// delete, the entries still there that it left, and the temporary files it kept because a
    /// save may still be using them.
    struct Swept: Equatable {
        var files = 0
        var left = 0
        var inUse = 0
    }

    /// What there is to remove, after `requireCheckable`, so a folder that cannot be checked is
    /// refused instead of read as empty.
    public static func plan(
        context: ToolContext, leaseMinutes: Int = PickerSettings().leaseMinutes,
        snapshot: SessionsSnapshot? = nil, now: Date = Date()
    ) throws -> Plan {
        try requireCheckable(context)
        let writer = NoFollowWriter(root: context.dataRoot)
        let hooks = HookRecord(context: context)
        let links = hooks.listedLinks()
        let inventory = TokenAccounts.inventory(
            context: context, leaseMinutes: leaseMinutes, snapshot: snapshot, now: now)
        func present(_ name: String) -> Bool { takeFile(writer, [], name, dryRun: true) }
        func count(_ top: [String]) -> Int { sweep(writer, top, dryRun: true, now: now).files }
        let state = sweep(writer, Layout.stateFolders, dryRun: true, now: now)
        let notFollowed = LaunchFiles.notFollowedEntryCount(context: context)
        return Plan(
            links: links.count, linksIntact: links.filter(hooks.isIntact).count,
            hasLinksFile: present(HookRecord.fileName), tokenFiles: inventory.tokenFiles,
            temporaries: TokenAccounts.temporariesForUninstall(context: context),
            otherCaseEntries: TokenAccounts.otherCaseEntryCount(context: context),
            launchEntriesNotFollowed: notFollowed.all,
            launchEntriesUnchecked: notFollowed.unchecked,
            launchFiles: inventory.launchFiles, launchFilesNamed: inventory.launchFilesNamed,
            recordsReadable: inventory.recordsReadable, leasesReadable: inventory.leasesReadable,
            stateFiles: state.files, stateTemporariesInUse: state.inUse,
            logFiles: count(Layout.logsFolders),
            backupFiles: count(Layout.backupsFolders), probeFiles: count(Layout.probeFolders),
            lockFiles: count(Layout.locksFolders), hasConfig: present(ConfigStore.fileName),
            dataFolderTemporaries: dataFolderTemporaries(writer, dryRun: true).files,
            dataFolderEmpty: writer.rootIsEmpty())
    }

    /// Removes the tool's own files in the order of `Step`: the launch files (deleted, or kept as
    /// tombstones) and a read-back that none holds a token, the token files, the writer's
    /// leftover temporary files, state, logs, backups, probe leftovers, the listed links, the link
    /// record, the config, the locks, and last the data folder when nothing is left in it. It
    /// starts with `requireCheckable`, before it removes anything.
    /// Everything up to the config happens under the pick lock, and the session records and the
    /// config's lease window are read once the lock is held, so a session that started while the
    /// person read the listing keeps its launch file; the lease window is never shorter than
    /// `leaseMinutes`. Only the steps before the token files can stop the run; from then on, what
    /// a step cannot remove is counted and left, a link or a file where a folder belongs included,
    /// and nothing is followed. Inside the folders it empties, only names the tool writes go
    /// (`OwnNames`). `accounts/` and anything the tool did not make stay. `afterStep` runs once
    /// each step is done.
    public static func run(
        context: ToolContext, leaseMinutes: Int = PickerSettings().leaseMinutes,
        snapshot: SessionsSnapshot? = nil, now: Date = Date(),
        afterStep: (Step) throws -> Void = { _ in }
    ) throws -> Result {
        try requireCheckable(context)
        var result = Result()
        let writer = NoFollowWriter(root: context.dataRoot)
        let lock = try TokenAccounts.takeLock(context)
        do {
            let records = snapshot ?? SessionsReader.read(context: context)
            let configured = (try? ConfigStore(context: context).load())?.picker.leaseMinutes
            let launch = try TokenAccounts.clearLaunchFilesForUninstall(
                context: context, leaseMinutes: max(leaseMinutes, configured ?? leaseMinutes),
                snapshot: records, now: now)
            result.launchFiles = launch.deleted
            result.launchFilesKept = launch.kept
            result.entriesLeft += launch.left
            result.otherCaseEntries += launch.otherCase
            result.launchEntriesNotFollowed = launch.notFollowed
            result.launchEntriesUnchecked = launch.unchecked
            try afterStep(.launchFiles)

            let tokens = try TokenAccounts.deleteTokenFilesForUninstall(context: context)
            result.tokenFiles = tokens.deleted
            result.tokenFilesLeft = tokens.undeleted
            result.entriesLeft += tokens.left
            result.otherCaseEntries += tokens.otherCase
            try afterStep(.tokenFiles)

            let leftovers = TokenAccounts.deleteWriterLeftoversForUninstall(context: context)
            result.temporariesLeft = leftovers.temporaries
            result.entriesLeft += leftovers.others
            result.add(removeDataFolderTemporaries(writer))
            try afterStep(.writerLeftovers)

            let folders: [(path: [String], step: Step)] = [
                (Layout.stateFolders, .state), (Layout.logsFolders, .logs),
                (Layout.backupsFolders, .backups), (Layout.probeFolders, .probe),
            ]
            for folder in folders {
                result.add(sweep(writer, folder.path, dryRun: false, now: now))
                try afterStep(folder.step)
            }

            let hooks = HookRecord(context: context)
            let links = hooks.removeListedLinks()
            result.linksRemoved = links.removed
            result.linksKept = links.kept
            // A record that stays, such as after a stop here, must not claim a link. With no
            // record there is nothing to clear, and nothing is made.
            if isOwnRegularFile(writer, [], HookRecord.fileName) { try? hooks.forgetAllLinks() }
            try afterStep(.links)

            result.add(removeFile(writer, HookRecord.fileName))
            try afterStep(.linkRecord)
            result.add(removeFile(writer, ConfigStore.fileName))
            try afterStep(.config)
        } catch {
            lock.release()
            throw error
        }
        lock.release()
        result.add(sweep(writer, Layout.locksFolders, dryRun: false, now: now))
        try afterStep(.locks)
        result.entriesLeft += strangers(writer)
        result.dataFolderRemoved = writer.removeRootIfEmpty()
        try afterStep(.dataFolder)
        return result
    }

    /// Refuses a data folder that is there but is not a real folder of the user's that passes the
    /// folder checks (a link, which is never followed, a file, another user's folder, or one wider
    /// than 0700, whose access list lets another user or group in or cannot be read, or that does
    /// not open), and the same for the token folder and the launch folder, which may hold a token.
    /// Every other folder of the tool's is refused when it is a real folder of the user's that
    /// fails the checks, a label's folder in the launch folder included. Every read of the plan
    /// would otherwise fail quietly and show nothing to remove while a token file is still there,
    /// and a run would leave the tool's files in a refused folder while it reports success. A
    /// missing data folder passes, and a link, a file or another user's folder where any folder
    /// but the data, token and launch folders belongs passes too: the run counts it and never
    /// follows it.
    public static func requireCheckable(_ context: ToolContext) throws {
        let writer = NoFollowWriter(root: context.dataRoot)
        switch writer.rootEntry() {
        case .missing, .folder:
            break
        case .link:
            throw ToolError(Messages.uninstallDataFolderIsALink)
        case .notFolder:
            throw ToolError(Messages.uninstallDataFolderIsNotAFolder)
        case .notYours:
            throw ToolError(Messages.uninstallDataFolderIsNotYours)
        case .problem(let problem):
            throw ToolError(
                Messages.uninstallFolderRefused("The data folder", "~/.agent-balancer", problem))
        }
        try TokenAccounts.requireCheckableForUninstall(context: context)
        let hooks = HookRecord(context: context)
        let linked = Set(hooks.listedLinks().compactMap { hooks.location(of: $0)?.folders[1] })
        try requireOtherFoldersCheckable(writer, linkedLabels: linked)
    }

    /// Refuses, with the folder's own fix, when a folder of the tool's other than the data, token
    /// and launch folders is a real folder of the user's that fails the folder checks: `state/`
    /// and the two folders in it, `logs/`, `locks/`, `probe/` and each probe's folder,
    /// `backups/`, and, where a listed link of the folder accounts in `linkedLabels` sits,
    /// `accounts/` and that account's two folders. A folder in one that is not a real folder of
    /// the user's is not looked at.
    static func requireOtherFoldersCheckable(_ writer: NoFollowWriter, linkedLabels: Set<String>)
        throws
    {
        // Whether `path` is a real folder of the user's that passes the checks.
        func check(_ path: [String]) throws -> Bool {
            let name = path[path.count - 1]
            let entry = writer.placeEntry(parent: Array(path.dropLast()), name: name)
            if case .problem(let problem) = entry {
                let place = (["~/.agent-balancer"] + path).joined(separator: "/")
                throw ToolError(Messages.uninstallFolderRefused("The folder", place, problem))
            }
            return entry == .folder
        }
        func names(_ path: [String]) -> [String] { (try? writer.listNames(folders: path)) ?? [] }
        if try check(Layout.stateFolders) {
            _ = try check(Layout.readingsFolders)
            _ = try check(ReadingHistory.folders)
        }
        for top in [Layout.logsFolders, Layout.locksFolders] { _ = try check(top) }
        if try check(Layout.probeFolders) {
            for name in names(Layout.probeFolders)
            where NoFollowWriter.isScratchName(name, prefix: Layout.probeFolderPrefix) {
                _ = try check(Layout.probeFolders + [name])
            }
        }
        _ = try check(Layout.backupsFolders)
        // Only the link step enters the account folders, and only where a listed link sits.
        guard !linkedLabels.isEmpty else { return }
        let accounts = [FolderPaths.accountsFolderName]
        if try check(accounts) {
            for label in linkedLabels.sorted() where ConfigValidator.isValidLabel(label) {
                let inner = FolderPaths.folders(label: label)
                if try check(Array(inner.dropLast())) { _ = try check(inner) }
            }
        }
    }

    /// The lease window `uninstall` starts from: the config's `picker.leaseMinutes`, or the
    /// default when no config can be read, as on a rerun after a run that deleted it.
    public static func leaseWindow(context: ToolContext) -> Int {
        (try? ConfigStore(context: context).load())?.picker.leaseMinutes
            ?? PickerSettings().leaseMinutes
    }

    /// The tool's regular files under the folder `top` of the data folder (a path of one name),
    /// by `OwnNames`, depth first: deleted, then each of the tool's folders left empty, that one
    /// included; or with `dryRun` only counted. Every other entry, a link, a folder the tool did
    /// not make and a folder that cannot be opened safely included, is counted once and never
    /// opened or followed; a folder of the tool's that cannot be opened but is empty goes like
    /// any other empty one and is not counted. A temporary file a write may still be using
    /// (`mayBeInUse`) stays and is counted on its own (`inUse`). It never throws.
    static func sweep(_ writer: NoFollowWriter, _ top: [String], dryRun: Bool, now: Date) -> Swept {
        switch (try? writer.folderEntry(parent: [], name: top[0])) ?? .other {
        case .missing:
            return Swept()
        case .other:
            return Swept(files: 0, left: 1)
        case .folder:
            let found = sweepFolder(writer, top, depth: 0, dryRun: dryRun, now: now)
            // A folder that is gone was empty, so nothing in it, itself included, was left.
            if !dryRun, (try? writer.removeEmptyFolder(parent: [], name: top[0])) == true {
                return Swept(files: found.files, left: 0)
            }
            return found
        }
    }

    private static func sweepFolder(
        _ writer: NoFollowWriter, _ path: [String], depth: Int, dryRun: Bool, now: Date
    ) -> Swept {
        guard depth < 8, let names = try? writer.listNames(folders: path),
            let real = try? writer.listFolders(folders: path)
        else { return Swept(files: 0, left: 1) }
        let folders = Set(real)
        var found = Swept()
        for name in names {
            if folders.contains(name) {
                guard OwnNames.isFolder(name, in: path) else {
                    found.left += 1
                    continue
                }
                let inner = sweepFolder(
                    writer, path + [name], depth: depth + 1, dryRun: dryRun, now: now)
                found.files += inner.files
                found.inUse += inner.inUse
                let gone =
                    !dryRun && (try? writer.removeEmptyFolder(parent: path, name: name)) == true
                if !gone { found.left += inner.left }
            } else if !OwnNames.isFile(name, in: path) {
                found.left += 1
            } else if mayBeInUse(writer, path, name, now: now) {
                found.inUse += 1
            } else if takeFile(writer, path, name, dryRun: dryRun) {
                found.files += 1
            } else {
                found.left += 1
            }
        }
        return found
    }

    /// The folders whose writers save without the pick lock that `uninstall` holds: the status
    /// rebuild holds the history lock, a reading save its probe lock, and a settings verdict
    /// save no lock.
    static let foldersSavedWithoutThePickLock: [[String]] = [
        Layout.stateFolders, Layout.readingsFolders, ReadingHistory.folders,
    ]

    /// How long a temporary file in those folders may still belong to a save in progress.
    static let saveInProgressSeconds: TimeInterval = 60

    /// Whether `name` in the folder `path` is a temporary file of a save that may still be
    /// running: in one of `foldersSavedWithoutThePickLock`, and modified less than
    /// `saveInProgressSeconds` before `now`, or after it. A run at least that long after the time
    /// it was modified deletes it, so one dated ahead of the clock stays until then.
    private static func mayBeInUse(
        _ writer: NoFollowWriter, _ path: [String], _ name: String, now: Date
    ) -> Bool {
        guard NoFollowWriter.isTemporaryName(name), foldersSavedWithoutThePickLock.contains(path),
            let info = try? writer.info(folders: path, name: name)
        else { return false }
        return now.timeIntervalSince(info.modified) < saveInProgressSeconds
    }

    /// Deletes `name` in the folder `path` when it is a regular file owned by the user, or with
    /// `dryRun` only says whether it is one. Returns whether it is, or was, deleted.
    private static func takeFile(
        _ writer: NoFollowWriter, _ path: [String], _ name: String, dryRun: Bool
    ) -> Bool {
        if !dryRun { return (try? writer.removeOwnRegularFile(folders: path, name: name)) == true }
        return isOwnRegularFile(writer, path, name)
    }

    /// Whether `lstat` shows `name` in the folder `path` as a regular file owned by the user.
    private static func isOwnRegularFile(_ writer: NoFollowWriter, _ path: [String], _ name: String)
        -> Bool
    {
        guard let info = try? writer.info(folders: path, name: name) else { return false }
        return info.isRegularFile && info.ownedByUser
    }

    /// The writer's temporary files directly in the data folder, from a write of the config or the
    /// link manifest that stopped before its rename: deleted, or with `dryRun` only counted.
    /// Another entry of that shape is counted as left.
    static func dataFolderTemporaries(_ writer: NoFollowWriter, dryRun: Bool) -> Swept {
        let names = ((try? writer.listNames(folders: [])) ?? []).filter(
            NoFollowWriter.isTemporaryName)
        var found = Swept()
        for name in names where takeFile(writer, [], name, dryRun: dryRun) { found.files += 1 }
        found.left = names.count - found.files
        return found
    }

    /// The writer leftovers step for the data folder. A temporary file there comes from a save of
    /// the config, made under the pick lock the caller holds, or of `links.json`, made under the
    /// links lock, so the files go only while that lock is held too; when it cannot be had within
    /// `lockWait` seconds, each one stays and is counted. It never throws.
    static func removeDataFolderTemporaries(_ writer: NoFollowWriter, lockWait: TimeInterval = 30)
        -> Swept
    {
        let found = dataFolderTemporaries(writer, dryRun: true)
        if found.files == 0 { return found }
        guard
            let lock = try? writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.linksLockName, wait: lockWait)
        else { return Swept(files: 0, left: found.files + found.left) }
        defer { lock.release() }
        return dataFolderTemporaries(writer, dryRun: false)
    }

    /// Entries directly in the data folder whose names the tool never gives there. Each counts
    /// once and is never opened. One that the volume takes for one of the tool's names, such as
    /// `STATE` on a volume that ignores case, is reached through that name by its own step, which
    /// counts it, so it is not counted again here.
    static func strangers(_ writer: NoFollowWriter) -> Int {
        let own: Set<String> = [
            ConfigStore.fileName, HookRecord.fileName, TokenPaths.folderName, LaunchFiles.folder,
            Layout.stateFolders[0], Layout.logsFolders[0], Layout.backupsFolders[0],
            Layout.probeFolders[0], Layout.locksFolders[0], FolderPaths.accountsFolderName,
        ]
        return ((try? writer.listNames(folders: [])) ?? []).filter { name in
            if own.contains(name) || NoFollowWriter.isTemporaryName(name) { return false }
            let folded = Paths.caseFolded(name)
            return !(own.contains(folded) && writer.isSameEntry(parent: [], name, folded))
        }.count
    }

    /// Deletes one file directly in the data folder when it is a regular file the user owns.
    /// Anything else under that name stays and is counted. It never throws.
    private static func removeFile(_ writer: NoFollowWriter, _ name: String) -> Swept {
        if takeFile(writer, [], name, dryRun: false) { return Swept(files: 1, left: 0) }
        let there = ((try? writer.info(folders: [], name: name)) ?? nil) != nil
        return Swept(files: 0, left: there ? 1 : 0)
    }
}

extension Uninstall.Result {
    fileprivate mutating func add(_ removed: Uninstall.Swept) {
        otherFiles += removed.files
        entriesLeft += removed.left
        stateTemporariesKept += removed.inUse
    }
}

extension Uninstall {
    /// The names the tool writes in the folders `uninstall` empties, each from its writer:
    /// `state/` holds the status rebuild's `status.json`, `current.json` and token rejections,
    /// the events record and the copies it sets aside, the leases, the pick log, the settings
    /// verdict, and the readings and their history in `readings/` and `history/`, one file per
    /// label; `logs/` holds the log; `backups/` the config backups; `probe/` one `p-<16 hex>`
    /// folder per probe, with whatever the probe left in it; `locks/` the pick, links, history and
    /// per-label probe locks. The writer's temporary files count where a whole-file write goes,
    /// and in `locks/` and `logs/`, where the check before a `login` sign-in makes one to test the
    /// folder. Anything else in those folders the tool did not make.
    enum OwnNames {
        /// Whether the tool writes a regular file named `name` directly in the folder `path`.
        static func isFile(_ name: String, in path: [String]) -> Bool {
            if isInsideProbeFolder(path) { return true }
            let temporary = NoFollowWriter.isTemporaryName(name)
            switch path {
            case Layout.stateFolders:
                let fixed: [String] = [
                    StatusBuilder.statusName, StatusBuilder.currentName,
                    StatusBuilder.rejectionsName, EventLog.fileName, Layout.leasesName,
                    Layout.picksLogName, Layout.settingsSeenName,
                ]
                return fixed.contains(name) || EventLog.isSetAsideName(name) || temporary
            case Layout.readingsFolders:
                return isLabelName(name, prefix: "", suffix: ".json") || temporary
            case ReadingHistory.folders:
                return isLabelName(name, prefix: "", suffix: ".jsonl") || temporary
            case Layout.logsFolders:
                return name == Layout.logName || temporary
            case Layout.backupsFolders:
                return ConfigStore.isBackupName(name) || temporary
            case Layout.locksFolders:
                let fixed: [String] = [
                    Layout.pickLockName, Layout.linksLockName, StatusBuilder.lockName,
                ]
                return fixed.contains(name) || isLabelName(name, prefix: "probe-", suffix: ".lock")
                    || temporary
            default:
                return false
            }
        }

        /// Whether the tool makes a folder named `name` directly in the folder `path`.
        static func isFolder(_ name: String, in path: [String]) -> Bool {
            if isInsideProbeFolder(path) { return true }
            if path == Layout.probeFolders {
                return NoFollowWriter.isScratchName(name, prefix: Layout.probeFolderPrefix)
            }
            let written: [[String]] = [Layout.readingsFolders, ReadingHistory.folders]
            return written.contains(path + [name])
        }

        /// True inside a probe's own folder, where everything is what the probe left.
        private static func isInsideProbeFolder(_ path: [String]) -> Bool {
            path.count >= 2 && path[0] == Layout.probeFolders[0]
                && NoFollowWriter.isScratchName(path[1], prefix: Layout.probeFolderPrefix)
        }

        /// Whether `name` is a label the tool accepts between `prefix` and `suffix`, the way
        /// `Layout.readingName`, `ReadingHistory.fileName` and `Layout.lockName` build it.
        private static func isLabelName(_ name: String, prefix: String, suffix: String) -> Bool {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                name.count > prefix.count + suffix.count
            else { return false }
            return ConfigValidator.isValidLabel(
                String(name.dropFirst(prefix.count).dropLast(suffix.count)))
        }
    }
}

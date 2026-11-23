import Foundation

/// The `doctor` checks that need no `claude`: the launch file count and age, a data folder in a
/// synced location, and access lists that let others in (docs/ARCHITECTURE.md section 13).
public enum DoctorChecks {
    /// What `doctor` says about each folder of the tool's that the folder checks refuse for its
    /// mode or its access list, that cannot be opened, searched or checked, or that is a link, a
    /// file or another user's folder, about a probe folder that holds something no probe made,
    /// and about each file of the tool's whose access list lets another user or group in, cannot
    /// be read, or keeps `lstat` out, each with its fix. What is in a folder refused for its mode
    /// or its list is checked in the same run; what is in one that cannot be opened or checked,
    /// once it can. No file is opened: a file's list is read by path, without following a link.
    /// The token and launch folders are judged by their own modules.
    public static func accessListProblems(context: ToolContext) -> [String] {
        let writer = NoFollowWriter.forDoctor(root: context.dataRoot)
        let top = NoFollowWriter.dataFolderPlace
        var found: [String] = []
        let start = writer.doctorVerdict(parent: [], name: nil)
        if let line = start.line { found.append(line) }
        guard start.readable else { return found }
        found += fileProblems(writer, [], top: top)
        // Whether what is in the folder `path` can be read, after naming it or the tool's files
        // in it.
        func folder(_ path: [String], files: Bool = true) -> Bool {
            let verdict = writer.doctorVerdict(
                parent: Array(path.dropLast()), name: path[path.count - 1])
            if let line = verdict.line { found.append(line) }
            if verdict.readable && files { found += fileProblems(writer, path, top: top) }
            return verdict.readable
        }
        func names(_ path: [String]) -> [String] { (try? writer.listNames(folders: path)) ?? [] }
        if folder(Layout.stateFolders) {
            _ = folder(Layout.readingsFolders)
            _ = folder(ReadingHistory.folders)
        }
        _ = folder(Layout.locksFolders)
        if folder(Layout.probeFolders) {
            var foreign = false
            for name in names(Layout.probeFolders) {
                guard NoFollowWriter.isScratchName(name, prefix: Layout.probeFolderPrefix) else {
                    foreign = true
                    continue
                }
                // What a probe leaves in its folder is `claude`'s, not the tool's.
                _ = folder(Layout.probeFolders + [name], files: false)
            }
            if foreign {
                found.append(
                    Messages.doctorHoldsForeignEntry(NoFollowWriter.place(Layout.probeFolders)))
            }
        }
        _ = folder(Layout.logsFolders)
        _ = folder(Layout.backupsFolders)
        let accounts = [FolderPaths.accountsFolderName]
        if folder(accounts) {
            for label in names(accounts) where ConfigValidator.isValidLabel(label) {
                let inner = FolderPaths.folders(label: label)
                if folder(Array(inner.dropLast())) { _ = folder(inner) }
            }
        }
        return found + TokenAccounts.accessListProblems(context: context)
            + Core.LaunchFiles.accessListProblems(context: context)
    }

    /// The `doctor` lines for the files the tool writes directly in the folder `path`: the config,
    /// the link manifest and their temporary files in the data folder, and by the names of
    /// `Uninstall.OwnNames` in the folders below it.
    private static func fileProblems(_ writer: NoFollowWriter, _ path: [String], top: String)
        -> [String]
    {
        let names = (try? writer.listNames(folders: path)) ?? []
        return names.compactMap { name in
            let own =
                path.isEmpty
                ? [ConfigStore.fileName, HookRecord.fileName].contains(name)
                    || NoFollowWriter.isTemporaryName(name)
                : Uninstall.OwnNames.isFile(name, in: path)
            guard own, let problem = writer.fileListProblem(folders: path, name: name) else {
                return nil
            }
            let place = ([top] + path + [name]).joined(separator: "/")
            return Messages.doctorFileProblem(place, problem)
        }
    }

    /// The launch files the tool holds, the age of the oldest, and the launch folders it cannot
    /// check. Never a launch file's path or any content.
    public struct LaunchSummary: Equatable, Sendable {
        /// The launch files the tool can count: those it can check, and those it cannot check,
        /// since each may hold a token. A launch file in a launch folder that cannot be listed
        /// counts only when a session record names it.
        public var count: Int
        public var oldestAge: TimeInterval?
        /// How many of `count` the tool cannot check.
        public var unchecked = 0
        /// The launch folders the folder checks refuse, as a person types them; each launch file
        /// in one is counted as one the tool cannot check.
        public var refusedFolders: [String] = []
        /// The launch folders that cannot be listed or checked, as a person types them.
        public var unlistedFolders: [String] = []
    }

    public static func launchFiles(
        context: ToolContext, snapshot: SessionsSnapshot, now: Date = Date()
    ) -> LaunchSummary {
        let inventory = Core.LaunchFiles.inventory(context: context, snapshot: snapshot, now: now)
        return LaunchSummary(
            count: inventory.files + inventory.unchecked, oldestAge: inventory.oldestAge,
            unchecked: inventory.unchecked, refusedFolders: inventory.refusedFolders,
            unlistedFolders: inventory.unlistedFolders)
    }

    /// Whether `doctor` exits 1 for its launch files: one it cannot check, a launch folder it
    /// cannot check, or a live session that names a launch file it cannot check. Each may hold a
    /// token, whatever else `doctor` says about the folder.
    public static func launchFilesFail(_ launch: LaunchSummary, sessionNamesUnchecked: Bool)
        -> Bool
    {
        sessionNamesUnchecked || launch.unchecked > 0 || !launch.refusedFolders.isEmpty
            || !launch.unlistedFolders.isEmpty
    }

    /// The `launch files` line of `doctor`: how many, the age of the oldest, how many the tool
    /// cannot check, and each launch folder it cannot check, so a count that leaves out the files
    /// of a folder it cannot list never reads as the whole.
    public static func launchFilesLine(_ launch: LaunchSummary) -> String {
        var line = "launch files: \(launch.count)"
        if let oldest = launch.oldestAge { line += ", oldest \(describe(age: oldest)) old" }
        if launch.unchecked > 0 { line += ", \(launch.unchecked) cannot be checked" }
        func folders(_ places: [String]) -> String {
            let noun = places.count == 1 ? "folder" : "folders"
            return ", and the launch \(noun) " + Messages.listed(places.map { "`" + $0 + "`" })
        }
        if !launch.refusedFolders.isEmpty {
            let it = launch.refusedFolders.count == 1 ? "it" : "them"
            line +=
                folders(launch.refusedFolders)
                + " cannot be checked, so each launch file in \(it) counts as one that cannot be checked"
        }
        if !launch.unlistedFolders.isEmpty {
            let it = launch.unlistedFolders.count == 1 ? "it" : "them"
            line +=
                folders(launch.unlistedFolders)
                + " cannot be checked or listed, so a launch file in \(it) counts only when a session record names it"
        }
        return line
    }

    /// `3 days`, `5 hours`, `12 minutes` or `under a minute`.
    public static func describe(age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 120 { return "\(minutes) minutes" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) hours" }
        return "\(hours / 24) days"
    }

    private static func provider(_ part: String) -> String? {
        if part == "Mobile Documents" || part == "iCloud Drive" { return "iCloud Drive" }
        if part == "Dropbox" || part.hasPrefix("Dropbox (") || part.hasPrefix("Dropbox-") {
            return "Dropbox"
        }
        if part == "OneDrive" || part.hasPrefix("OneDrive-") || part.hasPrefix("OneDrive - ") {
            return "OneDrive"
        }
        if part == "Google Drive" || part.hasPrefix("GoogleDrive") { return "Google Drive" }
        if part == "Box" || part == "Box Sync" || part.hasPrefix("Box-") { return "Box" }
        if part == "pCloud Drive" || part == "MEGA" { return "a sync service" }
        if part == "CloudStorage" { return "a cloud storage provider" }
        return nil
    }

    /// The name of the sync service when the data folder sits inside a synced location, or nil.
    /// The path is read as text; no file is opened.
    public static func syncedFolder(context: ToolContext) -> String? {
        for part in context.dataRoot.standardizedFileURL.pathComponents {
            if let name = provider(part) { return name }
        }
        return nil
    }
}

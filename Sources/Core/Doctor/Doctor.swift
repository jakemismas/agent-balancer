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

    /// The launch files the tool holds, and the age of the oldest. Never a path or any content.
    public struct LaunchSummary: Equatable, Sendable {
        public var count: Int
        public var oldestAge: TimeInterval?
    }

    public static func launchFiles(
        context: ToolContext, snapshot: SessionsSnapshot, now: Date = Date()
    ) -> LaunchSummary {
        let inventory = Core.LaunchFiles.inventory(context: context, snapshot: snapshot, now: now)
        return LaunchSummary(count: inventory.files, oldestAge: inventory.oldestAge)
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

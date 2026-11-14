import Foundation

/// Writing and deleting the token file. Like the read in `TokenSecret.swift`, it is reached only
/// from this module and the launch file upkeep; the commands go through `TokenAccounts` and
/// `TokenCapture`.
extension TokenStore {
    /// Writes `tokens/<label>.json` whole, at mode 0600, through a random temporary name and one
    /// rename, so a reader sees the old file or the new one and never half a token. The folder is
    /// marked as excluded from backups before the file lands in it.
    static func save(context: ToolContext, label: String, token: String) throws {
        guard isPlausible(token) else { throw ToolError("The token does not have a usable shape.") }
        let name = try TokenPaths.fileName(label: label)
        let body: [String: Any] = [
            "env": [
                ProtectedEnv.tokenVariable: token,
                LaunchFiles.accountVariable: label,
            ]
        ]
        let data =
            try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            + Data([0x0A])
        let writer = NoFollowWriter(root: context.dataRoot)
        try writer.prepare(folders: TokenPaths.folders)
        try writer.markExcludedFromBackup(folders: TokenPaths.folders)
        try writer.put(data, folders: TokenPaths.folders, name: name)
    }

    /// Deletes the token file of `label` when it is a regular file owned by the user. Returns
    /// whether a file was removed.
    @discardableResult
    static func delete(context: ToolContext, label: String) throws -> Bool {
        let name = try TokenPaths.fileName(label: label)
        return try NoFollowWriter(root: context.dataRoot).removeOwnRegularFile(
            folders: TokenPaths.folders, name: name)
    }

    /// Deletes the temporary files the no-follow writer left in `tokens/` when a write stopped
    /// before its rename; one may hold a whole token. Their names carry no label, so all of them
    /// go. Callers hold the pick lock, which every writer of a token file holds. Returns how many
    /// names of that shape are still there.
    @discardableResult
    static func deleteWriterLeftovers(context: ToolContext) throws -> Int {
        try NoFollowWriter(root: context.dataRoot).removeLeftoverTemporaries(
            folders: TokenPaths.folders)
    }

    /// How many temporary files the writer left in `tokens/`. Names only; nothing is opened.
    static func writerLeftoverCount(context: ToolContext) -> Int {
        (try? NoFollowWriter(root: context.dataRoot).leftoverTemporaries(
            folders: TokenPaths.folders
        ).count) ?? 0
    }

    /// Whether `name` is the name `TokenPaths.fileName` gives a label, `<label>.json`.
    static func isTokenFileName(_ name: String) -> Bool {
        name.hasSuffix(".json") && ConfigValidator.isValidLabel(String(name.dropLast(5)))
    }

    /// Whether `name` is a token file's name only once its letter case is folded, such as
    /// `Pool-a.json`. On a volume that ignores case, a save renames onto such an entry and keeps
    /// its spelling, so it may hold a token.
    static func isOtherCaseTokenFileName(_ name: String) -> Bool {
        !isTokenFileName(name) && isTokenFileName(Paths.caseFolded(name))
    }

    /// What `lstat` shows for a name in the token folder: a token file this tool made (a regular
    /// file owned by the user named `<label>.json`), a token file's name that `lstat` cannot
    /// check, such as in a folder the user cannot search, which may hold a token, or anything
    /// else. Nothing is opened.
    private enum TokenEntry { case own, unchecked, other }

    private static func tokenEntry(_ writer: NoFollowWriter, _ name: String) -> TokenEntry {
        guard isTokenFileName(name) else { return .other }
        do {
            guard let info = try writer.checkedInfo(folders: TokenPaths.folders, name: name)
            else { return .other }
            return info.isRegularFile && info.ownedByUser ? .own : .other
        } catch {
            return .unchecked
        }
    }

    /// How many entries in the token folder are named like a token file only in other letter
    /// case. Names only; nothing is opened.
    static func otherCaseEntryCount(context: ToolContext) -> Int {
        let writer = NoFollowWriter(root: context.dataRoot)
        let names = (try? writer.listNames(folders: TokenPaths.folders)) ?? []
        return names.filter(isOtherCaseTokenFileName).count
    }

    /// `uninstall`'s token file step: deletes every token file this tool made, a regular file owned
    /// by the user named `<label>.json` directly under the token folder. A token file that could
    /// not be deleted still holds its token and is counted on its own (`undeleted`), as is a token
    /// file's name that `lstat` cannot check, and so is an entry named like one only in other
    /// letter case (`otherCase`), which is never opened.
    /// Anything else there but the writer's temporary files is counted and left. A token folder
    /// that is a link or a file is never followed and counts as one entry. A token folder that is
    /// not private stops the run before any file goes; once one goes, the step no longer throws.
    /// Callers hold the pick lock.
    static func deleteFilesForUninstall(context: ToolContext) throws
        -> TokenAccounts.TokenFilesCleared
    {
        let writer = NoFollowWriter(root: context.dataRoot)
        var cleared = TokenAccounts.TokenFilesCleared()
        switch try writer.folderEntry(parent: [], name: TokenPaths.folderName) {
        case .missing: return cleared
        case .other:
            cleared.left = 1
            return cleared
        case .folder: break
        }
        for name in try writer.listNames(folders: TokenPaths.folders) {
            if NoFollowWriter.isTemporaryName(name) { continue }
            if isOtherCaseTokenFileName(name) {
                cleared.otherCase += 1
                continue
            }
            switch tokenEntry(writer, name) {
            case .other:
                cleared.left += 1
            case .unchecked:
                cleared.undeleted += 1
            case .own:
                let folders = TokenPaths.folders
                if (try? writer.removeOwnRegularFile(folders: folders, name: name)) == true {
                    cleared.deleted += 1
                } else {
                    cleared.undeleted += 1
                }
            }
        }
        return cleared
    }

    /// `uninstall`'s writer leftovers step for the token folder: the writer's leftover temporary
    /// files go, then the folder when it is empty. It never throws. Returns how many names of the
    /// temporary shape are still there.
    static func tidyForUninstall(context: ToolContext) -> Int {
        let left = (try? deleteWriterLeftovers(context: context)) ?? 0
        _ = try? NoFollowWriter(root: context.dataRoot).removeEmptyFolder(
            parent: [], name: TokenPaths.folderName)
        return left
    }

    /// How many token files `uninstall` deletes: those `deleteFilesForUninstall` takes, by the
    /// same rule, a token file's name that `lstat` cannot check included. Names and `lstat` only.
    static func fileCount(context: ToolContext) -> Int {
        let writer = NoFollowWriter(root: context.dataRoot)
        let names = (try? writer.listNames(folders: TokenPaths.folders)) ?? []
        return names.filter { tokenEntry(writer, $0) != .other }.count
    }

    /// How many names of the writer's temporary shape in the token folder `lstat` cannot check.
    /// Each may hold a whole token. Nothing is opened.
    static func uncheckedTemporaryCount(context: ToolContext) -> Int {
        NoFollowWriter(root: context.dataRoot).uncheckedCount(
            folders: TokenPaths.folders, of: NoFollowWriter.isTemporaryName)
    }
}

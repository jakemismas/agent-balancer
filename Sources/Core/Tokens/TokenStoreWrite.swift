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

    /// Deletes every token file this tool made (a regular file owned by the user, directly under
    /// the token folder) and the writer's leftover temporary files, then the folder when it is
    /// empty. Entries the tool did not make are counted and left alone. Callers hold the pick lock.
    static func deleteAll(context: ToolContext) throws -> (deleted: Int, skipped: Int) {
        let writer = NoFollowWriter(root: context.dataRoot)
        try deleteWriterLeftovers(context: context)
        var deleted = 0
        for name in try writer.listNames(folders: TokenPaths.folders) {
            if try writer.removeOwnRegularFile(folders: TokenPaths.folders, name: name) {
                deleted += 1
            }
        }
        let skipped = try writer.listNames(folders: TokenPaths.folders).count
        try writer.removeEmptyFolder(parent: [], name: TokenPaths.folderName)
        return (deleted, skipped)
    }

    /// How many token files the token folder holds. Names only.
    static func fileCount(context: ToolContext) -> Int {
        let names =
            (try? NoFollowWriter(root: context.dataRoot).listNames(folders: TokenPaths.folders))
            ?? []
        return names.filter { $0.hasSuffix(".json") }.count
    }
}

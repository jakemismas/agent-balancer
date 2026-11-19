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

/// What `remove` does with a token file it cannot check or delete (docs/ARCHITECTURE.md section
/// 4A.4, Removing): the file may still hold the token, so the remove stops before it deletes the
/// account, and its text names the token file or its folder and the commands that let the tool
/// check or delete it again.
extension TokenStore {
    /// The token folder as a person types it.
    static let typedFolder = "~/.agent-balancer/" + TokenPaths.folderName

    /// The token file of `label` as a person types it.
    static func typedFile(label: String) -> String { typedFolder + "/" + label + ".json" }

    /// Throws what `remove` stops with when it cannot check the token file of `label`: the token
    /// folder cannot be listed or searched, or `lstat` cannot check the token file. A token folder
    /// `lstat` cannot check, such as one whose access list denies you `readattr`, fails the folder
    /// checks, since that list cannot be read either, so it gets the cannot-be-checked text. Any
    /// other refusal of the token folder, such as a link, a file, another user's folder or one
    /// wider than 0700, throws the writer's refusal. A missing token folder or token file passes.
    /// `kept` says what the stop kept. Callers hold the pick lock.
    static func requireCheckedForRemove(
        context: ToolContext, label: String, kept: TokenAccounts.Kept
    ) throws {
        let name = try TokenPaths.fileName(label: label)
        let writer = NoFollowWriter(root: context.dataRoot)
        if !writer.opensForSearch(folders: TokenPaths.folders) {
            switch writer.placeEntry(parent: [], name: TokenPaths.folderName) {
            case .problem(.cannotOpen):
                throw ToolError(folderCannotOpenText(label: label, kept: kept))
            case .problem(.cannotCheck):
                throw ToolError(folderCannotCheckText(label: label, kept: kept))
            default: break
            }
        }
        do {
            _ = try writer.checkedInfo(folders: TokenPaths.folders, name: name)
        } catch is NoFollowWriter.UncheckedEntry {
            throw ToolError(fileCannotCheckText(label: label, kept: kept))
        }
    }

    /// Throws, once `remove` tried to delete the token file of `label`, while it may still hold
    /// the token: a regular file of the user's that is still there, such as a locked one, or one
    /// `lstat` cannot check. A link or anything else the tool did not make stays, as before.
    /// `account` says whether the label has a registry entry, which the stop keeps.
    static func requireDeletedForRemove(context: ToolContext, label: String, account: Bool) throws {
        try requireCheckedForRemove(
            context: context, label: label, kept: .after(tokenFile: false, account: account))
        let name = try TokenPaths.fileName(label: label)
        guard
            let info = try NoFollowWriter(root: context.dataRoot).info(
                folders: TokenPaths.folders, name: name),
            info.isRegularFile, info.ownedByUser
        else { return }
        throw ToolError(notDeletedText(label: label, account: account))
    }

    /// Whether the token file of `label` is there, a regular file of the user's, for what a stop
    /// of `remove` says it kept. Names and `lstat` only.
    static func isThere(context: ToolContext, label: String) -> Bool {
        guard let name = try? TokenPaths.fileName(label: label),
            let info = try? NoFollowWriter(root: context.dataRoot).info(
                folders: TokenPaths.folders, name: name)
        else { return false }
        return info.isRegularFile && info.ownedByUser
    }

    /// What `remove` stops with when the token folder is a real folder of the user's that cannot
    /// be opened or searched. `lstat` showed it is not a link, so its commands take no `-h`, and
    /// `chmod -N` clears its list without opening it. A lock on it keeps `chmod` from changing it.
    static func folderCannotOpenText(label: String, kept: TokenAccounts.Kept) -> String {
        "The token folder `\(typedFolder)` cannot be opened or searched, so `remove` cannot check whether a token file of '\(label)' is in it.\(kept.sentence) Run `chmod -N \(typedFolder)`, then `chmod 700 \(typedFolder)`, and `chflags nouchg,nouappnd \(typedFolder)` first if it is locked, then run `agent-balancer remove \(label)` again."
    }

    /// What `remove` stops with when `lstat` cannot check the token folder and it does not open to
    /// be searched. It may be a link, so `-h` keeps each command on the entry itself; `chmod -h -N`
    /// opens the entry, so `chmod -N` clears one whose list also denies its owner `list`.
    static func folderCannotCheckText(label: String, kept: TokenAccounts.Kept) -> String {
        "The token folder `\(typedFolder)` cannot be checked, so `remove` cannot tell what it is or whether a token file of '\(label)' is in it.\(kept.sentence) Run `chmod -h -N \(typedFolder)`, or `chmod -N \(typedFolder)` if that says Permission denied, then `chmod -h 700 \(typedFolder)`, then run `agent-balancer remove \(label)` again."
    }

    /// What `remove` stops with when `lstat` cannot check the token file, such as one whose access
    /// list denies its owner `readattr`. It may be a link, so `-h` keeps `chmod` on the entry
    /// itself, and `chmod -N` clears one whose list also denies its owner `read`.
    static func fileCannotCheckText(label: String, kept: TokenAccounts.Kept) -> String {
        let file = typedFile(label: label)
        return
            "The token file `\(file)` cannot be checked, so `remove` cannot tell what it is or whether it still holds the token of '\(label)'.\(kept.sentence) Run `chmod -h -N \(file)`, or `chmod -N \(file)` if that says Permission denied, then run `agent-balancer remove \(label)` again."
    }

    /// What `remove` stops with when its token file could not be deleted: a lock or an
    /// append-only flag on it or on its folder, an access list that denies its owner `delete` on
    /// the file or `delete_child` on the folder, or a folder that is not writable. The folder
    /// passed the folder checks, so `chmod -h -N` opens it.
    static func notDeletedText(label: String, account: Bool) -> String {
        let kept = account ? ", and the account was kept" : ""
        return
            "The token file `\(typedFile(label: label))` could not be deleted, so it still holds the token of '\(label)'\(kept). On `\(typedFolder)`, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on the token file, or `chmod -N` if that says Permission denied. Run `chflags -h nouchg,nouappnd` first on either of them that is locked. Then run `agent-balancer remove \(label)` again."
    }
}

import Foundation

/// Where a token account's token file is. It builds a path from a label and reads nothing.
public enum TokenPaths {
    static let folderName = "tokens"

    /// The folder under the data folder, as folder names for the no-follow reader and writer.
    public static let folders = [folderName]

    public static func fileName(label: String) throws -> String {
        guard ConfigValidator.isValidLabel(label) else {
            throw ToolError("Label is not valid.")
        }
        return label + ".json"
    }

    /// The absolute path of `tokens/<label>.json`. No file is opened.
    public static func fileURL(context: ToolContext, label: String) throws -> URL {
        try context.dataRoot.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName(label: label))
    }

    /// What the file system says about the token file, from `lstat` alone: the file is never
    /// opened and its content is never read.
    public struct Facts: Equatable, Sendable {
        public var exists: Bool
        public var isRegularFile: Bool
        public var ownedByUser: Bool
        public var mode: Int
        public var isPrivate: Bool { isRegularFile && ownedByUser && mode == 0o600 }
    }

    public static func facts(context: ToolContext, label: String) throws -> Facts {
        let name = try fileName(label: label)
        let none = Facts(exists: false, isRegularFile: false, ownedByUser: false, mode: 0)
        // The data root and tokens/ are opened with no-follow handles, so a link in either is refused.
        let dir = try NoFollowWriter.openFolder(
            root: context.dataRoot, folders: folders, create: false)
        guard dir >= 0 else { return none }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return none }
        return Facts(
            exists: true, isRegularFile: (st.st_mode & S_IFMT) == S_IFREG,
            ownedByUser: st.st_uid == getuid(), mode: Int(st.st_mode & 0o777))
    }
}

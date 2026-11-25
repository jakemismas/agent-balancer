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

    /// What the file system says about the token file, from `lstat` and its access list: the file
    /// is never opened and its content is never read.
    public struct Facts: Equatable, Sendable {
        public var exists: Bool
        public var isRegularFile: Bool
        public var ownedByUser: Bool
        public var mode: Int
        /// Last change of the file, from `lstat`. The estimate of the token's end counts from it.
        public var modified: Date? = nil
        /// Its access list lets another user or group in, or cannot be read.
        public var sharedByAccessList = false
        /// `lstat` cannot check the name in a token folder the user can search, as when the
        /// file's own list denies the user `readattr`, so that list cannot be read either.
        public var unchecked = false
        /// The user cannot search the token folder, as when its list denies the user `search`, so
        /// `lstat` can check no name in it and the token file may be there.
        public var folderUnsearchable = false
        public var isPrivate: Bool {
            isRegularFile && ownedByUser && mode == 0o600 && !sharedByAccessList
        }
        /// Whether a token file may be there: one `lstat` shows, or one it cannot check.
        public var mayExist: Bool { exists || unchecked || folderUnsearchable }
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
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            let failure = errno
            var facts = none
            // A folder the user cannot search keeps every name in it from `lstat`.
            if faccessat(dir, ".", X_OK, AT_EACCESS) != 0 {
                facts.folderUnsearchable = true
            } else {
                facts.unchecked = failure != ENOENT
            }
            return facts
        }
        let isRegular = (st.st_mode & S_IFMT) == S_IFREG
        let owned = st.st_uid == getuid()
        // By path, so a file whose list denies its owner `read` is judged too.
        let path = try fileURL(context: context, label: label).path
        let shared = isRegular && owned && AccessList.letsOthersIn(path: path)
        return Facts(
            exists: true, isRegularFile: isRegular, ownedByUser: owned,
            mode: Int(st.st_mode & 0o777),
            modified: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)),
            sharedByAccessList: shared)
    }
}

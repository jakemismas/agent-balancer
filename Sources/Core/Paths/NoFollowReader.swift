import Foundation

/// Reads for the tool's own data folder (no-follow) and for one outside file (settings).
public struct NoFollowReader: Sendable {
    public let root: URL
    public static let defaultLimit = 1_048_576

    public init(root: URL) {
        self.root = root
    }

    /// Reads `<root>/<folders...>/<name>`. Returns nil when it does not exist. A link anywhere on
    /// the way, or a file that is not a regular file, throws.
    public func read(folders: [String], name: String, limit: Int = defaultLimit) throws -> Data? {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return nil }
        defer { close(dir) }
        let fd = NoFollowWriter.openFileNoFollow(in: dir, name: name)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ToolError("Refused to read \(name): it is a link or cannot be opened.")
        }
        defer { close(fd) }
        return try Self.readAll(fd, name: name, limit: limit)
    }

    /// Reads a file outside the data folder, such as a settings file. Links are followed, because
    /// a user may keep such a file in a dotfiles folder. Returns nil when the file is missing.
    public static func readOutside(_ url: URL, limit: Int = defaultLimit) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw ToolError("Could not read \(url.lastPathComponent).")
        }
        defer { close(fd) }
        return try readAll(fd, name: url.lastPathComponent, limit: limit)
    }

    private static func readAll(_ fd: Int32, name: String, limit: Int) throws -> Data {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw ToolError("Refused to read \(name): it is not a regular file.")
        }
        guard st.st_size <= limit else { throw ToolError("\(name) is larger than \(limit) bytes.") }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 { throw ToolError("Could not read \(name).") }
            if n == 0 { break }
            data.append(chunk, count: n)
            if data.count > limit { throw ToolError("\(name) is larger than \(limit) bytes.") }
        }
        return data
    }
}

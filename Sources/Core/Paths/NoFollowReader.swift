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
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw ToolError("Could not read \(url.lastPathComponent).")
        }
        defer { close(fd) }
        return try readAll(fd, name: url.lastPathComponent, limit: limit)
    }

    /// The names in a folder outside the data folder, such as another tool's `sessions/` folder,
    /// or nil when it does not exist. Nothing is opened inside the folder.
    public static func listOutside(_ url: URL) throws -> [String]? {
        guard let stream = opendir(url.path) else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw ToolError("Could not list \(url.lastPathComponent).")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// Reads one file directly in a folder outside the data folder without following a link on the
    /// final name. Returns nil when the file is missing. A link, a file that is not a regular
    /// file, or one over `limit` bytes throws.
    public static func readEntryOutside(folder: URL, name: String, limit: Int = defaultLimit) throws
        -> Data?
    {
        try Paths.checkName(name)
        let path = folder.appendingPathComponent(name).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw ToolError("Could not read \(name).")
        }
        defer { close(fd) }
        return try readAll(fd, name: name, limit: limit)
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

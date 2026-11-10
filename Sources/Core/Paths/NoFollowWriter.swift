import Foundation

/// The only file that writes or deletes. Every create, rename and mode change works relative to a
/// folder handle opened with `O_NOFOLLOW`, so a planted symlink never redirects a write.
public struct NoFollowWriter: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Writes `data` whole to `<root>/<folders...>/<name>` at mode 0600 through a random temporary
    /// name and a rename. Folders are created at 0700. A refusal leaves everything as it was.
    public func put(_ data: Data, folders: [String], name: String) throws {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }

        var st = stat()
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            let isRegular = (st.st_mode & S_IFMT) == S_IFREG
            guard isRegular, st.st_uid == getuid() else {
                throw ToolError("Refused to write \(name): it is not a regular file made by you.")
            }
        }

        let temp = ".tmp-" + Paths.randomHex(8)
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolError("Could not write \(name).") }
        var ok = true
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 {
                    ok = false
                    return
                }
                offset += n
            }
        }
        if ok { ok = fsync(fd) == 0 && fchmod(fd, 0o600) == 0 }
        close(fd)
        if !ok {
            unlinkat(dir, temp, 0)
            throw ToolError("Could not write \(name).")
        }
        if renameat(dir, temp, dir, name) != 0 {
            unlinkat(dir, temp, 0)
            throw ToolError("Could not write \(name).")
        }
    }

    /// Creates the data root and the given folders at 0700 without writing a file.
    public func prepare(folders: [String]) throws {
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        close(dir)
    }

    /// Opens the data root, then each folder below it, with `O_NOFOLLOW | O_DIRECTORY`. A folder
    /// that is a link, not owned by the user, or wider than 0700 is refused.
    static func openFolder(root: URL, folders: [String], create: Bool) throws -> Int32 {
        if create { _ = mkdir(root.path, 0o700) }
        var dir = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else {
            if !create && errno == ENOENT { return -1 }
            throw ToolError("Refused the data folder: it is missing or is a link.")
        }
        do {
            try verifyFolder(dir)
            for name in folders {
                try Paths.checkName(name)
                if create { _ = mkdirat(dir, name, 0o700) }
                let next = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    let missing = errno == ENOENT
                    close(dir)
                    dir = -1
                    if !create && missing { return -1 }
                    throw ToolError("Refused the folder \(name): it is missing or is a link.")
                }
                close(dir)
                dir = next
                try verifyFolder(dir)
            }
        } catch {
            if dir >= 0 { close(dir) }
            throw error
        }
        return dir
    }

    /// Opens an existing file for reading without following a link on the final name.
    static func openFileNoFollow(in dir: Int32, name: String) -> Int32 {
        openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }

    private static func verifyFolder(_ fd: Int32) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw ToolError("Refused a data folder that is not yours or is wider than 0700.")
        }
    }
}

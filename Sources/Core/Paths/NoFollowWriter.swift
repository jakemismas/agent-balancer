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

/// An exclusive lock on a file under the data folder. It is released when this value goes away.
public final class FileLock: @unchecked Sendable {
    private var descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public func release() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}

extension NoFollowWriter {
    /// Takes an exclusive lock on `<root>/<folders...>/<name>`, making the file at 0600 when it is
    /// missing. Waits up to `wait` seconds and returns nil when the lock stays held. The lock file
    /// is never deleted, so two callers never lock two different files of one name.
    public func acquireLock(folders: [String], name: String, wait: TimeInterval) throws -> FileLock?
    {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }
        let fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolError("Could not open the lock file \(name).") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
            close(fd)
            throw ToolError("Refused the lock file \(name): it is not a regular file made by you.")
        }
        _ = fchmod(fd, 0o600)
        let deadline = Date().addingTimeInterval(max(0, wait))
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return FileLock(descriptor: fd) }
            if Date() >= deadline {
                close(fd)
                return nil
            }
            usleep(50_000)
        }
    }

    /// Makes a fresh folder `<prefix><16 hex>` at 0700 under `<root>/<parent...>` and returns its
    /// name. Before it makes one, a folder of that shape older than `staleAfter` seconds is
    /// removed. Anything else in the parent that is not such a folder refuses the call.
    public func makeScratchFolder(parent: [String], prefix: String, staleAfter: TimeInterval)
        throws -> String
    {
        let dir = try NoFollowWriter.openFolder(root: root, folders: parent, create: true)
        defer { close(dir) }
        let now = Date().timeIntervalSince1970
        for entry in try NoFollowWriter.entries(of: dir) {
            var st = stat()
            if fstatat(dir, entry, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                // Another probe removed its own folder after the listing.
                if errno == ENOENT { continue }
                throw ToolError("Could not read the probe folder.", code: .checkFailed)
            }
            let isFolder = (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
            guard isFolder, NoFollowWriter.isScratchName(entry, prefix: prefix) else {
                throw ToolError(
                    "The probe folder holds something that is not a probe folder.",
                    code: .checkFailed)
            }
            let modified = Double(st.st_mtimespec.tv_sec)
            if now - modified > staleAfter {
                NoFollowWriter.removeTree(in: dir, name: entry, depth: 0)
            }
        }
        let name = prefix + Paths.randomHex(8)
        guard mkdirat(dir, name, 0o700) == 0 else {
            throw ToolError("Could not make a probe folder.", code: .checkFailed)
        }
        return name
    }

    /// Removes a folder made by `makeScratchFolder`, and what is inside it, without following links.
    public func removeScratchFolder(parent: [String], name: String, prefix: String) {
        guard NoFollowWriter.isScratchName(name, prefix: prefix) else { return }
        guard let dir = try? NoFollowWriter.openFolder(root: root, folders: parent, create: false),
            dir >= 0
        else { return }
        defer { close(dir) }
        NoFollowWriter.removeTree(in: dir, name: name, depth: 0)
    }

    static func isScratchName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let rest = name.dropFirst(prefix.count)
        return rest.count == 16 && rest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func entries(of dir: Int32) throws -> [String] {
        let copy = dup(dir)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw ToolError("Could not list the probe folder.", code: .checkFailed)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Deletes `name` under `parent`. Folders are opened with `O_NOFOLLOW`; any other entry,
    /// a link included, is unlinked itself and never followed.
    private static func removeTree(in parent: Int32, name: String, depth: Int) {
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            unlinkat(parent, name, 0)
            return
        }
        if depth < 8,
            case let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
            child >= 0
        {
            if let names = try? entries(of: child) {
                for entry in names { removeTree(in: child, name: entry, depth: depth + 1) }
            }
            close(child)
        }
        unlinkat(parent, name, AT_REMOVEDIR)
    }
}

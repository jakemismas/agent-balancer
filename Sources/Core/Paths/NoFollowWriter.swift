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
        try Self.writeFile(data, in: dir, name: name)
    }

    /// The write `put` does, relative to an open folder handle.
    static func writeFile(_ data: Data, in dir: Int32, name: String) throws {
        var st = stat()
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            let isRegular = (st.st_mode & S_IFMT) == S_IFREG
            guard isRegular, st.st_uid == getuid() else {
                throw ToolError("Refused to write \(name): it is not a regular file made by you.")
            }
        }

        let temp = Self.temporaryPrefix + Paths.randomHex(8)
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
        do {
            try Self.beforeRename.run(name)
        } catch {
            unlinkat(dir, temp, 0)
            throw error
        }
        if renameat(dir, temp, dir, name) != 0 {
            unlinkat(dir, temp, 0)
            throw ToolError("Could not write \(name).")
        }
    }

    /// Test seam: runs after the temporary file is complete and before the rename, so a test can
    /// stop a write at that point.
    final class RenameHook: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [String: @Sendable () throws -> Void] = [:]

        /// Sets or, with nil, clears the action for writes of the file `name`.
        func set(_ name: String, _ new: (@Sendable () throws -> Void)?) {
            lock.lock()
            actions[name] = new
            lock.unlock()
        }

        func run(_ name: String) throws {
            lock.lock()
            let current = actions[name]
            lock.unlock()
            try current?()
        }
    }

    static let beforeRename = RenameHook()

    /// Creates the data root and the given folders at 0700 without writing a file.
    public func prepare(folders: [String]) throws {
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        close(dir)
    }

    /// Opens the data root, then each folder below it, with `O_NOFOLLOW | O_DIRECTORY`. A folder
    /// that is a link, not owned by the user, or wider than 0700 is refused.
    static func openFolder(
        root: URL, folders: [String], create: Bool, ownerId: uid_t = getuid()
    ) throws -> Int32 {
        if create { _ = mkdir(root.path, 0o700) }
        var dir = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else {
            if !create && errno == ENOENT { return -1 }
            throw ToolError("Refused the data folder: it is missing or is a link.")
        }
        do {
            try verifyFolder(dir, ownerId: ownerId)
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
                try verifyFolder(dir, ownerId: ownerId)
            }
        } catch {
            if dir >= 0 { close(dir) }
            throw error
        }
        return dir
    }

    /// Opens an existing file for reading without following a link on the final name.
    static func openFileNoFollow(in dir: Int32, name: String) -> Int32 {
        openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }

    private static func verifyFolder(_ fd: Int32, ownerId: uid_t) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == ownerId, st.st_mode & 0o077 == 0 else {
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
        // Callers creating the same lock file at once can see a transient ENOENT, so retry a few times.
        var fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var tries = 0
        while fd < 0 && (errno == ENOENT || errno == EEXIST) && tries < 20 {
            tries += 1
            usleep(10_000)
            fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
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

/// What `lstat` says about one file the tool made.
public struct OwnFileInfo: Equatable, Sendable {
    public var isRegularFile: Bool
    public var ownedByUser: Bool
    public var mode: Int
    public var modified: Date
}

extension NoFollowWriter {
    /// Appends `data` to `<root>/<folders...>/<name>` at mode 0600. The final name is opened with
    /// `O_NOFOLLOW`, and a file that is not a regular file made by you is refused.
    public func append(_ data: Data, folders: [String], name: String) throws {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }
        let fd = openat(dir, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolError("Could not write \(name).") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
            throw ToolError("Refused to write \(name): it is not a regular file made by you.")
        }
        _ = fchmod(fd, 0o600)
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
        if !ok { throw ToolError("Could not write \(name).") }
    }

    /// The names in `<root>/<folders...>`, or an empty list when that folder does not exist.
    public func listNames(folders: [String]) throws -> [String] {
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return [] }
        defer { close(dir) }
        return try NoFollowWriter.entries(of: dir).sorted()
    }

    /// `lstat` of `<root>/<folders...>/<name>`, or nil when it is missing.
    public func info(folders: [String], name: String) throws -> OwnFileInfo? {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return nil }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return OwnFileInfo(
            isRegularFile: (st.st_mode & S_IFMT) == S_IFREG, ownedByUser: st.st_uid == getuid(),
            mode: Int(st.st_mode & 0o777),
            modified: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)))
    }

    /// Deletes `<root>/<folders...>/<name>` only when `lstat` shows a regular file owned by the
    /// user. Anything else, a link included, is left alone. Returns whether a file was removed.
    @discardableResult
    public func removeOwnRegularFile(folders: [String], name: String) throws -> Bool {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return false }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
            (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid()
        else { return false }
        return unlinkat(dir, name, 0) == 0
    }
}

extension NoFollowWriter {
    static let temporaryPrefix = ".tmp-"

    /// Whether `name` has the shape of the temporary name `put` writes to before its rename.
    public static func isTemporaryName(_ name: String) -> Bool {
        name.range(of: #"\A\.tmp-[0-9a-f]{16}\z"#, options: .regularExpression) != nil
    }

    /// The temporary files `put` left directly in `<root>/<folders...>` when a write stopped
    /// before its rename: names of that shape that `lstat` shows as a regular file owned by the
    /// user. Such a file may hold the whole content of the write. Nothing is opened.
    public func leftoverTemporaries(folders: [String]) throws -> [String] {
        try listNames(folders: folders).filter { name in
            guard Self.isTemporaryName(name), let facts = try? info(folders: folders, name: name)
            else { return false }
            return facts.isRegularFile && facts.ownedByUser
        }
    }

    /// Deletes the temporary files `put` left directly in `<root>/<folders...>`. Callers hold the
    /// lock every writer of that folder holds, so none of them belongs to a write in progress.
    /// Anything else of that shape, a link included, is left alone. Returns how many names of that
    /// shape are still there when it has read the folder again.
    @discardableResult
    public func removeLeftoverTemporaries(folders: [String]) throws -> Int {
        for name in try leftoverTemporaries(folders: folders) {
            try removeOwnRegularFile(folders: folders, name: name)
        }
        return try listNames(folders: folders).filter(Self.isTemporaryName).count
    }
}

extension NoFollowWriter {
    static let backupExcludeName = "com.apple.metadata:com_apple_backup_excludeItem"

    /// Marks `<root>/<folders...>` as excluded from backups. The folder is opened with no-follow
    /// handles and the attribute is set on that handle, so a planted link is never followed. The
    /// folder is made first when it is missing. An attribute that is already set is left alone.
    public func markExcludedFromBackup(folders: [String]) throws {
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }
        if fgetxattr(dir, Self.backupExcludeName, nil, 0, 0, 0) >= 0 { return }
        let value = try PropertyListSerialization.data(
            fromPropertyList: "com.apple.backupd", format: .binary, options: 0)
        let ok = value.withUnsafeBytes {
            fsetxattr(dir, Self.backupExcludeName, $0.baseAddress, value.count, 0, 0) == 0
        }
        if !ok { throw ToolError("Could not mark a data folder as excluded from backups.") }
    }

    /// Whether `<root>/<folders...>` carries the backup exclusion. A missing folder reads as no.
    public func isExcludedFromBackup(folders: [String]) throws -> Bool {
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return false }
        defer { close(dir) }
        return fgetxattr(dir, Self.backupExcludeName, nil, 0, 0, 0) >= 0
    }

    /// Removes the folder `name` under `<root>/<parent...>` only when it is empty and a real folder
    /// made by the user. Returns whether it was removed.
    @discardableResult
    public func removeEmptyFolder(parent: [String], name: String) throws -> Bool {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: parent, create: false)
        if dir < 0 { return false }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
            (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid()
        else { return false }
        return unlinkat(dir, name, AT_REMOVEDIR) == 0
    }
}

extension NoFollowWriter {
    /// Deletes `<root>/<folders...>/<name>` only when `lstat` shows a symbolic link owned by the
    /// user whose target text equals `target`. A regular file, a folder, a link with another target
    /// and anything missing stay as they are. Returns whether a link was removed.
    @discardableResult
    public func removeLink(folders: [String], name: String, target: String) throws -> Bool {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return false }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
            (st.st_mode & S_IFMT) == S_IFLNK, st.st_uid == getuid()
        else { return false }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlinkat(dir, name, &buffer, buffer.count - 1)
        guard length > 0 else { return false }
        let actual = String(
            decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard actual == target else { return false }
        return unlinkat(dir, name, 0) == 0
    }

    /// Whether `<root>/<folders...>/<name>` is a symbolic link owned by the user with that target.
    public func hasLink(folders: [String], name: String, target: String) throws -> Bool {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return false }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
            (st.st_mode & S_IFMT) == S_IFLNK, st.st_uid == getuid()
        else { return false }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlinkat(dir, name, &buffer, buffer.count - 1)
        guard length > 0 else { return false }
        return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            == target
    }

    /// Lists the names directly under `<root>/<folders...>` that `lstat` shows as folders owned by
    /// the user. A link to a folder is not one.
    public func listFolders(folders: [String]) throws -> [String] {
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return [] }
        defer { close(dir) }
        return try NoFollowWriter.entries(of: dir).sorted().filter { name in
            var st = stat()
            return fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0
                && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
        }
    }
}

extension NoFollowWriter {
    /// Creates the symbolic link `<root>/<folders...>/<name>` that points at `target`, an absolute
    /// path. The folders must already exist and pass the folder checks; a name that is taken, a
    /// link included, is refused and left as it is.
    public func makeLink(folders: [String], name: String, target: String) throws {
        try Paths.checkName(name)
        guard target.hasPrefix("/"), !target.contains("\0") else {
            throw ToolError("Refused a link target that is not an absolute path.")
        }
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        guard dir >= 0 else { throw ToolError("The folder for the link does not exist.") }
        defer { close(dir) }
        guard symlinkat(target, dir, name) == 0 else {
            throw ToolError("Could not create the link \(name).")
        }
    }
}

/// Which file a descriptor or a path names: its device and inode.
public struct FileIdentity: Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64

    init(_ st: stat) {
        device = Int64(st.st_dev)
        inode = UInt64(st.st_ino)
    }

    /// The identity of what `path` names, following links, or nil when nothing is there.
    public static func of(path: String) -> FileIdentity? {
        var st = stat()
        return stat(path, &st) == 0 ? FileIdentity(st) : nil
    }
}

/// A folder opened once and written relative to its handle. Before each write, every name from
/// the start folder down is checked to still name the folder that was opened, and neither the
/// folder written into nor any folder above it may be a protected one, as the protected folders
/// were when the run started or as they read at that moment, so a folder swapped for a link,
/// moved into a protected folder, or named by a protected path part way stops the run instead of
/// sending a file there.
public final class HeldFolder: @unchecked Sendable {
    private let start: Int32
    /// The descriptor of each name in `names`; the last is the folder written into.
    private let chain: [Int32]
    private let names: [String]
    private let identities: [FileIdentity]
    private let refused: [FileIdentity]
    /// The protected folders as they read now, or nil when one cannot be compared.
    private let current: @Sendable () -> [FileIdentity]?

    fileprivate init(
        start: Int32, chain: [Int32], names: [String], identities: [FileIdentity],
        refused: [FileIdentity], current: @escaping @Sendable () -> [FileIdentity]?
    ) {
        self.start = start
        self.chain = chain
        self.names = names
        self.identities = identities
        self.refused = refused
        self.current = current
    }

    deinit {
        for fd in chain { close(fd) }
        close(start)
    }

    /// Writes `data` to `name` in the held folder as `NoFollowWriter.put` does.
    public func put(_ data: Data, name: String) throws {
        try Paths.checkName(name)
        var parent = start
        for (index, part) in names.enumerated() {
            var st = stat()
            guard fstatat(parent, part, &st, AT_SYMLINK_NOFOLLOW) == 0,
                (st.st_mode & S_IFMT) == S_IFDIR, FileIdentity(st) == identities[index]
            else {
                throw ToolError(
                    "The output folder changed while the files were written, so the run stopped.")
            }
            parent = chain[index]
        }
        guard let folder = chain.last else { throw ToolError("No output folder.") }
        guard let now = current(), NoFollowWriter.isOutside(refused + now, from: folder) else {
            throw ToolError(
                "The output folder is now a protected folder or inside one, a protected folder cannot be compared, or a folder above it cannot be read, so the run stopped."
            )
        }
        try NoFollowWriter.writeFile(data, in: folder, name: name)
    }
}

extension NoFollowWriter {
    /// Opens `<start>/<names...>` one name at a time, each relative to the folder before it with
    /// `O_DIRECTORY | O_NOFOLLOW`, and makes the last name at 0700 when it is missing. The start
    /// must be the folder the path `checked` names, with no folder of `refused` at or above it.
    /// Every folder opened must be a real folder that is not one of `refused`; the last must be
    /// owned by the user and private, and neither it nor a folder above it may be one that
    /// `current` gives, read after it is open. Nothing is made unless every check before it
    /// passed.
    public static func holdFolder(
        start: String, checked: String, names: [String], refused: [FileIdentity],
        current: @escaping @Sendable () -> [FileIdentity]? = { [] }
    ) throws -> HeldFolder {
        guard let last = names.last else { throw ToolError("No output folder was given.") }
        for name in names { try Paths.checkName(name) }
        let base = open(start, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw ToolError("Could not open the current folder.") }
        var chain: [Int32] = []
        var identities: [FileIdentity] = []
        func fail(_ text: String) -> ToolError {
            for fd in chain { close(fd) }
            close(base)
            return ToolError(text)
        }
        func identity(_ fd: Int32) -> FileIdentity? {
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return FileIdentity(st)
        }
        guard let baseIdentity = identity(base), !refused.contains(baseIdentity) else {
            throw fail("Refused the current folder.")
        }
        // The rules were checked on a path; a start that is another folder was never checked.
        var named = stat()
        guard lstat(checked, &named) == 0, FileIdentity(named) == baseIdentity else {
            throw fail("Refused the current folder: it is not the folder that was checked.")
        }
        guard isOutside(refused, from: base) else {
            throw fail(
                "Refused the current folder: it is inside a protected folder, or a folder above it cannot be read."
            )
        }
        var parent = base
        for (index, name) in names.enumerated() {
            // Only the output folder itself may be made; every folder above it must exist.
            if index == names.count - 1 { _ = mkdirat(parent, name, 0o700) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                throw fail("Refused the folder \(name): it is missing or a link.")
            }
            chain.append(fd)
            guard let id = identity(fd), !refused.contains(id) else {
                throw fail("Refused the folder \(name).")
            }
            identities.append(id)
            parent = fd
        }
        // A protected path that named nothing before may name the folder just made.
        guard let now = current(), isOutside(refused + now, from: parent) else {
            throw fail("Refused the folder \(last): it is a protected folder or inside one.")
        }
        do {
            try verifyFolder(parent, ownerId: getuid())
        } catch {
            throw fail("Refused the folder \(last): it is not yours or is wider than 0700.")
        }
        return HeldFolder(
            start: base, chain: chain, names: names, identities: identities, refused: refused,
            current: current)
    }

    /// Whether no folder from `folder` up to the root is one of `refused`. Each step opens `..` of
    /// the folder before it, so the answer holds whatever path, or no path, names the folder. Any
    /// step that cannot be taken answers no.
    static func isOutside(_ refused: [FileIdentity], from folder: Int32) -> Bool {
        var st = stat()
        guard fstat(folder, &st) == 0 else { return false }
        var here = FileIdentity(st)
        var current = folder
        defer { if current != folder { close(current) } }
        // Far deeper than any real folder, so a walk that never reaches the root is refused.
        for _ in 0..<4096 {
            if refused.contains(here) { return false }
            let up = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard up >= 0 else { return false }
            if current != folder { close(current) }
            current = up
            guard fstat(up, &st) == 0 else { return false }
            let parent = FileIdentity(st)
            // Only the root is its own parent.
            if parent == here { return true }
            here = parent
        }
        return false
    }
}

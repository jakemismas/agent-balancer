import Foundation

/// The only file that writes or deletes. Every create, rename and mode change works relative to a
/// folder handle opened with `O_NOFOLLOW`, so a planted symlink never redirects a write.
public struct NoFollowWriter: Sendable {
    public let root: URL
    /// Off only for `doctor`'s reads of names and access lists, which go on inside a folder the
    /// checks refuse for its mode or its list. Every write and delete keeps the checks.
    let strict: Bool

    public init(root: URL) {
        self.root = root
        strict = true
    }

    /// A writer whose reads of names and access lists open folders as `doctor` does.
    static func forDoctor(root: URL) -> NoFollowWriter { NoFollowWriter(root: root, strict: false) }

    private init(root: URL, strict: Bool) {
        self.root = root
        self.strict = strict
    }

    /// Writes `data` whole to `<root>/<folders...>/<name>` at mode 0600 through a random temporary
    /// name and a rename. Folders are created at 0700. A refusal leaves everything as it was.
    public func put(_ data: Data, folders: [String], name: String) throws {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }
        Self.trace.note(root, .changed(Self.joined(folders)))
        try Self.writeFile(data, in: dir, name: name, traced: (root, folders))
    }

    /// The write `put` does, relative to an open folder handle. `traced` names the data folder
    /// and the folder, for the test seam.
    static func writeFile(
        _ data: Data, in dir: Int32, name: String, traced: (URL, [String])? = nil
    ) throws {
        guard isReplaceable(in: dir, name: name) else {
            throw ToolError("Refused to write \(name): it is not a regular file made by you.")
        }
        var st = stat()
        let existed = fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0
        guard let made = makeTemporary(in: dir) else {
            throw ToolError("Could not write \(name).")
        }
        let (fd, temp) = made
        if let (root, folders) = traced {
            trace.note(root, .file(joined(folders + [temp]), .create))
        }
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
        if let (root, folders) = traced {
            trace.note(root, .file(joined(folders + [name]), existed ? .replace : .create))
        }
        if renameat(dir, temp, dir, name) != 0 {
            unlinkat(dir, temp, 0)
            throw ToolError("Could not write \(name).")
        }
    }

    /// Whether a write may put a file at `name` in `dir`: nothing is there, or a regular file of
    /// the user's is. A write never replaces anything else.
    static func isReplaceable(in dir: Int32, name: String) -> Bool {
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return true }
        return (st.st_mode & S_IFMT) == S_IFREG && st.st_uid == getuid()
    }

    /// Makes a new file of the writer's temporary shape in `dir` at 0600, with the inheritable
    /// entries of its folder that let anyone but the user in cleared, and returns its open handle
    /// and name; nil when it cannot be made or cleared, and then nothing is left.
    static func makeTemporary(in dir: Int32) -> (Int32, String)? {
        let temp = temporaryPrefix + Paths.randomHex(8)
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        // A new file takes its folder's inheritable entries, so they go before the first byte.
        guard shutOthersOut(fd) else {
            close(fd)
            unlinkat(dir, temp, 0)
            return nil
        }
        return (fd, temp)
    }

    /// Throws, before a step that writes in `<root>/<folders...>` runs, the refusal that step
    /// would meet there: the folder checks on every folder down to it (each made when missing),
    /// a folder in which no file can be made and deleted, or one whose new file keeps an access
    /// list the tool cannot read after the writer's clear, as an inherited entry that denies the
    /// user `readsecurity` makes; and for each name of `replacing` that is there, what
    /// `requireReplaceable` refuses. It makes and deletes one file of the writer's temporary shape
    /// there, the way a write starts and a failed one ends. A probe file it cannot delete loses
    /// its own access list and is deleted again before the refusal, which names one that stays.
    /// One that another command's cleanup deleted first is made again, once.
    public func requireWritable(folders: [String], replacing names: [String] = []) throws {
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }
        let place = Self.place(folders)
        let path = Self.joined(folders)
        var tries = 0
        while true {
            tries += 1
            guard let made = Self.makeTemporary(in: dir) else {
                Self.trace.note(root, .refused(path))
                throw ToolError(Self.notWritableText(dir, place))
            }
            _ = try? Self.afterCheckFileMade.run(root.path + "/" + path)
            let listed = AccessList.verdict(made.0)
            // A new file's inherited entries can deny its maker a later open, so the probe file
            // must open as the reader, an append and a lock open the tool's own files.
            let opens = Self.reopensAsTheTool(in: dir, name: made.1)
            // Another command's cleanup of the writer's leftovers may have deleted it first.
            let vanished = !opens && errno == ENOENT
            if unlinkat(dir, made.1, 0) != 0 && errno != ENOENT {
                // An inherited entry that denies deleting it goes with the file's own list.
                _ = Self.clearList(made.0)
                let kept = unlinkat(dir, made.1, 0) != 0 && errno != ENOENT
                close(made.0)
                Self.trace.note(root, .refused(path))
                let left = kept ? " " + Messages.checkLeft(place + "/" + made.1, folder: false) : ""
                throw ToolError(Self.notWritableText(dir, place) + left)
            }
            close(made.0)
            if vanished && tries == 1 { continue }
            guard listed == .closed && opens else {
                Self.trace.note(root, .refused(path))
                throw ToolError(Messages.folderGivesClosedFiles(place))
            }
            break
        }
        Self.trace.note(root, .checked(path, .probeList))
        Self.trace.note(root, .proved(path))
        for name in names { try requireReplaceable(folders: folders, name: name) }
    }

    /// Whether the existing file `name` in `dir` opens as the tool opens its own files once they
    /// are made: to read, as the reader does, to add lines, as `append` does, and to read and
    /// write, as a lock does.
    static func reopensAsTheTool(in dir: Int32, name: String) -> Bool {
        let flags = [
            O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, O_RDWR | O_NOFOLLOW | O_CLOEXEC,
        ]
        let read = openFileNoFollow(in: dir, name: name)
        guard read >= 0 else { return false }
        close(read)
        for flag in flags {
            let fd = openat(dir, name, flag)
            guard fd >= 0 else { return false }
            close(fd)
        }
        return true
    }

    /// Throws, before a step reads `<root>/<folders...>/<name>`, what keeps the reader from it:
    /// the folder checks, and a file there that does not open as the reader opens it, is not a
    /// regular file, or is larger than `limit`. Nothing in the file is read. A missing file or
    /// folder passes.
    func requireReadable(folders: [String], name: String, limit: Int, shown: Shown? = nil) throws {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        guard dir >= 0 else { return }
        defer { close(dir) }
        let path = Self.joined(folders + [name])
        let place = Self.place(folders + [name])
        let subject = shown?.subject ?? "`\(place)`"
        let fd = Self.openFileNoFollow(in: dir, name: name)
        var text: String?
        var st = stat()
        if fd < 0 {
            if errno == ENOENT { return }
            text =
                errno == ELOOP
                ? Messages.fileRefused(subject, shown?.path ?? place, .notRegular, "read it")
                : Messages.fileNotReadable(subject, shown?.path ?? place)
        } else if fstat(fd, &st) != 0 || (st.st_mode & S_IFMT) != S_IFREG {
            text = Messages.fileRefused(subject, shown?.path ?? place, .notRegular, "read it")
        } else if st.st_size > limit {
            text = Messages.fileTooLarge(subject)
        }
        if fd >= 0 { close(fd) }
        if let text {
            Self.trace.note(root, .fileRefused(path))
            throw ToolError(text)
        }
        Self.trace.note(root, .checked(path, .readable))
    }

    /// What a check says about a folder in which the tool cannot make and delete a file: a
    /// flag on the folder by its name, or the fix for an access list or a mode.
    private static func notWritableText(_ dir: Int32, _ place: String) -> String {
        var st = stat()
        guard fstat(dir, &st) == 0, let flags = FileFlags(st.st_flags) else {
            return Messages.folderNotWritable(place)
        }
        return Messages.flagged("`\(place)`", place, flags, "make and delete what it writes in it")
    }

    /// The flags on a file or folder that keep the tool from replacing, deleting or writing it:
    /// the user's immutable (`uchg`, Finder's Locked box) and append-only (`uappnd`) flags, which
    /// the user can clear, and the system's, which only an administrator can.
    public struct FileFlags: Equatable, Sendable {
        /// The user's flags set, by the names `chflags` takes.
        public let user: [String]
        public let system: Bool

        init?(_ bits: UInt32) {
            var user: [String] = []
            if bits & UInt32(UF_IMMUTABLE) != 0 { user.append("uchg") }
            if bits & UInt32(UF_APPEND) != 0 { user.append("uappnd") }
            system = bits & UInt32(SF_IMMUTABLE | SF_APPEND | SF_NOUNLINK) != 0
            self.user = user
            if user.isEmpty && !system { return nil }
        }
    }

    /// Why a step cannot replace or delete a file of the tool's.
    public enum FileRefusal: Equatable, Sendable {
        /// Not a regular file of the user's, such as a link, which the writer never replaces.
        case notRegular
        case flagged(FileFlags)
        /// Its access list, or its folder's, keeps the user from deleting it.
        case deleteDenied
        /// `lstat` cannot check it, as when its list denies the user `readattr`.
        case unchecked
    }

    /// Why the entry `name` in `dir` cannot be replaced or deleted, or nil when it can or when
    /// nothing is there. A rename over a file needs the right to delete it, which an owner's
    /// `deny delete` entry or a `uchg` flag takes away; `faccessat` with `_DELETE_OK` asks for
    /// it without deleting.
    static func replaceProblem(in dir: Int32, name: String) -> FileRefusal? {
        var st = stat()
        // A name `lstat` cannot check may be anything, and a launch file rewrite passes it by.
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            return errno == ENOENT ? nil : .unchecked
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return .notRegular }
        if let flags = FileFlags(st.st_flags) { return .flagged(flags) }
        guard faccessat(dir, name, _DELETE_OK, AT_EACCESS | AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? nil : .deleteDenied
        }
        return nil
    }

    /// Throws, before a step replaces or deletes `<root>/<folders...>/<name>`, what keeps it from
    /// doing so: a name there that is not a regular file of the user's, a flag that locks the
    /// file, a list that keeps the user from deleting it, or a name `lstat` cannot check. A
    /// missing file or folder passes. `shown` names a file the texts do not name by its path.
    func requireReplaceable(folders: [String], name: String, shown: Shown? = nil) throws {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        guard dir >= 0 else { return }
        defer { close(dir) }
        let path = Self.joined(folders + [name])
        let place = Self.place(folders + [name])
        if let refusal = Self.replaceProblem(in: dir, name: name) {
            Self.trace.note(root, .fileRefused(path))
            let subject = shown?.subject ?? "`\(place)`"
            let text = Messages.fileRefused(
                subject, shown?.path ?? place, refusal, "replace or delete it")
            throw ToolError(text)
        }
        Self.trace.note(root, .checked(path, .deleteRight))
        Self.trace.note(root, .checked(path, .flags))
    }

    /// Test seam: what the checks and the writer did under one data folder, noted only while a
    /// test watches that folder. Each folder and file is named by its path below the data folder.
    final class Trace: @unchecked Sendable {
        enum Event: Equatable, Sendable {
            /// The folder passed the folder checks.
            case passed(String)
            /// The folder checks refused the folder, or it did not open.
            case refused(String)
            /// An entry in the folder was made, replaced, opened to write or deleted.
            case changed(String)
            /// A file of the writer's temporary shape was made and deleted in the folder, and its
            /// access list read as closed after the writer's clear.
            case proved(String)
            /// A check of one file passed; for `probeList`, the path is the folder's.
            case checked(String, FileCheck)
            /// A check of one file refused it.
            case fileRefused(String)
            /// One file was made, replaced, deleted, added to or opened to lock.
            case file(String, FileChange)
            /// A plan's checks ran.
            case required(String, [Target])
            /// A step began under its plan, and ended.
            case began(String, [Target])
            case ended(String)
        }

        enum FileCheck: String, Sendable {
            case deleteRight, flags, probeList, appendable, lockable, readable
        }

        enum FileChange: String, Sendable {
            case replace, create, delete, append, lockOpen
        }

        private let lock = NSLock()
        private var watched: [String: [Event]] = [:]

        func watch(_ root: URL) {
            lock.lock()
            watched[root.path] = []
            lock.unlock()
        }

        func isWatching(_ root: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return watched[root.path] != nil
        }

        /// The events noted under `root` so far.
        func events(_ root: URL) -> [Event] {
            lock.lock()
            defer { lock.unlock() }
            return watched[root.path] ?? []
        }

        func stop(_ root: URL) {
            lock.lock()
            watched[root.path] = nil
            lock.unlock()
        }

        func note(_ root: URL, _ event: Event) {
            lock.lock()
            defer { lock.unlock() }
            guard watched[root.path] != nil else { return }
            watched[root.path]?.append(event)
        }
    }

    static let trace = Trace()

    /// A folder's path below the data folder, the data folder itself as the empty string.
    static func joined(_ folders: [String]) -> String { folders.joined(separator: "/") }

    /// A folder of the tool's as the person types it.
    static func place(_ folders: [String]) -> String {
        ([dataFolderPlace] + folders).joined(separator: "/")
    }

    /// Test seam: actions a test sets by name, run at one point of a write so a test can act there.
    final class WriteHook: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [String: @Sendable () throws -> Void] = [:]

        /// Sets or, with nil, clears the action for writes of the file or folder `name`.
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

    /// Runs after the temporary file is complete and before the rename.
    static let beforeRename = WriteHook()

    /// Runs in `openFolder` after the folder above `name` passed the checks and before `name` is
    /// made there, the window in which an entry can land on that folder.
    static let beforeMakingFolder = WriteHook()

    /// Runs in `requireWritable` once its probe file is made, by the folder's full path, the
    /// window in which another command's cleanup can delete that file.
    static let afterCheckFileMade = WriteHook()

    /// Creates the data root and the given folders at 0700 without writing a file.
    public func prepare(folders: [String]) throws {
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        close(dir)
    }

    /// Opens the data root, then each folder below it, with `O_NOFOLLOW | O_DIRECTORY`. A folder
    /// that is a link, not owned by the user, wider than 0700, or whose access list lets anyone
    /// but the user in is refused, with a text that names it and its fix. A folder made here has
    /// such inherited entries cleared first. With `strict` off, as `doctor` reads, only a link or
    /// another user's folder is refused, so what is inside a folder it names can be read.
    static func openFolder(
        root: URL, folders: [String], create: Bool, ownerId: uid_t = getuid(), strict: Bool = true
    ) throws -> Int32 {
        let madeRoot = create && mkdir(root.path, 0o700) == 0
        var dir = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else {
            let failure = errno
            if !create && failure == ENOENT { return -1 }
            trace.note(root, .refused(""))
            throw ToolError(Messages.folderRefused(dataFolderPlace, openFailure(failure)))
        }
        var path: [String] = []
        do {
            if madeRoot { _ = shutOthersOut(dir) }
            try check(dir, root: root, path: path, ownerId: ownerId, strict: strict)
            for name in folders {
                try Paths.checkName(name)
                if create { try beforeMakingFolder.run(name) }
                let made = create && mkdirat(dir, name, 0o700) == 0
                if made { trace.note(root, .changed(joined(path))) }
                let next = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    let failure = errno
                    // A folder the user cannot search keeps every name in it from opening.
                    let searchable = faccessat(dir, ".", X_OK, AT_EACCESS) == 0
                    close(dir)
                    dir = -1
                    if !create && failure == ENOENT { return -1 }
                    if failure == EACCES && !searchable {
                        trace.note(root, .refused(joined(path)))
                        throw ToolError(Messages.folderRefused(place(path), .cannotOpen))
                    }
                    path.append(name)
                    trace.note(root, .refused(joined(path)))
                    throw ToolError(Messages.folderRefused(place(path), openFailure(failure)))
                }
                close(dir)
                dir = next
                path.append(name)
                if made { _ = shutOthersOut(dir) }
                try check(dir, root: root, path: path, ownerId: ownerId, strict: strict)
            }
        } catch {
            if dir >= 0 { close(dir) }
            throw error
        }
        return dir
    }

    /// The data folder as the person types it, the start of every place a text names.
    static let dataFolderPlace = "~/.agent-balancer"

    /// Opens an existing file for reading without following a link on the final name.
    static func openFileNoFollow(in dir: Int32, name: String) -> Int32 {
        openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }

    /// Why a command refuses a folder of the tool's.
    public enum FolderRefusal: Equatable, Sendable {
        /// A link, which is never followed, or a file where a folder belongs.
        case linkOrNotFolder
        /// It does not open for the user, such as one with no read or search access.
        case cannotOpen
        /// It is missing and could not be made.
        case cannotMake
        case notYours
        case widerThanPrivate
        /// Its access list lets anyone but the user in, or cannot be read.
        case sharedByAccessList
    }

    /// Why a folder did not open, from the `errno` of the open.
    private static func openFailure(_ failure: Int32) -> FolderRefusal {
        switch failure {
        case ELOOP, ENOTDIR: return .linkOrNotFolder
        case ENOENT: return .cannotMake
        default: return .cannotOpen
        }
    }

    /// The folder checks on the open folder `fd`, which is `path` below the data folder.
    private static func check(
        _ fd: Int32, root: URL, path: [String], ownerId: uid_t, strict: Bool
    ) throws {
        let refusal: FolderRefusal?
        if strict {
            refusal = modeProblem(fd, ownerId: ownerId) ?? listProblem(fd)
        } else {
            var st = stat()
            refusal = fstat(fd, &st) == 0 && st.st_uid == ownerId ? nil : .notYours
        }
        if let refusal {
            trace.note(root, .refused(joined(path)))
            throw ToolError(Messages.folderRefused(place(path), refusal))
        }
        trace.note(root, .passed(joined(path)))
    }

    /// Why the open folder `fd` fails the checks of its owner and mode, or nil when it passes.
    private static func modeProblem(_ fd: Int32, ownerId: uid_t) -> FolderRefusal? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .cannotOpen }
        if st.st_uid != ownerId { return .notYours }
        return st.st_mode & 0o077 == 0 ? nil : .widerThanPrivate
    }

    /// `sharedByAccessList` when the list of the open folder `fd` lets anyone but the user in or
    /// cannot be read.
    private static func listProblem(_ fd: Int32) -> FolderRefusal? {
        AccessList.letsOthersIn(fd) ? .sharedByAccessList : nil
    }

    /// Clears the extended access list of the open file or folder `fd` when it lets anyone but
    /// the user in, as entries inherited from a folder can. Returns whether none is left. A list
    /// that only denies, or only allows the user, is left as it is.
    static func shutOthersOut(_ fd: Int32) -> Bool {
        // A list it cannot read stays, since the owner's own denials on it must be kept.
        guard AccessList.verdict(fd) == .open else { return true }
        guard clearList(fd) else { return false }
        return AccessList.verdict(fd) == .closed
    }

    /// Clears the whole extended access list of the open file or folder `fd`, the owner's own
    /// entries included. Returns whether the clear went through.
    static func clearList(_ fd: Int32) -> Bool {
        guard let empty = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        return acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0
    }

    /// Makes the folder `name` in `dir` at 0700 and clears inherited entries that let anyone but
    /// the user in. A folder that is already there is left for the folder checks to judge.
    @discardableResult
    static func makeFolder(in dir: Int32, _ name: String) -> Bool {
        guard mkdirat(dir, name, 0o700) == 0 else { return false }
        let made = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if made >= 0 {
            _ = shutOthersOut(made)
            close(made)
        }
        return true
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
        let fd = try openLockFile(folders: folders, name: name)
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

    /// Opens the lock file `<root>/<folders...>/<name>` to lock it, making it at 0600 when it is
    /// missing: a regular file of the user's, opened without following a link, with entries that
    /// let anyone but the user in cleared.
    private func openLockFile(folders: [String], name: String) throws -> Int32 {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }
        NoFollowWriter.trace.note(root, .changed(NoFollowWriter.joined(folders)))
        let place = NoFollowWriter.place(folders + [name])
        let path = NoFollowWriter.joined(folders + [name])
        var st = stat()
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT {
            NoFollowWriter.trace.note(root, .file(path, .create))
        }
        NoFollowWriter.trace.note(root, .file(path, .lockOpen))
        // Callers creating the same lock file at once can see a transient ENOENT, so retry a few times.
        var fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var tries = 0
        while fd < 0 && (errno == ENOENT || errno == EEXIST) && tries < 20 {
            tries += 1
            usleep(10_000)
            fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            let failure = errno
            NoFollowWriter.trace.note(root, .fileRefused(path))
            let there = fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0
            // A folder or another user's entry there fails with its own errno, not `ELOOP`.
            if failure == ELOOP
                || (there && ((st.st_mode & S_IFMT) != S_IFREG || st.st_uid != getuid()))
            {
                throw ToolError(Messages.notReplaceable(place))
            }
            if there, let flags = NoFollowWriter.FileFlags(st.st_flags) {
                throw ToolError(Messages.flagged("`\(place)`", place, flags, "open the lock file"))
            }
            throw ToolError(Messages.lockFileNotOpened(place))
        }
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
            close(fd)
            NoFollowWriter.trace.note(root, .fileRefused(path))
            throw ToolError(Messages.notReplaceable(place))
        }
        _ = fchmod(fd, 0o600)
        guard NoFollowWriter.shutOthersOut(fd) else {
            close(fd)
            NoFollowWriter.trace.note(root, .fileRefused(path))
            throw ToolError(Messages.lockFileNotOpened(place))
        }
        return fd
    }

    /// Throws what `acquireLock` would meet on opening the lock file, making it when missing,
    /// and takes no lock.
    public func requireLockable(folders: [String], name: String) throws {
        close(try openLockFile(folders: folders, name: name))
        let path = NoFollowWriter.joined(folders + [name])
        NoFollowWriter.trace.note(root, .checked(path, .lockable))
    }

    /// Throws what `append` would meet at `<root>/<folders...>/<name>`: the folder checks, a file
    /// there that is not a regular file of the user's, or one that does not open for writing,
    /// with a flag that locks it named. A missing file passes; `requireWritable` on the folder
    /// proves one can be made.
    public func requireAppendable(folders: [String], name: String) throws {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }
        let place = NoFollowWriter.place(folders + [name])
        let path = NoFollowWriter.joined(folders + [name])
        guard NoFollowWriter.isReplaceable(in: dir, name: name) else {
            NoFollowWriter.trace.note(root, .fileRefused(path))
            throw ToolError(Messages.notReplaceable(place))
        }
        var st = stat()
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            let fd = openat(dir, name, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                NoFollowWriter.trace.note(root, .fileRefused(path))
                if let flags = NoFollowWriter.FileFlags(st.st_flags) {
                    throw ToolError(Messages.flagged("`\(place)`", place, flags, "write to it"))
                }
                throw ToolError(Messages.fileNotWritable(place))
            }
            close(fd)
        }
        NoFollowWriter.trace.note(root, .checked(path, .appendable))
    }

    /// Makes a fresh folder `<prefix><16 hex>` at 0700 under `<root>/<parent...>` and returns its
    /// name. Before it makes one, a folder of that shape older than `staleAfter` seconds is
    /// removed. Anything else in the parent that is not such a folder refuses the call.
    public func makeScratchFolder(parent: [String], prefix: String, staleAfter: TimeInterval)
        throws -> String
    {
        let dir = try NoFollowWriter.openFolder(root: root, folders: parent, create: true)
        defer { close(dir) }
        NoFollowWriter.trace.note(root, .changed(NoFollowWriter.joined(parent)))
        let now = Date().timeIntervalSince1970
        for entry in try NoFollowWriter.entries(of: dir) {
            var st = stat()
            if fstatat(dir, entry, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                // Another probe removed its own folder after the listing.
                if errno == ENOENT { continue }
                let place = NoFollowWriter.place(parent + [entry])
                throw ToolError(
                    Messages.fileRefused("`\(place)`", place, .unchecked, "remove it"),
                    code: .checkFailed)
            }
            let isFolder = (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
            guard isFolder, NoFollowWriter.isScratchName(entry, prefix: prefix) else {
                throw ToolError(
                    Messages.holdsForeignEntry(NoFollowWriter.place(parent)), code: .checkFailed)
            }
            let modified = Double(st.st_mtimespec.tv_sec)
            if now - modified > staleAfter {
                NoFollowWriter.removeTree(in: dir, name: entry, depth: 0)
            }
        }
        let name = prefix + Paths.randomHex(8)
        guard NoFollowWriter.makeFolder(in: dir, name) else {
            throw ToolError(
                Messages.folderNotWritable(NoFollowWriter.place(parent)), code: .checkFailed)
        }
        return name
    }

    /// Throws what a probe would meet in `<root>/<parent...>`: the checks of `makeScratchFolder`,
    /// and a folder of its shape that cannot be made and removed there. It makes one and removes
    /// it, as each probe does with its own. One it cannot remove loses its own access list and is
    /// removed again before the refusal, which names one that stays.
    public func requireScratchable(parent: [String], prefix: String, staleAfter: TimeInterval)
        throws
    {
        let name = try makeScratchFolder(parent: parent, prefix: prefix, staleAfter: staleAfter)
        // The probe folder takes the inheritable entries of its parent, as each probe's does.
        let usable = isUsableScratch(parent: parent, name: name)
        removeScratchFolder(parent: parent, name: name, prefix: prefix)
        let dir = try NoFollowWriter.openFolder(root: root, folders: parent, create: false)
        func isGone() -> Bool {
            var st = stat()
            return dir >= 0 && fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
        }
        // One whose inherited entry keeps `lstat` out is still the empty folder made here.
        if dir >= 0 && usable == false { _ = unlinkat(dir, name, AT_REMOVEDIR) }
        let gone = isGone()
        var kept = false
        if dir >= 0 && !gone {
            // An inherited entry that denies deleting it goes with the folder's own list.
            let made = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if made >= 0 {
                _ = Self.clearList(made)
                close(made)
            }
            _ = unlinkat(dir, name, AT_REMOVEDIR)
            kept = !isGone()
        }
        if dir >= 0 { close(dir) }
        let path = NoFollowWriter.joined(parent)
        let place = NoFollowWriter.place(parent)
        guard gone else {
            NoFollowWriter.trace.note(root, .refused(path))
            let left = kept ? " " + Messages.checkLeft(place + "/" + name, folder: true) : ""
            throw ToolError(Messages.folderNotWritable(place) + left, code: .checkFailed)
        }
        guard usable else {
            NoFollowWriter.trace.note(root, .refused(path))
            throw ToolError(Messages.folderGivesClosedFiles(place), code: .checkFailed)
        }
        NoFollowWriter.trace.note(root, .checked(path, .probeList))
        NoFollowWriter.trace.note(root, .proved(path))
    }

    /// Whether the probe folder `name` that `makeScratchFolder` made in `<root>/<parent...>` is
    /// one the user can list, search and add to, as `claude` and the removal use it, with an
    /// access list that reads as closed after its clear.
    private func isUsableScratch(parent: [String], name: String) -> Bool {
        guard let dir = try? NoFollowWriter.openFolder(root: root, folders: parent, create: false),
            dir >= 0
        else { return false }
        defer { close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return faccessat(fd, ".", R_OK | W_OK | X_OK, AT_EACCESS) == 0
            && AccessList.verdict(fd) == .closed
    }

    /// Removes a folder made by `makeScratchFolder`, and what is inside it, without following links.
    public func removeScratchFolder(parent: [String], name: String, prefix: String) {
        guard NoFollowWriter.isScratchName(name, prefix: prefix) else { return }
        guard let dir = try? NoFollowWriter.openFolder(root: root, folders: parent, create: false),
            dir >= 0
        else { return }
        defer { close(dir) }
        NoFollowWriter.trace.note(root, .changed(NoFollowWriter.joined(parent)))
        NoFollowWriter.removeTree(in: dir, name: name, depth: 0)
    }

    /// Whether `name` is `prefix` and then 16 of the characters `Paths.randomHex` writes, compared
    /// byte for byte: only ASCII `0-9` and `a-f`, never a look-alike digit or letter in another
    /// script.
    static func isScratchName(_ name: String, prefix: String) -> Bool {
        let bytes = Array(name.utf8)
        let head = Array(prefix.utf8)
        guard bytes.count == head.count + 16, bytes.starts(with: head) else { return false }
        return bytes.dropFirst(head.count).allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
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
    /// Bytes, as `lstat` reports them.
    public var size: Int64 = 0
}

extension NoFollowWriter {
    /// Appends `data` to `<root>/<folders...>/<name>` at mode 0600. The final name is opened with
    /// `O_NOFOLLOW`, and a file that is not a regular file made by you is refused.
    public func append(_ data: Data, folders: [String], name: String) throws {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: true)
        defer { close(dir) }
        NoFollowWriter.trace.note(root, .changed(NoFollowWriter.joined(folders)))
        let path = NoFollowWriter.joined(folders + [name])
        var before = stat()
        if fstatat(dir, name, &before, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT {
            NoFollowWriter.trace.note(root, .file(path, .create))
        }
        NoFollowWriter.trace.note(root, .file(path, .append))
        let fd = openat(dir, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolError("Could not write \(name).") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
            throw ToolError("Refused to write \(name): it is not a regular file made by you.")
        }
        _ = fchmod(fd, 0o600)
        guard NoFollowWriter.shutOthersOut(fd) else { throw ToolError("Could not write \(name).") }
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
        let dir = try NoFollowWriter.openFolder(
            root: root, folders: folders, create: false, strict: strict)
        if dir < 0 { return [] }
        defer { close(dir) }
        return try NoFollowWriter.entries(of: dir).sorted()
    }

    /// `lstat` of `<root>/<folders...>/<name>`, or nil when it is missing. An entry `lstat` cannot
    /// check reads as missing here too; `checkedInfo` tells the two apart.
    public func info(folders: [String], name: String) throws -> OwnFileInfo? {
        do {
            return try checkedInfo(folders: folders, name: name)
        } catch is UncheckedEntry {
            return nil
        }
    }

    /// An entry that `lstat` cannot check for a reason other than a missing name, such as one in
    /// a folder the user cannot search. It may be anything, a file with a token included.
    struct UncheckedEntry: Error {}

    /// `lstat` of `<root>/<folders...>/<name>`, or nil when it is missing. It throws
    /// `UncheckedEntry` when `lstat` fails for another reason, so a caller that looks for a token
    /// never reads such an entry as missing.
    func checkedInfo(folders: [String], name: String) throws -> OwnFileInfo? {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: folders, create: false)
        if dir < 0 { return nil }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw UncheckedEntry()
        }
        return OwnFileInfo(
            isRegularFile: (st.st_mode & S_IFMT) == S_IFREG, ownedByUser: st.st_uid == getuid(),
            mode: Int(st.st_mode & 0o777),
            modified: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)),
            size: Int64(st.st_size))
    }

    /// How many names directly in `<root>/<folders...>` that `shape` takes cannot be checked with
    /// `lstat`, such as in a folder the user cannot search. Nothing is opened.
    func uncheckedCount(folders: [String], of shape: (String) -> Bool) -> Int {
        let names = (try? listNames(folders: folders)) ?? []
        return names.filter { name in
            guard shape(name) else { return false }
            do {
                _ = try checkedInfo(folders: folders, name: name)
                return false
            } catch {
                return true
            }
        }.count
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
        NoFollowWriter.trace.note(root, .changed(NoFollowWriter.joined(folders)))
        NoFollowWriter.trace.note(root, .file(NoFollowWriter.joined(folders + [name]), .delete))
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
        Self.trace.note(root, .changed(Self.joined(folders)))
        let value = try PropertyListSerialization.data(
            fromPropertyList: "com.apple.backupd", format: .binary, options: 0)
        let ok = value.withUnsafeBytes {
            fsetxattr(dir, Self.backupExcludeName, $0.baseAddress, value.count, 0, 0) == 0
        }
        if !ok { throw ToolError(Messages.notExcludedFromBackup(Self.place(folders))) }
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
        Self.trace.note(root, .changed(Self.joined(parent)))
        return unlinkat(dir, name, AT_REMOVEDIR) == 0
    }

    /// Whether the data folder is there, passes the folder checks, and holds nothing.
    public func rootIsEmpty() -> Bool {
        guard let dir = try? NoFollowWriter.openFolder(root: root, folders: [], create: false),
            dir >= 0
        else { return false }
        defer { close(dir) }
        return (try? NoFollowWriter.entries(of: dir))?.isEmpty ?? false
    }

    /// Removes the data folder itself only while it is empty and a real folder made by the user.
    /// `rmdir` never follows a link and never removes a folder with anything in it. Returns
    /// whether it was removed.
    public func removeRootIfEmpty() -> Bool {
        var st = stat()
        guard lstat(root.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid()
        else { return false }
        return rmdir(root.path) == 0
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
        Self.trace.note(root, .changed(Self.joined(folders)))
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

    /// What `lstat` shows at a name where a folder of the tool belongs.
    public enum FolderEntry: Equatable, Sendable {
        case missing
        /// A real folder owned by the user. Opening it can still refuse it for its mode.
        case folder
        /// A link, a file, another user's folder or anything else. It is never opened or followed.
        case other
    }

    /// What `lstat` shows at `<root>/<parent...>/<name>`. Nothing there is opened.
    public func folderEntry(parent: [String], name: String) throws -> FolderEntry {
        try Paths.checkName(name)
        let dir = try NoFollowWriter.openFolder(root: root, folders: parent, create: false)
        if dir < 0 { return .missing }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return .missing }
            throw ToolError("Could not check \(name).")
        }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid() ? .folder : .other
    }

    /// What keeps a folder of the user's from passing the folder checks, or keeps `lstat` from
    /// telling what is there.
    public enum FolderProblem: Equatable, Sendable {
        /// Its group or others have some access.
        case widerThanPrivate
        /// Its access list lets another user or group in, or cannot be read.
        case sharedByAccessList
        /// It does not open for the user, such as one with no read or search access.
        case cannotOpen
        /// `lstat` cannot check it, such as one whose access list denies its owner `readattr`,
        /// so it may be a link, a file or a folder.
        case cannotCheck
    }

    /// What keeps the real folder of the user's at `<root>/<parent...>/<name>` from passing the
    /// folder checks, the same checks as `placeEntry`, or nil when it passes, is missing, or is not
    /// a real folder of the user's (a link, a file or another user's folder, which callers count
    /// and never open). An entry `lstat` cannot check there is `cannotCheck`.
    public func folderProblem(parent: [String], name: String) -> FolderProblem? {
        if case .problem(let problem) = placeEntry(parent: parent, name: name) { return problem }
        return nil
    }

    /// What `lstat` shows where a folder of the tool belongs: the data folder, or a folder in it.
    public enum PlaceEntry: Equatable, Sendable {
        case missing
        /// A real folder of the user's that passes the folder checks.
        case folder
        case link
        /// A file or anything else that is neither a folder nor a link.
        case notFolder
        /// A folder another user owns.
        case notYours
        case problem(FolderProblem)
    }

    /// What is at the data folder's own path. A link there is never followed, and only a folder of
    /// the user's is opened, to check it.
    public func rootEntry() -> PlaceEntry {
        var st = stat()
        guard lstat(root.path, &st) == 0 else {
            return errno == ENOENT ? .missing : .problem(.cannotCheck)
        }
        return place(st, folders: [])
    }

    /// What is at `<root>/<parent...>/<name>`, told apart as `rootEntry` tells the data folder.
    /// A link there is never followed, and only a folder of the user's is opened, to check it.
    public func placeEntry(parent: [String], name: String) -> PlaceEntry {
        guard
            let dir = try? NoFollowWriter.openFolder(
                root: root, folders: parent, create: false, strict: strict)
        else { return .problem(.cannotOpen) }
        if dir < 0 { return .missing }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .missing : .problem(.cannotCheck)
        }
        return place(st, folders: parent + [name])
    }

    private func place(_ st: stat, folders: [String]) -> PlaceEntry {
        let kind = st.st_mode & S_IFMT
        if kind == S_IFLNK { return .link }
        if kind != S_IFDIR { return .notFolder }
        if st.st_uid != getuid() { return .notYours }
        if st.st_mode & 0o077 != 0 { return .problem(.widerThanPrivate) }
        if isSharedByAccessList(folders) { return .problem(.sharedByAccessList) }
        guard
            let dir = try? NoFollowWriter.openFolder(
                root: root, folders: folders, create: false, strict: strict)
        else { return .problem(.cannotOpen) }
        guard dir >= 0 else { return .missing }
        defer { close(dir) }
        // A folder opens with read access alone, and only search access lets a name in it be
        // checked.
        guard faccessat(dir, ".", R_OK | X_OK, AT_EACCESS) == 0 else {
            return .problem(.cannotOpen)
        }
        return .folder
    }

    /// Whether the folder `<root>/<folders...>` has an access list that lets anyone but the user
    /// in, or one that cannot be read. The folders above it are opened as `openFolder` opens them;
    /// the folder itself is opened with `O_NOFOLLOW` only to read its list, so a folder the folder
    /// checks refuse for its list alone is told apart. One that does not open answers no.
    private func isSharedByAccessList(_ folders: [String]) -> Bool {
        let fd: Int32
        if let last = folders.last {
            guard
                let parent = try? NoFollowWriter.openFolder(
                    root: root, folders: Array(folders.dropLast()), create: false,
                    strict: strict),
                parent >= 0
            else { return false }
            fd = openat(parent, last, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(parent)
        } else {
            fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return AccessList.letsOthersIn(fd)
    }

    /// What `rootEntry` says, except that a data folder `lstat` cannot check is opened as the
    /// folder checks open it, so one whose list keeps `lstat` out reads as `sharedByAccessList`.
    public func rootEntryOpening() -> PlaceEntry {
        let entry = rootEntry()
        guard entry == .problem(.cannotCheck) else { return entry }
        return opened(open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) ?? entry
    }

    /// What `placeEntry` says, except that an entry `lstat` cannot check is opened without
    /// following a link, as the folder checks open it: a folder of the user's whose list keeps
    /// `lstat` out, such as one that denies the user `readsecurity`, reads as `sharedByAccessList`.
    public func placeEntryOpening(parent: [String], name: String) -> PlaceEntry {
        let entry = placeEntry(parent: parent, name: name)
        guard entry == .problem(.cannotCheck),
            let dir = try? NoFollowWriter.openFolder(
                root: root, folders: parent, create: false, strict: strict),
            dir >= 0
        else { return entry }
        defer { close(dir) }
        return opened(openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) ?? entry
    }

    /// What `doctor` says about the folder `<root>/<parent...>/<name>`, or about the data folder
    /// when `name` is nil, and whether what is in it can be read. A folder that passes gives no
    /// line. One refused for its mode, its access list or both gives its line, and what is in it
    /// is read, so one run names that too. One that cannot be opened or checked, and a link, a
    /// file or another user's folder, which every command refuses without opening it, gives its
    /// line and is not read.
    func doctorVerdict(parent: [String], name: String?) -> (line: String?, readable: Bool) {
        let path = name.map { parent + [$0] } ?? []
        let entry = name.map { placeEntryOpening(parent: parent, name: $0) } ?? rootEntryOpening()
        let place = Self.place(path)
        switch entry {
        case .folder:
            return (nil, true)
        case .problem(.widerThanPrivate):
            let shared = isSharedByAccessList(path)
            return (
                Messages.doctorFolderProblem(place, .widerThanPrivate, alsoShared: shared), true
            )
        case .problem(.sharedByAccessList):
            return (Messages.doctorFolderShared(place), true)
        case .problem(let problem):
            return (Messages.doctorFolderProblem(place, problem), false)
        default:
            return (Messages.doctorFolderNotUsed(place, entry), false)
        }
    }

    /// What keeps a file of the tool's from being private by its access list.
    public enum FileListProblem: Equatable, Sendable {
        /// A regular file of the user's whose list lets another user or group in, or cannot be
        /// read.
        case shared
        /// `lstat` cannot check the name in a folder the user can search, as when the file's own
        /// list denies the user `readattr`, so that list cannot be read either.
        case unchecked
    }

    /// What the access list of `<root>/<folders...>/<name>` keeps from being private, read by
    /// path without opening the file, or nil when the folders do not pass the folder checks, or
    /// the name is missing, is not a regular file of the user's, or is private.
    public func fileListProblem(folders: [String], name: String) -> FileListProblem? {
        guard (try? Paths.checkName(name)) != nil,
            let dir = try? NoFollowWriter.openFolder(
                root: root, folders: folders, create: false, strict: strict),
            dir >= 0
        else { return nil }
        defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno != ENOENT && faccessat(dir, ".", X_OK, AT_EACCESS) == 0 ? .unchecked : nil
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return nil }
        let path = folders.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent(name).path
        return AccessList.letsOthersIn(path: path) ? .shared : nil
    }

    /// The folder checks' verdict on the handle `fd`, which it closes, or nil when it did not
    /// open, is not a folder of the user's, or passes.
    private func opened(_ fd: Int32) -> PlaceEntry? {
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid()
        else { return nil }
        if st.st_mode & 0o077 != 0 { return .problem(.widerThanPrivate) }
        return AccessList.letsOthersIn(fd) ? .problem(.sharedByAccessList) : nil
    }

    /// Whether the names `a` and `b` in `<root>/<parent...>` lead to one entry, as `STATE` and
    /// `state` do on a volume that ignores case. `lstat` only; nothing is opened or followed.
    public func isSameEntry(parent: [String], _ a: String, _ b: String) -> Bool {
        guard let dir = try? NoFollowWriter.openFolder(root: root, folders: parent, create: false),
            dir >= 0
        else { return false }
        defer { close(dir) }
        var first = stat()
        var second = stat()
        guard fstatat(dir, a, &first, AT_SYMLINK_NOFOLLOW) == 0,
            fstatat(dir, b, &second, AT_SYMLINK_NOFOLLOW) == 0
        else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
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
        Self.trace.note(root, .changed(Self.joined(folders)))
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
        guard modeProblem(parent, ownerId: getuid()) == nil else {
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

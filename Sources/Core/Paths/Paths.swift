import Foundation

/// Folder handling shared by the no-follow reader and writer, and facts about files.
public enum Paths {
    static func checkName(_ name: String) throws {
        let bad = name.isEmpty || name == "." || name == ".." || name.contains("/")
        if bad { throw ToolError("Refused an unsafe file name.") }
    }

    static func randomHex(_ bytes: Int) -> String { hex(randomBytes(bytes)) }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// How a random part of a name is spelled: two lowercase hex digits per byte.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes read two digits at a time from `text`, or nil when it is not pairs of hex
    /// digits. `hex` may spell them another way (`AB`, `+a`), so a name rule compares the two.
    static func bytes(fromHex text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var start = 0
        while start < digits.count {
            let pair = String(decoding: digits[start..<start + 2], as: UTF8.self)
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            bytes.append(byte)
            start += 2
        }
        return bytes
    }

    /// `name` with its letter case folded the way a volume that ignores case compares names, so
    /// `Pool-a.json`, a long s, a sharp s or a ligature give the spelling such a volume takes.
    /// Characters Unicode marks as default ignorable go first, since a Mac OS Extended volume
    /// ignores some of them in a name, such as a zero-width joiner.
    static func caseFolded(_ name: String) -> String {
        let kept: [Unicode.Scalar] = name.unicodeScalars.filter {
            !$0.properties.isDefaultIgnorableCodePoint
        }
        let plain = String(String.UnicodeScalarView(kept))
        return plain.folding(options: .caseInsensitive, locale: nil)
    }
}

/// Folder and file names under the data folder (docs/ARCHITECTURE.md section 13).
public enum Layout {
    public static let readingsFolders = ["state", "readings"]
    public static let locksFolders = ["locks"]
    public static let probeFolders = ["probe"]
    public static let probeFolderPrefix = "p-"
    public static let stateFolders = ["state"]
    public static let logsFolders = ["logs"]
    public static let backupsFolders = ["backups"]
    public static let pickLockName = "pick.lock"
    public static let linksLockName = "links.lock"
    public static let leasesName = "leases.json"
    public static let picksLogName = "picks.log"
    public static let settingsSeenName = "settings-seen.json"
    public static let logName = "agent-balancer.log"

    public static func readingName(_ label: String) -> String { label + ".json" }
    public static func lockName(_ label: String) -> String { "probe-" + label + ".lock" }
}

/// What the runner needs to know about a path before it trusts it.
public struct FileFacts: Sendable {
    public let realPath: String
    public let ownerIsUserOrRoot: Bool
    /// False when root owns it and the tool runs as another user, so only an administrator can
    /// change its mode or its access list.
    public let ownerIsUser: Bool
    public let writableByOthers: Bool
    /// Its access list gives another user or group a right other than reading, running, listing,
    /// searching and reading its attributes or list, inherited or not, or cannot be read.
    public let listLetsOthersChange: Bool
    /// The flags that keep its list from being changed, such as `uchg`, or nil when none is set.
    public let flags: NoFollowWriter.FileFlags?
    public let isRegularFile: Bool
    public let isExecutable: Bool

    /// What a look at a path found.
    public enum Lookup: Sendable {
        case found(FileFacts)
        /// Nothing that can run is there: an entry on the way is missing or not a folder, or its
        /// links loop.
        case missing
        /// Something is there that cannot be checked, for the reason `Stop` gives.
        case unchecked(Stop)
    }

    /// Where a lookup that cannot be finished stops, and who can clear the access list that
    /// stops it with `chmod -N`, when that is known to let the lookup through.
    public enum Stop: Equatable, Sendable {
        /// The user cannot search the folder at `path`. `unlocking` holds the user's flags that
        /// lock it, by the names `chflags` takes, which must be cleared before `chmod -N` runs.
        case unsearchable(path: String, clearedBy: Clearer?, unlocking: [String])
        /// The user cannot read the entry at `path`: its attributes, or what it holds when it is
        /// a link, which `isLink` says.
        case unreadable(path: String, isLink: Bool, clearedBy: Clearer?)
        /// The lookup of `path` fails where no step can be named.
        case unknown(path: String)
    }

    /// Who can run the `chmod -N` that clears an entry's access list.
    public enum Clearer: Equatable, Sendable {
        case user
        case root
    }

    /// Follows links. Returns nil when the path does not exist, does not resolve or cannot be
    /// checked.
    public static func inspect(_ url: URL) -> FileFacts? {
        guard case .found(let facts) = look(url) else { return nil }
        return facts
    }

    /// Follows links, as `inspect` does, and tells a path with nothing there from one it cannot
    /// check, and where that check stops, so a check of what is there can fail closed.
    public static func look(_ url: URL) -> Lookup {
        errno = 0
        guard let resolved = realpath(url.path, nil) else {
            if [ENOENT, ENOTDIR, ELOOP].contains(errno) { return .missing }
            return walk(url.path)
        }
        defer { free(resolved) }
        let real = String(cString: resolved)
        var st = stat()
        guard stat(real, &st) == 0 else { return walk(real) }
        let uid = getuid()
        let kind = st.st_mode & S_IFMT
        return .found(
            FileFacts(
                realPath: real,
                ownerIsUserOrRoot: st.st_uid == uid || st.st_uid == 0,
                ownerIsUser: st.st_uid == uid,
                writableByOthers: st.st_mode & 0o022 != 0,
                listLetsOthersChange: AccessList.letsOthersChange(path: real),
                flags: NoFollowWriter.FileFlags(st.st_flags),
                isRegularFile: kind == S_IFREG,
                isExecutable: access(real, X_OK) == 0))
    }

    /// Where a lookup of `path` that `realpath` or `stat` could not finish stops, found one name
    /// at a time with `lstat`, and with `readlink` for a link, which needs no right on what the
    /// link points to: the first folder the user cannot search, or the first entry whose
    /// attributes the user cannot read. A missing entry, a path through a file or a loop of
    /// links leaves nothing that can run.
    private static func walk(_ path: String) -> Lookup {
        guard path.hasPrefix("/") else { return .unchecked(.unknown(path: path)) }
        var rest = path.split(separator: "/").map(String.init)
        var folder = ""
        var links = 0
        while !rest.isEmpty {
            let name = rest.removeFirst()
            if name == "." { continue }
            if name == ".." {
                folder = String(folder[..<(folder.lastIndex(of: "/") ?? folder.startIndex)])
                continue
            }
            let next = folder + "/" + name
            var st = stat()
            guard lstat(next, &st) == 0 else {
                if [ENOENT, ENOTDIR].contains(errno) { return .missing }
                let above = folder.isEmpty ? "/" : folder
                errno = 0
                if access(above, X_OK) != 0 {
                    let error = errno
                    let read = stat(above, &st) == 0
                    return .unchecked(unsearchable(above, error: error, st: read ? st : nil))
                }
                return .unchecked(unreadable(next))
            }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                links += 1
                guard links <= Int(MAXSYMLINKS) else { return .missing }
                guard let target = linkTarget(next).target else {
                    return .unchecked(.unreadable(path: next, isLink: true, clearedBy: nil))
                }
                if target.hasPrefix("/") { folder = "" }
                rest = target.split(separator: "/").map(String.init) + rest
            case S_IFDIR:
                folder = next
            default:
                guard rest.isEmpty else { return .missing }
                folder = next
            }
        }
        return .unchecked(.unknown(path: path))
    }

    /// The folder `path` the user cannot search, from the error `access` gave and the folder's
    /// `stat`, nil when that failed. The user's `chmod -N` clears it only when the user owns it
    /// and its mode lets the owner search it, so only its access list can deny it, after the
    /// `chflags` that clears a user flag that locks it, which `chmod -N` cannot pass. A system
    /// flag, which only an administrator can clear, or a `stat` that failed leaves no command.
    static func unsearchable(_ path: String, error: Int32, st: stat?) -> Stop {
        let flags = st.flatMap { NoFollowWriter.FileFlags($0.st_flags) }
        guard error == EACCES, let st, st.st_uid == getuid(), st.st_mode & S_IXUSR != 0,
            flags?.system != true
        else { return .unsearchable(path: path, clearedBy: nil, unlocking: []) }
        return .unsearchable(path: path, clearedBy: .user, unlocking: flags?.user ?? [])
    }

    /// The entry `path` whose attributes the user cannot read. Opened for events only, without
    /// following a link, it still gives its owner, type and flags when the user may read it;
    /// `chmod -N` then clears it for its owner, unless a flag locks it or it is a link.
    private static func unreadable(_ path: String) -> Stop {
        let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            // Anything but a link answers `readlink` with EINVAL, whatever its list denies.
            let link = linkTarget(path).error != EINVAL
            return .unreadable(path: path, isLink: link, clearedBy: nil)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, NoFollowWriter.FileFlags(st.st_flags) == nil else {
            return .unreadable(path: path, isLink: false, clearedBy: nil)
        }
        let clearer: Clearer? = st.st_uid == getuid() ? .user : st.st_uid == 0 ? .root : nil
        return .unreadable(path: path, isLink: false, clearedBy: clearer)
    }

    /// What the link at `path` holds, or nil with the error of `readlink` when it cannot be read.
    private static func linkTarget(_ path: String) -> (target: String?, error: Int32) {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        errno = 0
        let count = buffer.withUnsafeMutableBufferPointer { space in
            space.baseAddress.map { readlink(path, $0, space.count) } ?? -1
        }
        let error = errno
        guard count > 0 else { return (nil, error) }
        let bytes = buffer[0..<count].map { UInt8(bitPattern: $0) }
        return (String(decoding: bytes, as: UTF8.self), 0)
    }
}

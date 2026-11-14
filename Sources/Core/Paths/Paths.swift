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
    public let writableByOthers: Bool
    public let isRegularFile: Bool
    public let isExecutable: Bool

    /// Follows links. Returns nil when the path does not exist or does not resolve.
    public static func inspect(_ url: URL) -> FileFacts? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        let real = String(cString: resolved)
        var st = stat()
        guard stat(real, &st) == 0 else { return nil }
        let uid = getuid()
        return FileFacts(
            realPath: real,
            ownerIsUserOrRoot: st.st_uid == uid || st.st_uid == 0,
            writableByOthers: st.st_mode & 0o022 != 0,
            isRegularFile: (st.st_mode & S_IFMT) == S_IFREG,
            isExecutable: access(real, X_OK) == 0)
    }
}

import Foundation

/// The metadata of one path from a single stat call. Nothing is opened or read, so taking a stamp
/// of a file never touches its content.
public struct FileStamp: Codable, Equatable, Sendable {
    public var present: Bool
    public var isRegular: Bool
    public var device: Int64
    public var inode: UInt64
    public var size: Int64
    public var mtimeSeconds: Int64
    public var mtimeNanos: Int64
    public var ctimeSeconds: Int64
    public var ctimeNanos: Int64

    public static let absent = FileStamp(
        present: false, isRegular: false, device: 0, inode: 0, size: 0, mtimeSeconds: 0,
        mtimeNanos: 0, ctimeSeconds: 0, ctimeNanos: 0)

    /// A missing path is `absent`. Any other failure throws, so a caller never treats an
    /// unknown state as a known one.
    public static func take(_ path: String, followLinks: Bool) throws -> FileStamp {
        var st = stat()
        let result = followLinks ? stat(path, &st) : lstat(path, &st)
        if result != 0 {
            if errno == ENOENT || errno == ENOTDIR { return .absent }
            throw ToolError("Could not check \(URL(fileURLWithPath: path).lastPathComponent).")
        }
        return FileStamp(
            present: true, isRegular: (st.st_mode & S_IFMT) == S_IFREG, device: Int64(st.st_dev),
            inode: UInt64(st.st_ino), size: Int64(st.st_size),
            mtimeSeconds: Int64(st.st_mtimespec.tv_sec), mtimeNanos: Int64(st.st_mtimespec.tv_nsec),
            ctimeSeconds: Int64(st.st_ctimespec.tv_sec), ctimeNanos: Int64(st.st_ctimespec.tv_nsec))
    }
}

/// The stamp of a settings file: the path itself (no link followed) and what it resolves to. The
/// change time is part of each, because a write moves it and no ordinary call puts it back.
public struct SettingsStamp: Codable, Equatable, Sendable {
    public var link: FileStamp
    public var target: FileStamp

    public static func take(_ url: URL) throws -> SettingsStamp {
        SettingsStamp(
            link: try FileStamp.take(url.path, followLinks: false),
            target: try FileStamp.take(url.path, followLinks: true))
    }

    /// True when nothing is there, or the path resolves to a regular file. A folder, a link that
    /// goes nowhere and a special file are not usable.
    public var isRegularOrAbsent: Bool {
        if !link.present { return !target.present }
        return target.present && target.isRegular
    }
}

import Foundation

/// Folder handling shared by the no-follow reader and writer, and facts about files.
public enum Paths {
    static func checkName(_ name: String) throws {
        let bad = name.isEmpty || name == "." || name == ".." || name.contains("/")
        if bad { throw ToolError("Refused an unsafe file name.") }
    }

    static func randomHex(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in
            String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
        }
        .joined()
    }
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

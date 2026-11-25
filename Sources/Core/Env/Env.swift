import Foundation

/// The one place the tool reads its own environment.
public enum Env {
    public static func snapshot() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// The real user's home folder as the user database names it, or nil when it names none. No
    /// environment variable moves it, `CFFIXED_USER_HOME` included.
    static func userDatabaseHome() -> String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }
}

/// Where the tool runs: the home folder and the environment it was started with.
/// Tests build one directly so no test touches the real home or the process environment.
public struct ToolContext: Sendable {
    public let home: URL
    public let ambient: [String: String]
    /// The user id a folder or link target must belong to. It is the real user's; a test sets
    /// another to stand in for a foreign owner.
    public let ownerId: uid_t

    public init(home: URL, ambient: [String: String], ownerId: uid_t = getuid()) {
        self.home = home
        self.ambient = ambient
        self.ownerId = ownerId
    }

    /// The context every command and the menu app start from, before they read or write a file.
    /// An unset or empty HOME falls back to the home folder the user database names. A HOME or
    /// fallback that `isUsableHome` refuses throws, and so does a database that names no home.
    public static func current() throws -> ToolContext {
        try current(environment: Env.snapshot())
    }

    /// `userDatabaseHome` stands in for the user database, so a test can name the fallback.
    static func current(
        environment: [String: String], userDatabaseHome: () -> String? = Env.userDatabaseHome
    ) throws -> ToolContext {
        let named = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        guard let home = named ?? userDatabaseHome(), isUsableHome(home) else {
            throw homeRefusal
        }
        return ToolContext(home: URL(fileURLWithPath: home), ambient: environment)
    }

    /// The one HOME rule, which the render flags share: an absolute path with no `..` segment,
    /// checked as written. A relative HOME would move the data folder with the current folder.
    static func isUsableHome(_ home: String) -> Bool {
        home.hasPrefix("/") && !home.split(separator: "/").contains("..")
    }

    static let homeRefusal = ToolError(
        "HOME must be an absolute path with no .. segment. Set it to the full path of your home folder and try again. Nothing was read or written."
    )

    public var dataRoot: URL { home.appendingPathComponent(".agent-balancer") }

    /// Claude Code's default config folder.
    public var defaultClaudeFolder: URL { home.appendingPathComponent(".claude") }

    /// True when the tool runs inside a chat's tool shell (present with any value, empty included).
    public var inChatShell: Bool { ambient["CLAUDE_CODE_CHILD_SESSION"] != nil }

    /// A path with the home folder written as `~`, for output that must not carry a user name.
    public func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}

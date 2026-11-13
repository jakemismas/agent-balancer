import Foundation

/// The one place the tool reads its own environment.
public enum Env {
    public static func snapshot() -> [String: String] {
        ProcessInfo.processInfo.environment
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

    public static func current() -> ToolContext {
        let env = Env.snapshot()
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return ToolContext(home: URL(fileURLWithPath: home), ambient: env)
    }

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

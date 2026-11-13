import Foundation

/// The two environments a child process can get (docs/ARCHITECTURE.md section 6.2).
public enum ChildEnvironment {
    static let fixedPathTail = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let proxyNames = [
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE",
    ]
    static let passNames = ["USER", "LOGNAME", "LANG", "TMPDIR"]

    /// True when `folder` is the default Claude Code folder, which never gets `CLAUDE_CONFIG_DIR`.
    static func isDefaultFolder(_ folder: URL, context: ToolContext) -> Bool {
        func plain(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        return folder.standardizedFileURL.path
            == context.defaultClaudeFolder.standardizedFileURL.path
            || plain(folder) == plain(context.defaultClaudeFolder)
    }

    /// Allowlist for probe and `auth status` children. Everything else is dropped, including the
    /// protected group and an ambient `CLAUDE_CONFIG_DIR`.
    public static func probe(
        context: ToolContext, claudeFolder: URL, configDir: URL?, passProxyEnv: Bool
    ) -> [String: String] {
        var env: [String: String] = [
            "PATH": claudeFolder.path + ":" + fixedPathTail,
            "HOME": context.home.path,
        ]
        for (name, value) in context.ambient {
            let allowed = passNames.contains(name) || name.hasPrefix("LC_")
            if allowed && !ProtectedEnv.isProtected(name) { env[name] = value }
        }
        if passProxyEnv {
            for name in proxyNames { if let v = context.ambient[name] { env[name] = v } }
        }
        if let dir = configDir, !isDefaultFolder(dir, context: context) {
            env[ProtectedEnv.configDirVariable] = dir.path
        }
        return env
    }

    /// For a person's own interactive launch: the user's environment minus the protected group,
    /// with the terminal attached. `TERM` and `SSH_AUTH_SOCK` pass through.
    public static func person(context: ToolContext, configDir: URL?) -> [String: String] {
        var env = context.ambient.filter { !ProtectedEnv.isProtected($0.key) }
        if let dir = configDir, !isDefaultFolder(dir, context: context) {
            env[ProtectedEnv.configDirVariable] = dir.path
        }
        return env
    }
}

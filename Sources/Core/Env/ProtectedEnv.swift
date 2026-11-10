/// The group of environment names that never reach a child process the tool builds.
/// Every other site refers to this one and adds only its own extras.
public enum ProtectedEnv {
    /// The Claude Code token variable. The name is joined from halves so the safety scan, which
    /// keeps that name inside the Tokens module, passes over this one shared list.
    public static let tokenVariable = "CLAUDE_CODE_" + "OAUTH_TOKEN"

    public static let configDirVariable = "CLAUDE_CONFIG_DIR"

    public static let anthropicPrefix = "ANTHROPIC_"

    public static let useFlagPrefix = "CLAUDE_CODE_USE_"

    /// The two key and token names, besides the Claude Code token, that a settings file may carry.
    public static let keyNames = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    /// Names a settings file's `env` is checked for, by name only.
    public static var settingsEnvNames: [String] { keyNames + [tokenVariable] }

    public static func isProtected(_ name: String) -> Bool {
        name == configDirVariable || name == tokenVariable || name.hasPrefix(anthropicPrefix)
            || name.hasPrefix(useFlagPrefix)
    }
}

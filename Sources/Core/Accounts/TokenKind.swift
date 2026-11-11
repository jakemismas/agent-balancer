import Foundation

/// The `token` kind, for probing only in this version.
enum TokenKind {
    /// A token account is probed with its token file named in `--settings`. The tool passes the
    /// path and never reads the token, and no `CLAUDE_CONFIG_DIR` is set.
    static func probeContext(account: Account, context: ToolContext) throws -> ProbeContext {
        let facts = try TokenPaths.facts(context: context, label: account.label)
        guard facts.exists else {
            throw ToolError(
                "Account '\(Display.safe(account.label))' has no token file.", code: .tokenMissing)
        }
        guard facts.isPrivate else {
            throw ToolError(
                "Account '\(Display.safe(account.label))': the token file must be a regular file owned by you with mode 0600.",
                code: .tokenMissing)
        }
        let path = try TokenPaths.fileURL(context: context, label: account.label).path
        return ProbeContext(
            extraArguments: ["--settings", path], configDir: nil, callsAfterProbeHook: true)
    }
}

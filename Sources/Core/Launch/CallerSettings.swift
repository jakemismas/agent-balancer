import Foundation

/// The settings a caller hands to `pick`, checked against the allowlist of
/// docs/ARCHITECTURE.md section 4A.2. A refusal names the offending key and never a value.
public struct CallerSettings: Sendable {
    public static let maxBytes = 16_384
    static let envNamePattern = #"\A[A-Z][A-Z0-9_]{0,63}\z"#
    /// Names that are never allowed in `env`, whatever the config lists. The protected group and
    /// the prefix and suffix rules are checked in `isForbiddenEnvName`.
    static let forbiddenEnvNames: Set<String> = [
        "PATH", "HOME", "NODE_OPTIONS", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "BASH_ENV", "ENV",
        "ZDOTDIR", "SHELL", "NODE_PATH", "NODE_TLS_REJECT_UNAUTHORIZED", "SSL_CERT_DIR",
        "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "TMPDIR", "PYTHONSTARTUP", "PYTHONPATH",
        "RUBYOPT", "RUBYLIB", "PERL5OPT", "PERL5LIB", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        "IFS", "PS4", "PROMPT_COMMAND", "EDITOR", "VISUAL", "PAGER", "SSLKEYLOGFILE",
        "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS",
    ]
    /// These could run code beside the token or point a tool at another credential.
    static let forbiddenEnvPrefixes = [
        "DYLD_", "LD_", "GIT_", "NODE_", "BASH_", "LC_", "NPM_", "BUN_", "DENO_", "SSH_", "AWS_",
        "GOOGLE_", "AZURE_", "OTEL_", "OPENSSL_",
    ]
    /// No key here can switch hooks off, run a command or change permissions.
    static let allowedSettingsKeys: Set<String> = ["env", "crossSessionInbound"]
    /// The key `merged` writes beside the caller's keys.
    static let hooksKey = "disableAllHooks"
    static let forbiddenNestedKeys: Set<String> = ["__proto__", "constructor", "prototype"]
    static let maxDepth = 8

    /// Canonical JSON of the checked object. `{}` when the caller gave none.
    let json: Data

    public static let none = CallerSettings(json: Data("{}".utf8))

    /// These redirect the account, run code or tie a session to its parent; `CLAUDE_ROLE` is fine.
    static func isForbiddenEnvName(_ name: String) -> Bool {
        ProtectedEnv.isProtected(name) || ChildEnvironment.launchDropNames.contains(name)
            || name.hasPrefix(ProtectedEnv.codePrefix)
            || name.hasPrefix(LaunchFiles.accountVariablePrefix)
            || forbiddenEnvNames.contains(name) || name.uppercased().hasSuffix("_PROXY")
            || forbiddenEnvPrefixes.contains { name.hasPrefix($0) }
            || ProtectedEnv.launchRefusedNames.contains(name)
            || ProtectedEnv.launchRefusedPrefixes.contains { name.hasPrefix($0) }
    }

    /// True when `key` may be listed in `launch.settingsKeys`.
    static func isAllowedSettingsKey(_ key: String) -> Bool { allowedSettingsKeys.contains(key) }

    /// One check for config load and pick time, so the two can never disagree.
    static func checkLaunchLists(_ launch: LaunchSettings) throws {
        if launch.settingsKeys.contains(where: { !isAllowedSettingsKey($0) }) {
            throw ToolError(
                "launch.settingsKeys holds a key that is never allowed. It can hold env and crossSessionInbound."
            )
        }
        if launch.envNames.contains(where: isForbiddenEnvName) {
            throw ToolError("launch.envNames holds a name that is never allowed.")
        }
    }

    /// Refuses a prototype-pollution key at any depth, and nesting deeper than `maxDepth`.
    static func checkNested(_ value: Any, depth: Int = 0) throws {
        if depth > maxDepth { throw ToolError("The caller settings are nested too deeply.") }
        if let object = value as? [String: Any] {
            for (key, inner) in object {
                if forbiddenNestedKeys.contains(key) {
                    throw ToolError(
                        "The caller settings use the key '\(Display.safe(key, limit: 64))', which is never allowed."
                    )
                }
                try checkNested(inner, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for inner in array { try checkNested(inner, depth: depth + 1) }
        }
    }

    /// Checks `text`. Throws a `ToolError` (exit 1) and writes nothing on any violation.
    public static func validate(_ text: String?, launch: LaunchSettings) throws -> CallerSettings {
        guard let text else { return .none }
        try checkLaunchLists(launch)
        let data = Data(text.utf8)
        guard data.count <= maxBytes else {
            throw ToolError("The caller settings are larger than \(maxBytes) bytes.")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
            let object = parsed as? [String: Any]
        else { throw ToolError("The caller settings are not one JSON object.") }

        try checkNested(object)
        for key in object.keys.sorted()
        where !launch.settingsKeys.contains(key) || !isAllowedSettingsKey(key) {
            throw ToolError(
                "The caller settings use the key '\(Display.safe(key, limit: 64))', which is not in launch.settingsKeys."
            )
        }
        if let inbound = object["crossSessionInbound"], !(inbound is String) {
            throw ToolError("The caller settings key 'crossSessionInbound' is not a string.")
        }
        if let rawEnv = object["env"] {
            guard let env = rawEnv as? [String: Any] else {
                throw ToolError("The caller settings key 'env' is not an object.")
            }
            for name in env.keys.sorted() {
                let shown = Display.safe(name, limit: 64)
                guard name.range(of: envNamePattern, options: .regularExpression) != nil else {
                    throw ToolError("The caller settings env name '\(shown)' is not valid.")
                }
                guard !isForbiddenEnvName(name) else {
                    throw ToolError("The caller settings env name '\(shown)' is never allowed.")
                }
                guard launch.envNames.contains(name) else {
                    throw ToolError(
                        "The caller settings env name '\(shown)' is not in launch.envNames.")
                }
                guard env[name] is String else {
                    throw ToolError("The caller settings env value of '\(shown)' is not a string.")
                }
            }
        }
        guard JSONSerialization.isValidJSONObject(object),
            let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
        else { throw ToolError("The caller settings are not valid JSON.") }
        return CallerSettings(json: canonical)
    }

    /// The checked object, with `env` merged: the caller's entries, then the extra ones.
    func merged(extraEnv: [String: String]) throws -> Data {
        guard var object = (try JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw ToolError("The caller settings are not valid JSON.")
        }
        var env = object["env"] as? [String: Any] ?? [:]
        for (name, value) in extraEnv { env[name] = value }
        object["env"] = env
        // Written by the tool, so a project or local settings file cannot switch hooks off for a
        // session this file launches.
        object[Self.hooksKey] = false
        return try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

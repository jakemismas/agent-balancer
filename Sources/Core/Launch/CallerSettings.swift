import Foundation

/// The settings a caller hands to `pick`, checked against the allowlist of
/// docs/ARCHITECTURE.md section 4A.2. A refusal names the offending key and never a value.
public struct CallerSettings: Sendable {
    public static let maxBytes = 16_384
    static let envNamePattern = "^[A-Z][A-Z0-9_]{0,63}$"
    /// Names that are never allowed in `env`, whatever the config lists. The protected group and
    /// the prefix and suffix rules are checked in `isForbiddenEnvName`.
    static let forbiddenEnvNames: Set<String> = [
        "PATH", "HOME", "NODE_OPTIONS", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE",
    ]

    /// Canonical JSON of the checked object. `{}` when the caller gave none.
    let json: Data

    public static let none = CallerSettings(json: Data("{}".utf8))

    static func isForbiddenEnvName(_ name: String) -> Bool {
        ProtectedEnv.isProtected(name) || name.hasPrefix(LaunchFiles.accountVariablePrefix)
            || forbiddenEnvNames.contains(name) || name.uppercased().hasSuffix("_PROXY")
    }

    /// Checks `text`. Throws a `ToolError` (exit 1) and writes nothing on any violation.
    public static func validate(_ text: String?, launch: LaunchSettings) throws -> CallerSettings {
        guard let text else { return .none }
        let data = Data(text.utf8)
        guard data.count <= maxBytes else {
            throw ToolError("The caller settings are larger than \(maxBytes) bytes.")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
            let object = parsed as? [String: Any]
        else { throw ToolError("The caller settings are not one JSON object.") }

        for key in object.keys.sorted() where !launch.settingsKeys.contains(key) {
            throw ToolError(
                "The caller settings use the key '\(Display.safe(key, limit: 64))', which is not in launch.settingsKeys."
            )
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
        return try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

import Foundation

/// A token read for a launch file. It prints as a fixed word, so a stray string interpolation
/// or dump never shows the value.
public struct TokenSecret: CustomStringConvertible, CustomDebugStringConvertible, Sendable {
    let value: String

    public var description: String { "[token]" }
    public var debugDescription: String { "[token]" }

    /// The value for the one call that writes a launch file. Only the `Launch` module uses it.
    func reveal() -> String { value }
}

/// Reads the token of a token account. Only the `Launch` module takes the value; other modules
/// ask `isUsable`, which answers yes or no.
public enum TokenStore {
    static let maxLength = 512

    /// The token of `label`, from a token file that is a regular file owned by the user with
    /// mode 0600. A file that is missing, wide open, not JSON or without a plausible token throws
    /// `token_missing`, with a message that holds no part of the file.
    static func read(context: ToolContext, label: String) throws -> TokenSecret {
        let missing = ToolError(Messages.tokenMissing(label), code: .tokenMissing)
        let facts = try TokenPaths.facts(context: context, label: label)
        guard facts.exists, facts.isPrivate else { throw missing }
        let name = try TokenPaths.fileName(label: label)
        guard
            let data = try NoFollowReader(root: context.dataRoot).read(
                folders: TokenPaths.folders, name: name, limit: 16_384),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let env = object["env"] as? [String: Any],
            let value = env[ProtectedEnv.tokenVariable] as? String,
            isPlausible(value)
        else { throw missing }
        return TokenSecret(value: value)
    }

    /// Whether the token file of `label` is private and holds a plausible token. Answers yes or no
    /// and never returns any part of the file.
    public static func isUsable(context: ToolContext, label: String) -> Bool {
        (try? read(context: context, label: label)) != nil
    }

    /// A shape check only: printable, no spaces, a sane length.
    static func isPlausible(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        return value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }
}

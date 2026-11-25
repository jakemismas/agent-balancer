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
    /// mode 0600 and an access list that lets no other user or group in. A file that is missing,
    /// not private, not JSON or without a plausible token throws `token_missing`, with a message
    /// that holds no part of the file.
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

    /// What a status row, `pick` and `run` say when a token of `label` is kept from use by more
    /// than a missing file: the refusal of a folder above it, which names its fix, a token folder
    /// the user cannot search, so the token file cannot be checked, or a token file whose access
    /// list may let others in. Nil otherwise. No file is opened.
    public static func blockedText(context: ToolContext, label: String) -> String? {
        do {
            let facts = try TokenPaths.facts(context: context, label: label)
            if facts.folderUnsearchable { return folderUnsearchableText(label: label) }
            return facts.sharedByAccessList || facts.unchecked
                ? Messages.tokenFileShared(label) : nil
        } catch let error as ToolError {
            return error.message
        } catch {
            return nil
        }
    }

    /// What a status row, `pick` and `run` say when the user cannot search the token folder, so
    /// the token file of `label` cannot be checked. The folder passed the folder checks, so it
    /// is a real folder of the user's: `chflags` first clears a lock or an append-only flag,
    /// which keeps `chmod` out, then `chmod -N` clears a list that denies `search`, and
    /// `chmod 700` a mode without it, as the folder refusal for one that cannot be searched says.
    /// It stays within the 300 characters the status table and `pick` print.
    static func folderUnsearchableText(label: String) -> String {
        let place = typedFolder
        return
            "The token file of '\(Display.safe(label, limit: 32))' cannot be checked: the token folder `\(place)` cannot be searched. Run `chflags nouchg,nouappnd \(place)` if it is locked, `chmod -N \(place)`, then `chmod 700 \(place)` in Terminal."
    }

    /// A shape check only: printable, no spaces, a sane length.
    static func isPlausible(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        return value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }
}

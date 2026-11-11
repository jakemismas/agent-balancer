import CryptoKit
import Foundation

/// One hook entry of a settings file: the event, the matcher and the SHA-256 of the command
/// string. The command text itself is never kept.
public struct HookEntry: Codable, Hashable, Comparable, Sendable {
    public var event: String
    public var matcher: String
    /// SHA-256 of the command string, or of the empty string for a hook without one. Printing only.
    public var commandHash: String
    /// SHA-256 of the canonical JSON of the whole hook object. This is what the comparison uses.
    public var fingerprint: String

    public static func < (a: HookEntry, b: HookEntry) -> Bool {
        (a.event, a.matcher, a.fingerprint) < (b.event, b.matcher, b.fingerprint)
    }

    /// Event, matcher and the first 12 characters of the hash: safe to print.
    public var summary: String {
        "\(Self.printable(event)) [\(matcher.isEmpty ? "*" : Self.printable(matcher))] "
            + Self.printable(String(fingerprint.prefix(12)))
    }

    private static func printable(_ text: String) -> String {
        Display.safe(Scrubber.scrubText(text))
    }

    /// The shape of both hashes as `HookRecord` writes them: 64 lowercase hex digits.
    static func isHash(_ text: String) -> Bool {
        text.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }
}

/// The only things taken from a settings file. No other value is kept.
public struct SettingsFacts: Equatable, Sendable {
    public var hooks: [HookEntry]
    public var disableAllHooks: Bool
    public var apiKeyHelperPresent: Bool
    /// Names among `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and the Claude Code token variable.
    public var keyEnvNames: [String]

    public static let empty = SettingsFacts(
        hooks: [], disableAllHooks: false, apiKeyHelperPresent: false, keyEnvNames: [])

    public var carriesKey: Bool { apiKeyHelperPresent || !keyEnvNames.isEmpty }
}

public struct HookDiff: Equatable, Sendable {
    public var added: [HookEntry]
    public var removed: [HookEntry]
    public var disableAllHooks: Bool
    public var recordedDisableAllHooks: Bool

    /// True when nothing differs from the record, the hook-off flag included.
    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && disableAllHooks == recordedDisableAllHooks
    }
}

public enum HookRecordStatus: Equatable, Sendable {
    /// No record, or one that does not parse.
    case missing
    /// Every recorded hook is still there and hooks are on. Added hooks pass.
    case matches(added: Int)
    /// A recorded hook is gone, or `disableAllHooks` is set.
    case changed(HookDiff)
}

struct HookRecordFile: Codable, Equatable {
    var schemaVersion: Int
    var defaultFolder: DefaultFolderRecord?
}

struct DefaultFolderRecord: Codable, Equatable {
    var disableAllHooks: Bool
    var hooks: [HookEntry]
}

/// The hook fingerprint of the default folder's `settings.json`, kept in `links.json`. This is the
/// only reader of that settings file.
public struct HookRecord: Sendable {
    public let context: ToolContext
    private let reader: NoFollowReader
    private let writer: NoFollowWriter
    static let fileName = "links.json"

    public init(context: ToolContext) {
        self.context = context
        self.reader = NoFollowReader(root: context.dataRoot)
        self.writer = NoFollowWriter(root: context.dataRoot)
    }

    // MARK: Parsing

    /// Takes the hook entries, the `disableAllHooks` flag, whether `apiKeyHelper` is present and
    /// which of the three key names `env` holds. Every other key and every value is dropped.
    public static func parse(_ data: Data) throws -> SettingsFacts {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("settings.json is not a JSON object.")
        }
        var entries = Set<HookEntry>()
        if let raw = object["hooks"] {
            guard let events = raw as? [String: Any] else {
                throw ToolError("settings.json hooks is not an object.")
            }
            for (event, groups) in events {
                guard let list = groups as? [Any] else {
                    throw ToolError("settings.json hooks entry has an unexpected shape.")
                }
                for item in list {
                    guard let group = item as? [String: Any] else {
                        throw ToolError("settings.json hooks entry has an unexpected shape.")
                    }
                    var matcher = ""
                    if let raw = group["matcher"] {
                        guard let text = raw as? String else {
                            throw ToolError("settings.json hooks entry has an unexpected shape.")
                        }
                        matcher = text
                    }
                    guard let hooks = group["hooks"] as? [Any] else {
                        throw ToolError("settings.json hooks entry has an unexpected shape.")
                    }
                    for entry in hooks {
                        guard let hook = entry as? [String: Any],
                            JSONSerialization.isValidJSONObject(hook)
                        else {
                            throw ToolError("settings.json hooks entry has an unexpected shape.")
                        }
                        var command = ""
                        if let raw = hook["command"] {
                            guard let text = raw as? String else {
                                throw ToolError(
                                    "settings.json hooks entry has an unexpected shape.")
                            }
                            command = text
                        }
                        let canonical = try JSONSerialization.data(
                            withJSONObject: hook, options: [.sortedKeys])
                        entries.insert(
                            HookEntry(
                                event: event, matcher: matcher, commandHash: sha256(command),
                                fingerprint: sha256(Data(canonical))))
                    }
                }
            }
        }
        var keyNames: [String] = []
        if let env = object["env"] as? [String: Any] {
            keyNames = ProtectedEnv.settingsEnvNames.filter { env[$0] != nil }.sorted()
        }
        return SettingsFacts(
            hooks: entries.sorted(), disableAllHooks: (object["disableAllHooks"] as? Bool) == true,
            apiKeyHelperPresent: object["apiKeyHelper"] != nil, keyEnvNames: keyNames)
    }

    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The default folder's settings. A missing file is an empty set; one that does not parse
    /// throws.
    public func readSettings() throws -> SettingsFacts {
        let url = context.defaultClaudeFolder.appendingPathComponent("settings.json")
        guard let data = try NoFollowReader.readOutside(url) else { return .empty }
        return try Self.parse(data)
    }

    // MARK: The record

    /// A record holding a hash of another shape reads as unreadable, like one that does not parse.
    private func loadFile() -> HookRecordFile? {
        guard let data = try? reader.read(folders: [], name: Self.fileName),
            let file = try? JSONDecoder().decode(HookRecordFile.self, from: data),
            file.schemaVersion == 1,
            (file.defaultFolder?.hooks ?? []).allSatisfy({
                HookEntry.isHash($0.fingerprint) && HookEntry.isHash($0.commandHash)
            })
        else { return nil }
        return file
    }

    /// Writes the fingerprint of `facts` as the default folder's record.
    public func record(_ facts: SettingsFacts) throws {
        let file = HookRecordFile(
            schemaVersion: 1,
            defaultFolder: DefaultFolderRecord(
                disableAllHooks: facts.disableAllHooks, hooks: facts.hooks))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(file)
        data.append(0x0A)
        try writer.put(data, folders: [], name: Self.fileName)
    }

    /// The recorded hooks, or nil when the record is missing or unreadable.
    func recorded() -> DefaultFolderRecord? { loadFile()?.defaultFolder }

    public func diff(current facts: SettingsFacts) -> HookDiff? {
        guard let rec = recorded() else { return nil }
        let before = Set(rec.hooks)
        let now = Set(facts.hooks)
        return HookDiff(
            added: now.subtracting(before).sorted(), removed: before.subtracting(now).sorted(),
            disableAllHooks: facts.disableAllHooks, recordedDisableAllHooks: rec.disableAllHooks)
    }

    public func status(current facts: SettingsFacts) -> HookRecordStatus {
        guard let d = diff(current: facts) else { return .missing }
        if !d.removed.isEmpty || d.disableAllHooks { return .changed(d) }
        return .matches(added: d.added.count)
    }
}

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

/// One link the tool made for a folder account: where it sits and what it points to.
public struct LinkEntry: Codable, Equatable, Sendable {
    public var path: String
    public var target: String

    public init(path: String, target: String) {
        self.path = path
        self.target = target
    }
}

struct HookRecordFile: Codable, Equatable {
    var schemaVersion: Int
    var defaultFolder: DefaultFolderRecord?
    var links: [LinkEntry]?
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
    /// throws. When the file's stamp is the same before and after the read, the outcome is saved
    /// as the verdict that `run` uses in place of reading the file (`seenVerdict`). No other code
    /// opens the file.
    public func readSettings() throws -> SettingsFacts {
        let url = context.defaultClaudeFolder.appendingPathComponent("settings.json")
        let before = try? SettingsStamp.take(url)
        let outcome: Result<SettingsFacts, Error>
        do {
            if let data = try NoFollowReader.readOutside(url) {
                outcome = .success(try Self.parse(data))
            } else {
                outcome = .success(.empty)
            }
        } catch {
            outcome = .failure(error)
        }
        if let before, before == (try? SettingsStamp.take(url)) {
            saveVerdict(stamp: before, facts: try? outcome.get())
        }
        return try outcome.get()
    }

    // MARK: The settings verdict

    /// What a reader saw: the stamp of the file, then the hooks and the key flag, or `readable`
    /// false when the file could not be read or parsed. No env name and no value is kept.
    struct VerdictFile: Codable, Equatable {
        var schemaVersion: Int
        var stamp: SettingsStamp
        var readable: Bool
        var hooks: [HookEntry]
        var disableAllHooks: Bool
        var carriesKey: Bool
    }

    func saveVerdict(stamp: SettingsStamp, facts: SettingsFacts?) {
        let file = VerdictFile(
            schemaVersion: 1, stamp: stamp, readable: facts != nil, hooks: facts?.hooks ?? [],
            disableAllHooks: facts?.disableAllHooks ?? false, carriesKey: facts?.carriesKey ?? false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(file) else { return }
        data.append(0x0A)
        // A failed save leaves the older verdict, which no longer matches the file, so `run` refuses.
        try? writer.put(data, folders: Layout.stateFolders, name: Layout.settingsSeenName)
    }

    /// What `run` may take from the settings of the default folder: a reason to refuse, or the key
    /// flag. It stats the file and never opens it.
    public struct SeenSettings: Equatable, Sendable {
        public var issue: String?
        public var carriesKey: Bool
    }

    /// The verdict a reader saved, valid only while the file's stamp is unchanged. A missing,
    /// unreadable, malformed or older verdict, a stamp that cannot be taken, and a settings path
    /// that is not a regular file all refuse. The hook record is compared live, so a record that
    /// changed after the verdict is caught too.
    public func seenVerdict() -> SeenSettings {
        let stale = SeenSettings(issue: Messages.settingsNotChecked, carriesKey: false)
        let url = context.defaultClaudeFolder.appendingPathComponent("settings.json")
        guard let stamp = try? SettingsStamp.take(url), stamp.isRegularOrAbsent,
            let data = try? reader.read(
                folders: Layout.stateFolders, name: Layout.settingsSeenName),
            let file = try? JSONDecoder().decode(VerdictFile.self, from: data),
            file.schemaVersion == 1, file.readable, file.stamp == stamp,
            file.hooks.allSatisfy({
                HookEntry.isHash($0.fingerprint) && HookEntry.isHash($0.commandHash)
            })
        else { return stale }
        let facts = SettingsFacts(
            hooks: file.hooks, disableAllHooks: file.disableAllHooks,
            apiKeyHelperPresent: file.carriesKey, keyEnvNames: [])
        switch status(current: facts) {
        case .missing:
            return SeenSettings(issue: Messages.hookRecordMissing, carriesKey: file.carriesKey)
        case .changed:
            return SeenSettings(issue: Messages.settingsChanged, carriesKey: file.carriesKey)
        case .matches:
            return SeenSettings(issue: nil, carriesKey: file.carriesKey)
        }
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

    /// The link list of the file as it stands, so a save never drops it. A file whose list cannot
    /// be decoded stops the save: a record that is only missing or has a bad hook part still keeps
    /// its list.
    private func linksToKeep() throws -> [LinkEntry]? {
        guard let data = try reader.read(folders: [], name: Self.fileName) else { return nil }
        struct LinksOnly: Decodable { var links: [LinkEntry]? }
        guard let parsed = try? JSONDecoder().decode(LinksOnly.self, from: data) else {
            throw ToolError(
                "links.json cannot be read, so the record was not saved and its link list is kept. Move links.json aside and run this again."
            )
        }
        return parsed.links
    }

    /// Writes the fingerprint of `facts` as the default folder's record.
    public func record(_ facts: SettingsFacts) throws {
        let file = HookRecordFile(
            schemaVersion: 1,
            defaultFolder: DefaultFolderRecord(
                disableAllHooks: facts.disableAllHooks, hooks: facts.hooks),
            links: try linksToKeep())
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

    // MARK: Links

    /// The links `links.json` lists, or none when the record is missing or unreadable.
    public func listedLinks() -> [LinkEntry] { loadFile()?.links ?? [] }

    /// Where a listed link sits as folders under the data folder, or nil when it is not directly
    /// inside `accounts/<label>/.claude/`. Nothing outside the data folder is ever named.
    func location(of entry: LinkEntry) -> (folders: [String], name: String)? {
        let root = context.dataRoot.standardizedFileURL.pathComponents
        let parts = URL(fileURLWithPath: entry.path).standardizedFileURL.pathComponents
        guard !entry.path.contains("/../"), parts.count == root.count + 4,
            Array(parts.prefix(root.count)) == root
        else { return nil }
        let rest = Array(parts.suffix(4))
        guard rest[0] == "accounts", ConfigValidator.isValidLabel(rest[1]), rest[2] == ".claude"
        else { return nil }
        return (Array(rest.prefix(3)), rest[3])
    }

    /// Whether a listed link is still a symlink with the recorded target.
    public func isIntact(_ entry: LinkEntry) -> Bool {
        guard let spot = location(of: entry) else { return false }
        return (try? writer.hasLink(folders: spot.folders, name: spot.name, target: entry.target))
            ?? false
    }

    /// Removes each listed link that is still a symlink with the recorded target. A path that is
    /// a regular file, a folder or a link to somewhere else stays. Returns the counts.
    public func removeListedLinks() -> (removed: Int, kept: Int) {
        var removed = 0
        var kept = 0
        for entry in listedLinks() {
            guard let spot = location(of: entry),
                (try? writer.removeLink(
                    folders: spot.folders, name: spot.name, target: entry.target)) == true
            else {
                kept += 1
                continue
            }
            removed += 1
        }
        return (removed, kept)
    }
}

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
    /// `env` names that carry a credential or choose the account (`ProtectedEnv.isKeyInSettings`).
    public var keyEnvNames: [String]
    /// `env` names that switch hooks off or bring in a settings source, by exact name.
    public var hooksOffEnvNames: [String] = []

    public static let empty = SettingsFacts(
        hooks: [], disableAllHooks: false, apiKeyHelperPresent: false, keyEnvNames: [])

    public var carriesKey: Bool { apiKeyHelperPresent || !keyEnvNames.isEmpty }

    /// Such an `env` name switches hooks off as surely as the flag does.
    public var hooksOff: Bool { disableAllHooks || !hooksOffEnvNames.isEmpty }
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
    /// The folder accounts a `link` run completed for. An empty manifest still counts as linked.
    var linkedLabels: [String]?
}

/// The five things a folder account may share with the shared source, in the order they are
/// linked. Nothing else is ever linked.
public enum SharedItems {
    public struct Item: Equatable, Sendable {
        public let name: String
        public let isFolder: Bool
    }

    public static let settingsName = "settings.json"
    public static let all: [Item] = [
        Item(name: settingsName, isFolder: false), Item(name: "CLAUDE.md", isFolder: false),
        Item(name: "skills", isFolder: true), Item(name: "agents", isFolder: true),
        Item(name: "commands", isFolder: true),
    ]
}

/// The default folder's record as it was when a person reviewed it.
public struct HookRecordSnapshot: Sendable {
    let value: DefaultFolderRecord?
}

struct DefaultFolderRecord: Codable, Equatable, Sendable {
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

    /// The read rule allows hook entries, the flag, `apiKeyHelper`'s presence and `env` names only.
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
        var hooksOffNames: [String] = []
        if let env = object["env"] as? [String: Any] {
            let names = env.keys.filter {
                $0.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil
            }
            keyNames = names.filter(ProtectedEnv.isKeyInSettings).sorted()
            hooksOffNames = names.filter(ProtectedEnv.switchesHooksOff).sorted()
        }
        return SettingsFacts(
            hooks: entries.sorted(), disableAllHooks: (object["disableAllHooks"] as? Bool) == true,
            apiKeyHelperPresent: object["apiKeyHelper"] != nil, keyEnvNames: keyNames,
            hooksOffEnvNames: hooksOffNames)
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
            disableAllHooks: facts?.hooksOff ?? false, carriesKey: facts?.carriesKey ?? false
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
        /// The stamp the verdict holds, set only when the verdict passes.
        public var stamp: SettingsStamp? = nil
    }

    /// The verdict a reader saved, valid only while the file's stamp is unchanged. A missing,
    /// unreadable, malformed or older verdict, a stamp that cannot be taken, and a settings path
    /// that is not a regular file all refuse. The hook record is compared live, so a record that
    /// changed after the verdict is caught too. A settings path that is a link that goes nowhere,
    /// or is not a file, refuses with a text that names that fix, since running `doctor` alone
    /// cannot clear it.
    public func seenVerdict() -> SeenSettings {
        let stale = SeenSettings(issue: Messages.settingsNotChecked, carriesKey: false)
        let url = context.defaultClaudeFolder.appendingPathComponent("settings.json")
        guard let stamp = try? SettingsStamp.take(url) else {
            // Only a link makes the path present while what it names cannot be checked.
            if let path = try? FileStamp.take(url.path, followLinks: false), path.present,
                !path.isRegular
            {
                return SeenSettings(issue: Messages.settingsLinkGoesNowhere, carriesKey: false)
            }
            return stale
        }
        guard stamp.isRegularOrAbsent else {
            let dangling = stamp.link.present && !stamp.link.isRegular && !stamp.target.present
            return SeenSettings(
                issue: dangling ? Messages.settingsLinkGoesNowhere : Messages.settingsNotAFile,
                carriesKey: false)
        }
        guard
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
            return SeenSettings(issue: nil, carriesKey: file.carriesKey, stamp: stamp)
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

    /// What a save keeps of the file as it stands: the link list, the linked labels and the
    /// default folder's record. A file whose link list or linked labels cannot be decoded stops
    /// every save. One whose default folder record cannot be decoded stops a links save, and only
    /// the save of a new default folder record, which replaces it, goes ahead.
    private struct Kept: Decodable {
        var schemaVersion: Int?
        var links: [LinkEntry]?
        var linkedLabels: [String]?
        var defaultFolder: DefaultFolderRecord?
        /// True when a `defaultFolder` value is present and does not decode.
        var defaultFolderUnreadable = false

        enum CodingKeys: String, CodingKey {
            case schemaVersion, links, linkedLabels, defaultFolder
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            links = try c.decodeIfPresent([LinkEntry].self, forKey: .links)
            linkedLabels = try c.decodeIfPresent([String].self, forKey: .linkedLabels)
            if c.contains(.defaultFolder), !(try c.decodeNil(forKey: .defaultFolder)) {
                do {
                    let record = try c.decode(DefaultFolderRecord.self, forKey: .defaultFolder)
                    // The same rule `loadFile` applies, so a save never works from a view that
                    // dropped a record the readers cannot read.
                    if record.hooks.allSatisfy({
                        HookEntry.isHash($0.fingerprint) && HookEntry.isHash($0.commandHash)
                    }) {
                        defaultFolder = record
                    } else {
                        defaultFolderUnreadable = true
                    }
                } catch {
                    defaultFolderUnreadable = true
                }
            }
        }

        init() {}
    }

    private static let unreadableText =
        "links.json cannot be read, so nothing was saved and the file is unchanged. Move links.json aside, run `agent-balancer link --accept-source-change` to record the hooks again, then run `agent-balancer link <label>` again for each folder account."

    private static let unreadableDefaultText =
        "The hook record in links.json cannot be read, so nothing was saved and the file is unchanged. Run `agent-balancer link --accept-source-change` to record the hooks again. The links stay listed."

    private func kept(replacingDefault: Bool = false) throws -> Kept {
        guard let data = try reader.read(folders: [], name: Self.fileName) else { return Kept() }
        guard let parsed = try? JSONDecoder().decode(Kept.self, from: data),
            parsed.schemaVersion == 1
        else { throw ToolError(Self.unreadableText) }
        if parsed.defaultFolderUnreadable && !replacingDefault {
            throw ToolError(Self.unreadableDefaultText)
        }
        return parsed
    }

    /// Holds one lock for a whole read-modify-write of `links.json`, so two writers never lose
    /// each other's change.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        guard
            let lock = try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.linksLockName, wait: 30)
        else { throw ToolError("Another change to links.json is running. Try again in a moment.") }
        defer { lock.release() }
        return try body()
    }

    private func saveFile(_ file: HookRecordFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(file)
        data.append(0x0A)
        try writer.put(data, folders: [], name: Self.fileName)
    }

    /// Writes the fingerprint of `facts` as the default folder's record.
    public func record(_ facts: SettingsFacts) throws {
        try record(facts, ifRecordIs: nil)
    }

    /// With `ifRecordIs`, writes only while the default folder's record is still the one the
    /// person was shown the difference against (nil inside the value means no record).
    public func record(_ facts: SettingsFacts, ifRecordIs expected: HookRecordSnapshot?) throws {
        try locked {
            if let expected, loadFile()?.defaultFolder != expected.value {
                throw ToolError(
                    "The hook record changed after you were shown the difference, so nothing was recorded. Run `agent-balancer link --accept-source-change` again."
                )
            }
            let old = try kept(replacingDefault: true)
            try saveFile(
                HookRecordFile(
                    schemaVersion: 1,
                    defaultFolder: DefaultFolderRecord(
                        disableAllHooks: facts.hooksOff, hooks: facts.hooks),
                    links: old.links, linkedLabels: old.linkedLabels))
        }
    }

    /// Replaces the links listed for one folder account and marks it linked or not. Every other
    /// account's entries and the default folder's record stay as they are.
    public func saveLinks(label: String, entries: [LinkEntry], linked: Bool) throws {
        try locked { try saveLinksHeld(label: label, entries: entries, linked: linked) }
    }

    /// The caller holds the links lock.
    private func saveLinksHeld(label: String, entries: [LinkEntry], linked: Bool) throws {
        let old = try kept()
        let others = (old.links ?? []).filter { location(of: $0)?.folders[1] != label }
        var labels = (old.linkedLabels ?? []).filter { $0 != label }
        if linked { labels.append(label) }
        try saveFile(
            HookRecordFile(
                schemaVersion: 1, defaultFolder: old.defaultFolder, links: others + entries,
                linkedLabels: labels.sorted()))
    }

    /// What `links.json` holds for one folder account: its listed links and whether it is marked
    /// linked.
    public struct LinkState: Equatable, Sendable {
        public var entries: [LinkEntry]
        public var linked: Bool
    }

    public func linkState(for label: String) -> LinkState {
        LinkState(entries: entries(for: label), linked: isLinked(label))
    }

    /// Runs `body` under the links lock when the account's record is still `expected`, the state a
    /// person approved a change against. Otherwise nothing runs and nothing is written. The lock
    /// is not held while a person is asked, only from this check to the final save.
    public func changeLinks<T>(
        label: String, expecting expected: LinkState,
        _ body: (_ save: (_ entries: [LinkEntry], _ linked: Bool) throws -> Void) throws -> T
    ) throws -> T {
        try locked {
            // Refuses before anything else runs when part of the file cannot be read.
            _ = try kept()
            guard linkState(for: label) == expected else {
                throw ToolError(
                    "The links of '\(Display.safe(label, limit: 32))' changed after you were shown them, so nothing was changed. Run the command again."
                )
            }
            return try body { entries, linked in
                try saveLinksHeld(label: label, entries: entries, linked: linked)
            }
        }
    }

    /// Forgets every folder account's links and linked mark, keeping the default folder's record.
    /// `uninstall` calls it after the links are removed, so a file that stays says nothing is linked.
    public func forgetAllLinks() throws {
        try locked {
            let old = try kept()
            try saveFile(
                HookRecordFile(
                    schemaVersion: 1, defaultFolder: old.defaultFolder, links: [], linkedLabels: [])
            )
        }
    }

    /// True once a `link` run finished for this folder account.
    public func isLinked(_ label: String) -> Bool {
        loadFile()?.linkedLabels?.contains(label) ?? false
    }

    /// The links listed for one folder account.
    public func entries(for label: String) -> [LinkEntry] {
        listedLinks().filter { location(of: $0)?.folders[1] == label }
    }

    /// The first shared source that exists in the default folder (by `lstat`, nothing opened) while
    /// the folder account's list has no link for it, or nil.
    public func firstUnlinkedSource(for label: String) -> String? {
        let listed = Set(
            entries(for: label).map { URL(fileURLWithPath: $0.path).lastPathComponent })
        return SharedItems.all.first { item in
            var st = stat()
            let path = context.defaultClaudeFolder.appendingPathComponent(item.name).path
            return !listed.contains(item.name) && lstat(path, &st) == 0
        }?.name
    }

    /// True when the folder account's list holds the shared settings link.
    public func sharesSettings(_ label: String) -> Bool {
        entries(for: label).contains {
            URL(fileURLWithPath: $0.path).lastPathComponent == SharedItems.settingsName
        }
    }

    /// Removes one listed link when it is still a symlink with the recorded target.
    @discardableResult
    public func removeLink(_ entry: LinkEntry) -> Bool {
        guard let spot = location(of: entry) else { return false }
        return
            (try? writer.removeLink(folders: spot.folders, name: spot.name, target: entry.target))
            ?? false
    }

    /// The shared source folder. Only the default folder is supported in this version, because the
    /// hook record covers that folder's settings.
    public static func sharedSource(config: Config, context: ToolContext) throws -> URL {
        let text = config.sharedSource
        let expanded =
            text == "~"
            ? context.home.path
            : text.hasPrefix("~/") ? context.home.path + String(text.dropFirst(1)) : text
        let given = URL(fileURLWithPath: expanded).standardizedFileURL
        guard given.path == context.defaultClaudeFolder.standardizedFileURL.path else {
            throw ToolError(
                "sharedSource must be the default folder in this version, because the hook record covers that folder's settings."
            )
        }
        return context.defaultClaudeFolder
    }

    /// What the default folder's settings show now against the record: the refusal text, its kind
    /// (`missing` or `changed`) and whether the settings carry a key. Names only.
    public func currentState() -> (issue: String?, kind: String?, carriesKey: Bool) {
        do {
            let facts = try readSettings()
            switch status(current: facts) {
            case .missing: return (Messages.hookRecordMissing, "missing", facts.carriesKey)
            case .changed: return (Messages.settingsChanged, "changed", facts.carriesKey)
            case .matches: return (nil, nil, facts.carriesKey)
            }
        } catch {
            return ("settings.json could not be read or parsed.", "changed", false)
        }
    }

    /// The record as it stands now, to pass back to `record(_:ifRecordIs:)`.
    public func snapshot() -> HookRecordSnapshot { HookRecordSnapshot(value: recorded()) }

    /// The recorded hooks, or nil when the record is missing or unreadable.
    func recorded() -> DefaultFolderRecord? { loadFile()?.defaultFolder }

    public func diff(current facts: SettingsFacts) -> HookDiff? {
        guard let rec = recorded() else { return nil }
        let before = Set(rec.hooks)
        let now = Set(facts.hooks)
        return HookDiff(
            added: now.subtracting(before).sorted(), removed: before.subtracting(now).sorted(),
            disableAllHooks: facts.hooksOff, recordedDisableAllHooks: rec.disableAllHooks)
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
    /// inside `accounts/<label>/.claude/`. Nothing outside the data folder is ever named. A path
    /// with an empty, `.` or `..` segment is not resolved: it names no location.
    func location(of entry: LinkEntry) -> (folders: [String], name: String)? {
        let written = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        guard entry.path.hasPrefix("/"),
            !written.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        let root = context.dataRoot.standardizedFileURL.pathComponents
        let parts = URL(fileURLWithPath: entry.path).standardizedFileURL.pathComponents
        guard parts.count == root.count + 4, Array(parts.prefix(root.count)) == root else {
            return nil
        }
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

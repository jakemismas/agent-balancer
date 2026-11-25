import Foundation

/// Reads, validates and writes `config.json` through the no-follow reader and writer.
public struct ConfigStore: Sendable {
    public let context: ToolContext
    private let reader: NoFollowReader
    private let writer: NoFollowWriter

    public static let fileName = "config.json"

    public init(context: ToolContext) {
        self.context = context
        self.reader = NoFollowReader(root: context.dataRoot)
        self.writer = NoFollowWriter(root: context.dataRoot)
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }

    /// The saved config, or nil before `init`. A damaged or invalid file throws.
    public func load() throws -> Config? {
        guard let data = try reader.read(folders: [], name: Self.fileName) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("config.json is not valid JSON.")
        }
        guard let version = object["schemaVersion"] as? Int else {
            throw ToolError("config.json has no schemaVersion.")
        }
        guard version == Config.currentSchema else {
            throw ToolError(
                "Config schema version \(version) is not supported. This version reads version \(Config.currentSchema)."
            )
        }
        let config: Config
        do {
            config = try Self.decoder().decode(Config.self, from: data)
        } catch {
            throw ToolError("config.json has a missing or wrong-typed field.")
        }
        try ConfigValidator.validate(config)
        return config
    }

    public func loadRequired() throws -> Config {
        guard let config = try load() else { throw ToolError(Messages.notSetUp) }
        return config
    }

    /// Validates, then writes. With `backup`, the file as it was goes to `backups/` first.
    public func save(_ config: Config, backup: Bool = false) throws {
        try ConfigValidator.validate(config, context: context)
        if backup, let old = try reader.read(folders: [], name: Self.fileName) {
            try writer.put(old, folders: Layout.backupsFolders, name: try backupName())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(config)
        if let old = try reader.read(folders: [], name: Self.fileName),
            let oldObject = try? JSONSerialization.jsonObject(with: old) as? [String: Any],
            let newObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let merged = Self.mergeTop(old: oldObject, new: newObject)
            data = try JSONSerialization.data(
                withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        }
        data.append(0x0A)
        try writer.put(data, folders: [], name: Self.fileName)
    }

    private static let topKeys: Set<String> = [
        "schemaVersion", "sharedSource", "accounts", "probe", "refresh", "fable", "picker",
        LaunchFiles.configKey, "history",
    ]
    private static let accountKeys: Set<String> = [
        "label", "kind", "role", "email", "expectedPlanTier", "accountKey", "reserve", "endsAt",
        "endingSoon", "fable", "tokenCreatedAt", "noLimit",
    ]
    private static let probeKeys: Set<String> = ["safeMode", "timeoutSeconds", "passProxyEnv"]
    private static let refreshKeys: Set<String> = ["backgroundMinutes"]
    private static let fableKeys: Set<String> = [
        "capPercentOfWeekly", "probe", "probeBudgetUsd", "probeTimeoutSeconds",
        "minRoomPercentOfCap", "recheckAfterWeeklyRisePercent",
    ]
    private static let pickerKeys: Set<String> = [
        "limitedAtPercent", "minRoomPercent", "maxReadingAgeMinutes", "deadlineSeconds",
        "leaseMinutes", "expectedRunPercent", "endingSoonAssumeDays",
    ]
    private static let historyKeys: Set<String> = ["retentionDays"]
    private static let launchKeys: Set<String> = ["settingsKeys", "envNames", "keepDays"]
    private static let reserveKeys: Set<String> = ["points", "marginPercent", "allowAbove90"]

    /// Known keys come from the new value (and vanish when it omits them); keys this version does
    /// not know are kept from the file as it was.
    private static func overlay(
        old: [String: Any], new: [String: Any], known: Set<String>
    ) -> [String: Any] {
        var out = old.filter { !known.contains($0.key) }
        for (k, v) in new { out[k] = v }
        return out
    }

    private static func mergeTop(old: [String: Any], new: [String: Any]) -> [String: Any] {
        var out = overlay(old: old, new: new, known: topKeys)
        if let n = new["probe"] as? [String: Any] {
            out["probe"] = overlay(
                old: old["probe"] as? [String: Any] ?? [:], new: n, known: probeKeys)
        }
        if let n = new["refresh"] as? [String: Any] {
            out["refresh"] = overlay(
                old: old["refresh"] as? [String: Any] ?? [:], new: n, known: refreshKeys)
        }
        if let n = new["fable"] as? [String: Any] {
            out["fable"] = overlay(
                old: old["fable"] as? [String: Any] ?? [:], new: n, known: fableKeys)
        }
        if let n = new["picker"] as? [String: Any] {
            out["picker"] = overlay(
                old: old["picker"] as? [String: Any] ?? [:], new: n, known: pickerKeys)
        }
        if let n = new[LaunchFiles.configKey] as? [String: Any] {
            out[LaunchFiles.configKey] = overlay(
                old: old[LaunchFiles.configKey] as? [String: Any] ?? [:], new: n, known: launchKeys)
        }
        if let n = new["history"] as? [String: Any] {
            out["history"] = overlay(
                old: old["history"] as? [String: Any] ?? [:], new: n, known: historyKeys)
        }
        let oldAccounts = (old["accounts"] as? [[String: Any]]) ?? []
        var byKey: [String: [String: Any]] = [:]
        for a in oldAccounts { if let k = a["accountKey"] as? String { byKey[k] = a } }
        let newAccounts = (new["accounts"] as? [[String: Any]]) ?? []
        out["accounts"] = newAccounts.map { n -> [String: Any] in
            guard let k = n["accountKey"] as? String, let o = byKey[k] else { return n }
            var merged = overlay(old: o, new: n, known: accountKeys)
            if let nr = n["reserve"] as? [String: Any] {
                merged["reserve"] = overlay(
                    old: o["reserve"] as? [String: Any] ?? [:], new: nr, known: reserveKeys)
            }
            return merged
        }
        return out
    }

    private func backupName() throws -> String {
        let formatter = Self.backupDayFormatter()
        let now = Date()
        var n = 1
        var name = Self.backupName(now, number: n, formatter: formatter)
        while try reader.read(folders: Layout.backupsFolders, name: name) != nil {
            n += 1
            name = Self.backupName(now, number: n, formatter: formatter)
        }
        return name
    }

    /// The day in a backup's name, `yyyy-MM-dd` in the Gregorian calendar whatever the person's
    /// calendar is. The writer uses the local time zone.
    static func backupDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// The name of the `number`th backup on the day of `date`: the first has no number, and the
    /// next ones count up from 2.
    static func backupName(_ date: Date, number: Int, formatter: DateFormatter) -> String {
        let day = formatter.string(from: date)
        return number <= 1 ? "config-\(day).json" : "config-\(day)-\(number).json"
    }

    /// Whether `backupName` gives `name` on a day of a four-digit year. The name is taken apart
    /// into a day and a number and built again by the same code, and only the same bytes pass, so
    /// a day that is not a real date and a number of `-0`, `-1` or with a leading zero are not a
    /// backup's. The day is read in UTC, where every day of the calendar exists.
    static func isBackupName(_ name: String) -> Bool {
        let head = "config-"
        let tail = ".json"
        let dayLength = 10
        guard name.hasPrefix(head), name.hasSuffix(tail),
            name.count >= head.count + dayLength + tail.count
        else { return false }
        let middle = name.dropFirst(head.count).dropLast(tail.count)
        let rest = middle.dropFirst(dayLength)
        let number: Int?
        if rest.isEmpty {
            number = 1
        } else if rest.first == "-" {
            number = Int(rest.dropFirst())
        } else {
            number = nil
        }
        guard let number else { return false }
        let formatter = backupDayFormatter()
        if let utc = TimeZone(identifier: "UTC") { formatter.timeZone = utc }
        guard let date = formatter.date(from: String(middle.prefix(dayLength))) else {
            return false
        }
        return Array(backupName(date, number: number, formatter: formatter).utf8)
            == Array(name.utf8)
    }
}

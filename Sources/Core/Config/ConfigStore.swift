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
        try ConfigValidator.validate(config)
        if backup, let old = try reader.read(folders: [], name: Self.fileName) {
            try writer.put(old, folders: ["backups"], name: try backupName())
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
        LaunchFiles.configKey,
    ]
    private static let accountKeys: Set<String> = [
        "label", "kind", "role", "email", "expectedPlanTier", "accountKey", "reserve", "endsAt",
        "endingSoon", "fable",
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        var name = "config-\(day).json"
        var n = 1
        while try reader.read(folders: ["backups"], name: name) != nil {
            n += 1
            name = "config-\(day)-\(n).json"
        }
        return name
    }
}

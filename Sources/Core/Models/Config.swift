import Foundation

public struct ProbeSettings: Codable, Equatable, Sendable {
    public var safeMode: Bool
    public var timeoutSeconds: Int
    public var passProxyEnv: Bool

    public init(safeMode: Bool = true, timeoutSeconds: Int = 60, passProxyEnv: Bool = false) {
        self.safeMode = safeMode
        self.timeoutSeconds = timeoutSeconds
        self.passProxyEnv = passProxyEnv
    }
}

public struct RefreshSettings: Codable, Equatable, Sendable {
    public var backgroundMinutes: Int

    public init(backgroundMinutes: Int = 60) {
        self.backgroundMinutes = backgroundMinutes
    }
}

/// The Fable weekly meter and its probe (docs/ARCHITECTURE.md sections 4A.6 and 7.4).
public struct FableSettings: Codable, Equatable, Sendable {
    public var capPercentOfWeekly: Int
    public var probe: Bool
    public var probeBudgetUsd: Double
    public var probeTimeoutSeconds: Int
    public var minRoomPercentOfCap: Int
    public var recheckAfterWeeklyRisePercent: Int

    public init(
        capPercentOfWeekly: Int = 50, probe: Bool = true, probeBudgetUsd: Double = 0.50,
        probeTimeoutSeconds: Int = 20, minRoomPercentOfCap: Int = 10,
        recheckAfterWeeklyRisePercent: Int = 5
    ) {
        self.capPercentOfWeekly = capPercentOfWeekly
        self.probe = probe
        self.probeBudgetUsd = probeBudgetUsd
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.minRoomPercentOfCap = minRoomPercentOfCap
        self.recheckAfterWeeklyRisePercent = recheckAfterWeeklyRisePercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FableSettings()
        capPercentOfWeekly =
            try c.decodeIfPresent(Int.self, forKey: .capPercentOfWeekly) ?? d.capPercentOfWeekly
        probe = try c.decodeIfPresent(Bool.self, forKey: .probe) ?? d.probe
        probeBudgetUsd =
            try c.decodeIfPresent(Double.self, forKey: .probeBudgetUsd) ?? d.probeBudgetUsd
        probeTimeoutSeconds =
            try c.decodeIfPresent(Int.self, forKey: .probeTimeoutSeconds) ?? d.probeTimeoutSeconds
        minRoomPercentOfCap =
            try c.decodeIfPresent(Int.self, forKey: .minRoomPercentOfCap) ?? d.minRoomPercentOfCap
        recheckAfterWeeklyRisePercent =
            try c.decodeIfPresent(Int.self, forKey: .recheckAfterWeeklyRisePercent)
            ?? d.recheckAfterWeeklyRisePercent
    }
}

/// The picker keys this version reads. The rest of section 7.1 arrives with the picker.
public struct PickerSettings: Codable, Equatable, Sendable {
    public var maxReadingAgeMinutes: Int

    public init(maxReadingAgeMinutes: Int = 15) {
        self.maxReadingAgeMinutes = maxReadingAgeMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxReadingAgeMinutes =
            try c.decodeIfPresent(Int.self, forKey: .maxReadingAgeMinutes) ?? 15
    }
}

/// `config.json`: labels, kinds, emails and rules. It holds no token, no launch template and no
/// executable path.
public struct Config: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var sharedSource: String
    public var accounts: [Account]
    public var probe: ProbeSettings
    public var refresh: RefreshSettings
    public var fable: FableSettings
    public var picker: PickerSettings

    public init(
        schemaVersion: Int = Config.currentSchema, sharedSource: String = "~/.claude",
        accounts: [Account] = [], probe: ProbeSettings = ProbeSettings(),
        refresh: RefreshSettings = RefreshSettings(), fable: FableSettings = FableSettings(),
        picker: PickerSettings = PickerSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.sharedSource = sharedSource
        self.accounts = accounts
        self.probe = probe
        self.refresh = refresh
        self.fable = fable
        self.picker = picker
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sharedSource, accounts, probe, refresh, fable, picker
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sharedSource = try c.decodeIfPresent(String.self, forKey: .sharedSource) ?? "~/.claude"
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        probe = try c.decodeIfPresent(ProbeSettings.self, forKey: .probe) ?? ProbeSettings()
        refresh = try c.decodeIfPresent(RefreshSettings.self, forKey: .refresh) ?? RefreshSettings()
        fable = try c.decodeIfPresent(FableSettings.self, forKey: .fable) ?? FableSettings()
        picker = try c.decodeIfPresent(PickerSettings.self, forKey: .picker) ?? PickerSettings()
    }

    public func account(_ label: String) -> Account? {
        accounts.first { $0.label == label }
    }

    public var loginAccount: Account? { accounts.first { $0.kind == Kind.login } }
}

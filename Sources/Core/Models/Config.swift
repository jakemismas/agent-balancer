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

/// The picker keys of docs/ARCHITECTURE.md section 7.1.
public struct PickerSettings: Codable, Equatable, Sendable {
    public var limitedAtPercent: Int
    public var minRoomPercent: Int
    public var maxReadingAgeMinutes: Int
    public var deadlineSeconds: Int
    public var leaseMinutes: Int
    public var expectedRunPercent: Int
    public var endingSoonAssumeDays: Int

    public init(
        limitedAtPercent: Int = 95, minRoomPercent: Int = 5, maxReadingAgeMinutes: Int = 15,
        deadlineSeconds: Int = 45, leaseMinutes: Int = 10, expectedRunPercent: Int = 5,
        endingSoonAssumeDays: Int = 2
    ) {
        self.limitedAtPercent = limitedAtPercent
        self.minRoomPercent = minRoomPercent
        self.maxReadingAgeMinutes = maxReadingAgeMinutes
        self.deadlineSeconds = deadlineSeconds
        self.leaseMinutes = leaseMinutes
        self.expectedRunPercent = expectedRunPercent
        self.endingSoonAssumeDays = endingSoonAssumeDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PickerSettings()
        limitedAtPercent =
            try c.decodeIfPresent(Int.self, forKey: .limitedAtPercent) ?? d.limitedAtPercent
        minRoomPercent =
            try c.decodeIfPresent(Int.self, forKey: .minRoomPercent) ?? d.minRoomPercent
        maxReadingAgeMinutes =
            try c.decodeIfPresent(Int.self, forKey: .maxReadingAgeMinutes) ?? d.maxReadingAgeMinutes
        deadlineSeconds =
            try c.decodeIfPresent(Int.self, forKey: .deadlineSeconds) ?? d.deadlineSeconds
        leaseMinutes = try c.decodeIfPresent(Int.self, forKey: .leaseMinutes) ?? d.leaseMinutes
        expectedRunPercent =
            try c.decodeIfPresent(Int.self, forKey: .expectedRunPercent) ?? d.expectedRunPercent
        endingSoonAssumeDays =
            try c.decodeIfPresent(Int.self, forKey: .endingSoonAssumeDays)
            ?? d.endingSoonAssumeDays
    }
}

/// What a caller's own settings may carry into a launch file (docs/ARCHITECTURE.md section 4A.2).
public struct LaunchSettings: Codable, Equatable, Sendable {
    /// Top-level keys a caller's settings may use.
    public var settingsKeys: [String]
    /// Names a caller's `env` may use. Empty until the user lists some.
    public var envNames: [String]
    /// Days a launch file is kept when session entries cannot be read (section 4A.6).
    public var keepDays: Int

    public init(settingsKeys: [String] = ["env"], envNames: [String] = [], keepDays: Int = 35) {
        self.settingsKeys = settingsKeys
        self.envNames = envNames
        self.keepDays = keepDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LaunchSettings()
        settingsKeys = try c.decodeIfPresent([String].self, forKey: .settingsKeys) ?? d.settingsKeys
        envNames = try c.decodeIfPresent([String].self, forKey: .envNames) ?? d.envNames
        keepDays = try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? d.keepDays
    }
}

/// How long the readings history and the events record keep lines (docs/ARCHITECTURE.md
/// section 10.4). With 0 no history line is kept.
public struct HistorySettings: Codable, Equatable, Sendable {
    public var retentionDays: Int

    public init(retentionDays: Int = 35) {
        self.retentionDays = retentionDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays =
            try c.decodeIfPresent(Int.self, forKey: .retentionDays)
            ?? HistorySettings().retentionDays
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
    public var launch: LaunchSettings
    public var history: HistorySettings

    public init(
        schemaVersion: Int = Config.currentSchema, sharedSource: String = "~/.claude",
        accounts: [Account] = [], probe: ProbeSettings = ProbeSettings(),
        refresh: RefreshSettings = RefreshSettings(), fable: FableSettings = FableSettings(),
        picker: PickerSettings = PickerSettings(), launch: LaunchSettings = LaunchSettings(),
        history: HistorySettings = HistorySettings()
    ) {
        self.schemaVersion = schemaVersion
        self.sharedSource = sharedSource
        self.accounts = accounts
        self.probe = probe
        self.refresh = refresh
        self.fable = fable
        self.picker = picker
        self.launch = launch
        self.history = history
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sharedSource, accounts, probe, refresh, fable, picker, launch, history
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
        launch = try c.decodeIfPresent(LaunchSettings.self, forKey: .launch) ?? LaunchSettings()
        history = try c.decodeIfPresent(HistorySettings.self, forKey: .history) ?? HistorySettings()
    }

    public func account(_ label: String) -> Account? {
        accounts.first { $0.label == label }
    }

    public var loginAccount: Account? { accounts.first { $0.kind == Kind.login } }
}

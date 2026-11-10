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

/// `config.json`: labels, kinds, emails and rules. It holds no token, no launch template and no
/// executable path.
public struct Config: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var sharedSource: String
    public var accounts: [Account]
    public var probe: ProbeSettings
    public var refresh: RefreshSettings

    public init(
        schemaVersion: Int = Config.currentSchema, sharedSource: String = "~/.claude",
        accounts: [Account] = [], probe: ProbeSettings = ProbeSettings(),
        refresh: RefreshSettings = RefreshSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.sharedSource = sharedSource
        self.accounts = accounts
        self.probe = probe
        self.refresh = refresh
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sharedSource, accounts, probe, refresh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sharedSource = try c.decodeIfPresent(String.self, forKey: .sharedSource) ?? "~/.claude"
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        probe = try c.decodeIfPresent(ProbeSettings.self, forKey: .probe) ?? ProbeSettings()
        refresh = try c.decodeIfPresent(RefreshSettings.self, forKey: .refresh) ?? RefreshSettings()
    }

    public func account(_ label: String) -> Account? {
        accounts.first { $0.label == label }
    }

    public var loginAccount: Account? { accounts.first { $0.kind == Kind.login } }
}

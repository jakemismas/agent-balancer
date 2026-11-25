import Foundation

/// A lenient reader of `state/status.json` for the menu app (docs/ARCHITECTURE.md section 10.1).
/// It decodes only the fields the menu shows and tolerates added fields.
public struct SnapshotIssue: Decodable, Equatable, Sendable {
    public var code: String
    public var text: String

    public init(code: String, text: String) {
        self.code = code
        self.text = text
    }
}

/// A percent from the status file. One that is not finite or lies outside 0 to 100 reads as
/// missing, so no rewritten file can feed the menu a number it cannot show.
enum SnapshotPercent {
    static func read<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Double? {
        guard let value = try c.decodeIfPresent(Double.self, forKey: key), value.isFinite,
            (0...100).contains(value)
        else { return nil }
        return value
    }
}

public struct SnapshotWindow: Decodable, Equatable, Sendable {
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var source: String?

    private enum CodingKeys: String, CodingKey {
        case usedPercent, resetsAt, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try SnapshotPercent.read(c, .usedPercent)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

public struct SnapshotFable: Decodable, Equatable, Sendable {
    public var usedPercent: Double?
    public var guaranteedLeftPercentOfCap: Double?
    public var possibleLeftPercentOfCap: Double?
    public var resetsAt: Date?
    public var source: String?

    private enum CodingKeys: String, CodingKey {
        case usedPercent, guaranteedLeftPercentOfCap, possibleLeftPercentOfCap, resetsAt, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try SnapshotPercent.read(c, .usedPercent)
        guaranteedLeftPercentOfCap = try SnapshotPercent.read(c, .guaranteedLeftPercentOfCap)
        possibleLeftPercentOfCap = try SnapshotPercent.read(c, .possibleLeftPercentOfCap)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

public struct SnapshotInUse: Decodable, Equatable, Sendable {
    public var count: Int?
}

public struct SnapshotLimited: Decodable, Equatable, Sendable {
    public var window: String?
    public var until: Date?
}

public struct AccountSnapshot: Decodable, Equatable, Sendable {
    public var label: String
    public var email: String?
    public var role: String
    public var endingSoon: Bool
    public var state: String
    public var limited: SnapshotLimited?
    public var error: SnapshotIssue?
    public var warnings: [SnapshotIssue]
    public var weekly: SnapshotWindow?
    public var fable: SnapshotFable?
    public var readingsAge: Int?
    public var inUse: SnapshotInUse?
    public var endsAt: String?
    /// The fields below are only read by the Manage accounts window. All are optional so an older
    /// status file still decodes.
    public var kind: String?
    public var fullLogin: Bool?
    public var configDir: String?
    public var linked: Bool?
    public var loginExpiresAt: Date?
    public var loginExpiresSource: String?
    /// When the tool first saw the current state. A value that is not a date reads as none, since
    /// the window only shows it.
    public var stateSince: Date?
    /// The plan tier the last check that saw the account signed in reported. A value that is not
    /// a plain tier reads as none, so it never counts as a sign-in.
    public var planTier: String?
    /// A folder account's last sign-in check result, as written. Nil in a status written before
    /// the field, before the first check, or when the value is not a string; the window fails
    /// closed on a value it does not know.
    public var signInCheck: String?
    /// Whether the row carries the `signInCheck` key as a string or null. A folder row written
    /// before the field has none, and its plan tier may outlive a check that doubted the sign-in.
    public var hasSignInCheck: Bool

    private enum CodingKeys: String, CodingKey {
        case label, email, role, endingSoon, state, limited, error, warnings, weekly, fable,
            readingsAge, inUse, endsAt, kind, fullLogin, configDir, linked, loginExpiresAt,
            loginExpiresSource, stateSince, planTier, signInCheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        endingSoon = try c.decodeIfPresent(Bool.self, forKey: .endingSoon) ?? false
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "ok"
        limited = try c.decodeIfPresent(SnapshotLimited.self, forKey: .limited)
        error = try c.decodeIfPresent(SnapshotIssue.self, forKey: .error)
        warnings = try c.decodeIfPresent([SnapshotIssue].self, forKey: .warnings) ?? []
        weekly = try c.decodeIfPresent(SnapshotWindow.self, forKey: .weekly)
        fable = try c.decodeIfPresent(SnapshotFable.self, forKey: .fable)
        readingsAge = try c.decodeIfPresent(Int.self, forKey: .readingsAge)
        inUse = try c.decodeIfPresent(SnapshotInUse.self, forKey: .inUse)
        endsAt = try c.decodeIfPresent(String.self, forKey: .endsAt)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        fullLogin = try c.decodeIfPresent(Bool.self, forKey: .fullLogin)
        configDir = try c.decodeIfPresent(String.self, forKey: .configDir)
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked)
        loginExpiresAt = try c.decodeIfPresent(Date.self, forKey: .loginExpiresAt)
        loginExpiresSource = try c.decodeIfPresent(String.self, forKey: .loginExpiresSource)
        stateSince = (try? c.decodeIfPresent(Date.self, forKey: .stateSince)) ?? nil
        planTier = ((try? c.decodeIfPresent(String.self, forKey: .planTier)) ?? nil)
            .flatMap { AuthStatusReader.isPlainTier($0) ? $0 : nil }
        do {
            signInCheck = try c.decodeIfPresent(String.self, forKey: .signInCheck)
            hasSignInCheck = c.contains(.signInCheck)
        } catch {
            // A value of another type is no check, read as strictly as a row with no key, and
            // the rest of the status still loads.
            signInCheck = nil
            hasSignInCheck = false
        }
    }
}

public struct NextChoiceSnapshot: Decodable, Equatable, Sendable {
    public var label: String?
    public var reason: String
}

public struct NextSnapshot: Decodable, Equatable, Sendable {
    public var all: NextChoiceSnapshot
    public var fable: NextChoiceSnapshot
}

public struct StatusSnapshot: Decodable, Equatable, Sendable {
    /// The status schema this app understands.
    public static let supportedSchema = 1

    public var schemaVersion: Int
    public var generatedAt: Date?
    public var banner: SnapshotIssue?
    public var accounts: [AccountSnapshot]
    public var next: NextSnapshot?

    /// Reads a status document. A schema newer than this app reads is reported as such, before
    /// any other field is looked at. Anything else that does not decode is `unreadable`.
    public static func parse(_ data: Data) -> StatusLoad {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["schemaVersion"] as? Int
        else { return .unreadable("The status file is not a status document.") }
        if version > supportedSchema { return .newerSchema(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = SnapshotDates.parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "bad date"))
        }
        do {
            return .loaded(try decoder.decode(StatusSnapshot.self, from: data))
        } catch {
            return .unreadable("The status file has a missing or wrong-typed field.")
        }
    }
}

enum SnapshotDates {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

public enum StatusLoad: Equatable, Sendable {
    case missing
    case unreadable(String)
    case newerSchema(Int)
    case loaded(StatusSnapshot)
}

/// What the menu app reads from the data folder: `state/status.json`, and whether `config.json`
/// exists. Both reads go through the no-follow reader. The app writes no file.
public struct StatusReader: Sendable {
    public let context: ToolContext
    private let reader: NoFollowReader

    public init(context: ToolContext) {
        self.context = context
        self.reader = NoFollowReader(root: context.dataRoot)
    }

    public func load() -> StatusLoad {
        do {
            guard let data = try reader.read(folders: Layout.stateFolders, name: "status.json")
            else { return .missing }
            return StatusSnapshot.parse(data)
        } catch {
            return .unreadable("The status file could not be read.")
        }
    }

    /// True when `config.json` is there. A file that cannot be checked counts as there, so the
    /// "run init" card never hides a real setup.
    public func configExists() -> Bool {
        do {
            return try reader.read(folders: [], name: ConfigStore.fileName) != nil
        } catch {
            return true
        }
    }

    /// `config.json` when it loads as a valid config, else nil.
    func validConfig() -> Config? {
        try? ConfigStore(context: context).load()
    }

    /// `refresh.backgroundMinutes`, or the default of 60 when the config cannot be read.
    public func backgroundMinutes() -> Int {
        Self.backgroundMinutes(validConfig())
    }

    static func backgroundMinutes(_ config: Config?) -> Int {
        guard let config else { return RefreshSettings().backgroundMinutes }
        return min(max(1, config.refresh.backgroundMinutes), ConfigLimits.spanMinutes)
    }
}

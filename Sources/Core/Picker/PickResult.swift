import Foundation

/// One account's line in a pick answer.
public struct CandidateResult: Codable, Equatable, Sendable {
    public var label: String
    public var eligible: Bool
    public var reason: String

    public init(label: String, eligible: Bool, reason: String) {
        self.label = label
        self.eligible = eligible
        self.reason = reason
    }
}

/// How a caller applies a recipe (docs/ARCHITECTURE.md section 4A.2).
public enum PickCaller: String, Sendable {
    case typed
    case launcher
}

/// The answer of `pick --json` (section 10.2). With no pick (`label` nil) the recipe fields are
/// null. The renderer for the typed strings is `Recipe`.
public struct PickResult: Encodable, Equatable, Sendable {
    public static let currentSchema = 1

    public var pickedAt: Date
    public var model: String
    public var label: String?
    public var env: [String: String]?
    public var args: [String]?
    public var launchPrefix: String?
    public var launchArgs: String?
    public var unsetEnv: [String]?
    public var backgroundOnly: Bool
    public var reason: String
    public var candidates: [CandidateResult]
    /// True for `--dry-run`: no lease and no launch file were written, so there is no recipe.
    public var dryRun: Bool

    public var picked: Bool { label != nil }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pickedAt, model, label, env, args, launchPrefix, launchArgs, unsetEnv,
            backgroundOnly, reason, candidates, dryRun
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchema, forKey: .schemaVersion)
        try c.encode(pickedAt, forKey: .pickedAt)
        try c.encode(model, forKey: .model)
        try encodeOrNull(&c, label, .label)
        try encodeOrNull(&c, env, .env)
        try encodeOrNull(&c, args, .args)
        try encodeOrNull(&c, launchPrefix, .launchPrefix)
        try encodeOrNull(&c, launchArgs, .launchArgs)
        try encodeOrNull(&c, unsetEnv, .unsetEnv)
        try c.encode(backgroundOnly, forKey: .backgroundOnly)
        try c.encode(reason, forKey: .reason)
        try c.encode(candidates, forKey: .candidates)
        if dryRun { try c.encode(true, forKey: .dryRun) }
    }

    private func encodeOrNull<T: Encodable>(
        _ c: inout KeyedEncodingContainer<CodingKeys>, _ value: T?, _ key: CodingKeys
    ) throws {
        if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// The one renderer of the typed strings. They are built only from values that passed the
/// validators: a launch file path under the data folder.
public enum Recipe {
    /// The names a launcher removes from the child's environment (section 4A.3).
    public static let unsetNames = [
        ProtectedEnv.configDirVariable, ProtectedEnv.tokenVariable, "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
    ]

    /// `--settings '<path>'`. A path with a quote or a control character is refused, because the
    /// string is typed into a shell line.
    public static func launchArgs(settingsPath: String) throws -> String {
        let safe =
            settingsPath.hasPrefix("/")
            && settingsPath.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
            && !settingsPath.contains("'") && !settingsPath.contains("\\")
        guard safe else {
            throw ToolError("The launch file path cannot be written safely into a command line.")
        }
        return "--settings '\(settingsPath)'"
    }
}

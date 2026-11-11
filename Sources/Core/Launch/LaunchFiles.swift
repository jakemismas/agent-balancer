import Foundation

/// One launch file a session record names: the label and the lease id from its path.
public struct LaunchRef: Hashable, Sendable {
    public let label: String
    public let leaseId: String

    public init(label: String, leaseId: String) {
        self.label = label
        self.leaseId = leaseId
    }
}

/// Launch files: `launch/<label>/<leaseId>.json`, mode 0600, one per pick (docs/ARCHITECTURE.md
/// section 4A.2). This module and `Tokens` are the only code that opens the `launch` folder.
public enum LaunchFiles {
    /// The config key that holds `LaunchSettings`.
    public static let configKey = "launch"
    static let folder = "launch"

    public static let accountVariable = "AGENT_BALANCER_ACCOUNT"
    static let accountVariablePrefix = "AGENT_BALANCER_"

    static func folders(label: String) -> [String] { [folder, label] }

    static func fileName(leaseId: String) -> String { leaseId + ".json" }

    static func isValidLeaseId(_ id: String) -> Bool {
        id.range(of: #"\Al-[0-9a-f]{8}\z"#, options: .regularExpression) != nil
    }

    static func makeLeaseId() -> String { "l-" + Paths.randomHex(4) }

    /// The folder that holds every launch folder. No file is opened.
    public static func rootURL(context: ToolContext) -> URL {
        context.dataRoot.appendingPathComponent(folder, isDirectory: true)
    }

    /// The absolute path of a launch file. No file is opened.
    public static func fileURL(context: ToolContext, label: String, leaseId: String) throws -> URL {
        guard ConfigValidator.isValidLabel(label), isValidLeaseId(leaseId) else {
            throw ToolError("Label or lease id is not valid.")
        }
        return context.dataRoot.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(fileName(leaseId: leaseId))
    }

    /// Writes the launch file of one pick and returns its path. The file holds the account label,
    /// the token for a token account, and the caller's checked settings. A token account whose
    /// token file cannot be used throws `token_missing` and nothing is written.
    public static func create(
        context: ToolContext, account: Account, leaseId: String, caller: CallerSettings
    ) throws -> URL {
        let url = try fileURL(context: context, label: account.label, leaseId: leaseId)
        var extra = [accountVariable: account.label]
        if account.kind == Kind.token {
            extra[ProtectedEnv.tokenVariable] = try TokenStore.read(
                context: context, label: account.label
            ).reveal()
        }
        let data = try caller.merged(extraEnv: extra) + Data([0x0A])
        try NoFollowWriter(root: context.dataRoot).put(
            data, folders: folders(label: account.label), name: fileName(leaseId: leaseId))
        return url
    }

    /// True when a launch file of that lease exists.
    static func exists(context: ToolContext, label: String, leaseId: String) -> Bool {
        let info = try? NoFollowWriter(root: context.dataRoot).info(
            folders: folders(label: label), name: fileName(leaseId: leaseId))
        return info != nil
    }
}

extension LaunchFiles {
    /// Removes the launch file of a pick that did not finish. Only a regular file owned by the
    /// user goes, through the no-follow writer.
    static func discard(context: ToolContext, label: String, leaseId: String) {
        _ = try? NoFollowWriter(root: context.dataRoot).removeOwnRegularFile(
            folders: folders(label: label), name: fileName(leaseId: leaseId))
    }
}

extension LaunchFiles {
    private static let referencePattern = try? NSRegularExpression(
        pattern: "launch/([a-z0-9][a-z0-9-]{0,31})/(l-[0-9a-f]{8})\\.json")

    /// The launch files a piece of record text names, by the shape `launch/<label>/l-<8 hex>.json`
    /// after `\/` is unescaped. The label comes from the path, never from anything else, and the
    /// text is never kept.
    public static func references(in text: String) -> [LaunchRef] {
        guard text.contains("launch"), let pattern = referencePattern else { return [] }
        let plain = text.replacingOccurrences(of: "\\/", with: "/")
        let whole = NSRange(plain.startIndex..., in: plain)
        var found: [LaunchRef] = []
        for match in pattern.matches(in: plain, range: whole) {
            guard let label = Range(match.range(at: 1), in: plain),
                let id = Range(match.range(at: 2), in: plain)
            else { continue }
            found.append(LaunchRef(label: String(plain[label]), leaseId: String(plain[id])))
        }
        return found
    }

    /// True when the named launch file exists as a directory entry. Nothing is read.
    public static func exists(context: ToolContext, ref: LaunchRef) -> Bool {
        exists(context: context, label: ref.label, leaseId: ref.leaseId)
    }
}

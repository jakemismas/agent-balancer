import Foundation

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
        id.range(of: "^l-[0-9a-f]{8}$", options: .regularExpression) != nil
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

    /// Removes launch files this tool made that are older than `launch.keepDays`. Session
    /// entries are not read in this version, so the rule of section 4A.6 for unreadable session
    /// entries applies to every file. Only a regular file owned by the user is removed, through
    /// the no-follow writer. Returns the number removed.
    @discardableResult
    public static func upkeep(context: ToolContext, keepDays: Int, now: Date) -> Int {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard let labels = try? writer.listNames(folders: [folder]) else { return 0 }
        let limit = Double(max(1, keepDays)) * 86_400
        var removed = 0
        for label in labels where ConfigValidator.isValidLabel(label) {
            guard let names = try? writer.listNames(folders: folders(label: label)) else {
                continue
            }
            for name in names where name.hasSuffix(".json") {
                let id = String(name.dropLast(5))
                guard isValidLeaseId(id),
                    let info = try? writer.info(folders: folders(label: label), name: name),
                    info.isRegularFile, info.ownedByUser,
                    now.timeIntervalSince(info.modified) > limit
                else { continue }
                if (try? writer.removeOwnRegularFile(folders: folders(label: label), name: name))
                    == true
                {
                    removed += 1
                }
            }
        }
        return removed
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

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
        let writer = NoFollowWriter(root: context.dataRoot)
        try writer.prepare(folders: [folder])
        try writer.markExcludedFromBackup(folders: [folder])
        try writer.put(
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

extension LaunchFiles {
    /// The names of the launch files this tool made for `label`: `l-<8 hex>.json`, a regular file
    /// owned by the user, directly under the label's folder. Anything else there is not ours.
    static func ownFileNames(context: ToolContext, label: String) throws -> [String] {
        guard ConfigValidator.isValidLabel(label) else { throw ToolError("Label is not valid.") }
        let writer = NoFollowWriter(root: context.dataRoot)
        let dir = folders(label: label)
        return try writer.listNames(folders: dir).filter { name in
            guard name.hasSuffix(".json"), isValidLeaseId(String(name.dropLast(5))),
                let info = try? writer.info(folders: dir, name: name)
            else { return false }
            return info.isRegularFile && info.ownedByUser
        }
    }

    /// The value a tombstone holds in place of a token. It is not a token, so a session that reads
    /// the file fails to sign in instead of falling back to the stored login.
    static let tombstoneValue = "invalid"

    /// The JSON object of one launch file, or nil when it cannot be read or does not parse.
    private static func object(context: ToolContext, label: String, name: String) -> [String: Any]?
    {
        guard
            let data = try? NoFollowReader(root: context.dataRoot).read(
                folders: folders(label: label), name: name, limit: 65_536)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func isTombstone(_ object: [String: Any]) -> Bool {
        (object["env"] as? [String: Any])?[ProtectedEnv.tokenVariable] as? String == tombstoneValue
    }

    private static func put(
        _ object: [String: Any], context: ToolContext, label: String, name: String
    ) throws {
        let out =
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            + Data([0x0A])
        try NoFollowWriter(root: context.dataRoot).put(
            out, folders: folders(label: label), name: name)
    }

    /// Overwrites one launch file with a tombstone: the launch file's shape with the token variable
    /// set to `invalid`, the account label, and nothing else.
    private static func writeTombstone(context: ToolContext, label: String, name: String) throws {
        let env: [String: Any] = [
            ProtectedEnv.tokenVariable: tombstoneValue, accountVariable: label,
        ]
        try put(["env": env], context: context, label: label, name: name)
    }

    /// True when a session record names the file, or when the records could not be read cleanly.
    private static func isNamed(_ name: String, label: String, snapshot: SessionsSnapshot) -> Bool {
        !snapshot.clean
            || snapshot.named.contains(LaunchRef(label: label, leaseId: String(name.dropLast(5))))
    }

    /// What one pass of `rewriteToken` did.
    struct RewritePass: Equatable {
        /// Every file the pass looked at, so a caller that lists again stops.
        var handled = Set<String>()
        /// Files that now carry the new token.
        var rewritten = 0
    }

    /// Writes the token of `label`, as the token store now holds it, into every live launch file of
    /// the label that is not in `skipping`. A tombstone is never revived. A file that does not
    /// parse never keeps the old token: one a session record names (or any, when the records
    /// cannot be read cleanly) becomes a tombstone, and any other is deleted. Callers hold the
    /// pick lock.
    static func rewriteToken(
        context: ToolContext, label: String, skipping: Set<String>, snapshot: SessionsSnapshot
    ) throws -> RewritePass {
        let token = try TokenStore.read(context: context, label: label).reveal()
        let writer = NoFollowWriter(root: context.dataRoot)
        var pass = RewritePass()
        for name in try ownFileNames(context: context, label: label) where !skipping.contains(name)
        {
            pass.handled.insert(name)
            guard var object = object(context: context, label: label, name: name) else {
                if isNamed(name, label: label, snapshot: snapshot) {
                    try writeTombstone(context: context, label: label, name: name)
                } else {
                    try writer.removeOwnRegularFile(folders: folders(label: label), name: name)
                }
                continue
            }
            if isTombstone(object) { continue }
            var env = object["env"] as? [String: Any] ?? [:]
            env[ProtectedEnv.tokenVariable] = token
            object["env"] = env
            try put(object, context: context, label: label, name: name)
            pass.rewritten += 1
        }
        return pass
    }

    /// What `removeAll` did with the launch files of one label.
    struct RemovalCount: Equatable {
        var deleted = 0
        /// Files kept as tombstones: a session record names them, their lease is open, or the
        /// records could not be read cleanly. Upkeep removes them once nothing needs them.
        var tombstoned = 0
        /// Entries in the label's folder that the tool did not make. They are left alone.
        var skipped = 0
        /// Names of the writer's temporary shape still in the label's folder after the delete.
        var temporariesLeft = 0
    }

    /// Deletes the temporary files the no-follow writer left in the label's folder when a write
    /// stopped before its rename; one may hold a whole launch file, token included. Callers hold
    /// the pick lock, which every writer of launch files holds. Returns how many names of that
    /// shape are still there.
    @discardableResult
    static func deleteWriterLeftovers(context: ToolContext, label: String) throws -> Int {
        guard ConfigValidator.isValidLabel(label) else { throw ToolError("Label is not valid.") }
        return try NoFollowWriter(root: context.dataRoot).removeLeftoverTemporaries(
            folders: folders(label: label))
    }

    /// How many temporary files the writer left in the launch folders of every label. Names only.
    static func writerLeftoverCount(context: ToolContext) -> Int {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard let labels = try? writer.listNames(folders: [folder]) else { return 0 }
        return labels.filter(ConfigValidator.isValidLabel).reduce(0) { sum, label in
            sum + ((try? writer.leftoverTemporaries(folders: folders(label: label)).count) ?? 0)
        }
    }

    /// Clears every launch file of `label` (docs/ARCHITECTURE.md section 4A.4, Removing). A file
    /// that a session record names, or whose lease in `leased` is open, or any file when the
    /// records cannot be read cleanly, becomes a tombstone and is kept; every other file is
    /// deleted. The folder is listed again after each pass, so a file written meanwhile is handled
    /// too. The writer's leftover temporary files go, entries the tool did not make are counted
    /// and left alone, and the label's folder goes when nothing else is in it. Callers hold the
    /// pick lock.
    static func removeAll(
        context: ToolContext, label: String, snapshot: SessionsSnapshot, leased: Set<String>,
        keepModifiedAfter: Date? = nil
    ) throws -> RemovalCount {
        let writer = NoFollowWriter(root: context.dataRoot)
        var count = RemovalCount()
        var handled = Set<String>()
        let dir = folders(label: label)
        for _ in 0..<5 {
            let names = try ownFileNames(context: context, label: label).filter {
                !handled.contains($0)
            }
            if names.isEmpty { break }
            for name in names {
                handled.insert(name)
                let young =
                    keepModifiedAfter.map { limit in
                        ((try? writer.info(folders: dir, name: name))?.modified ?? .distantFuture)
                            > limit
                    } ?? false
                if isNamed(name, label: label, snapshot: snapshot)
                    || leased.contains(String(name.dropLast(5))) || young
                {
                    try writeTombstone(context: context, label: label, name: name)
                    count.tombstoned += 1
                } else if try writer.removeOwnRegularFile(
                    folders: folders(label: label), name: name)
                {
                    count.deleted += 1
                }
            }
        }
        count.temporariesLeft = try deleteWriterLeftovers(context: context, label: label)
        let own = Set(try ownFileNames(context: context, label: label))
        count.skipped = try writer.listNames(folders: dir).filter {
            !own.contains($0) && !NoFollowWriter.isTemporaryName($0)
        }.count
        try writer.removeEmptyFolder(parent: [folder], name: label)
        return count
    }

    /// How many launch files of `label` may still carry a token: every one that is not a
    /// tombstone, a file that cannot be read included. Nothing but the count leaves this call.
    static func filesHoldingAToken(context: ToolContext, label: String) throws -> Int {
        try ownFileNames(context: context, label: label).filter { name in
            guard let object = object(context: context, label: label, name: name) else {
                return true
            }
            return !isTombstone(object)
        }.count
    }

    /// Whether the label's launch folder still holds a launch file that may carry a token, or a
    /// temporary file the writer left behind.
    static func hasLeftovers(context: ToolContext, label: String) throws -> Bool {
        if try filesHoldingAToken(context: context, label: label) > 0 { return true }
        let writer = NoFollowWriter(root: context.dataRoot)
        return !(try writer.leftoverTemporaries(folders: folders(label: label)).isEmpty)
    }
}

/// Whole-tree calls for `doctor` and `uninstall`. They return counts and ages only, never a name,
/// a path or any content of a launch file.
extension LaunchFiles {
    /// What the launch folders hold right now.
    public struct Inventory: Equatable, Sendable {
        /// Launch files the tool made, across every label.
        public var files = 0
        /// Of those, the files a session record still names. Zero when the records cannot be read.
        public var named = 0
        /// Age in seconds of the oldest launch file, or nil with no file.
        public var oldestAge: TimeInterval?
    }

    /// The labels that have a launch folder.
    static func labels(context: ToolContext) -> [String] {
        let writer = NoFollowWriter(root: context.dataRoot)
        return ((try? writer.listNames(folders: [folder])) ?? []).filter(
            ConfigValidator.isValidLabel)
    }

    public static func inventory(
        context: ToolContext, snapshot: SessionsSnapshot, now: Date
    ) -> Inventory {
        let writer = NoFollowWriter(root: context.dataRoot)
        var result = Inventory()
        for label in labels(context: context) {
            for name in (try? ownFileNames(context: context, label: label)) ?? [] {
                result.files += 1
                if snapshot.named.contains(
                    LaunchRef(label: label, leaseId: String(name.dropLast(5))))
                {
                    result.named += 1
                }
                if let info = try? writer.info(folders: folders(label: label), name: name) {
                    let age = max(0, now.timeIntervalSince(info.modified))
                    result.oldestAge = max(result.oldestAge ?? 0, age)
                }
            }
        }
        return result
    }

    /// What `removeEverything` did, summed over every label.
    struct WipeCount: Equatable {
        var deleted = 0
        var tombstoned = 0
        var skipped = 0
        var temporariesLeft = 0
    }

    /// Clears the launch files of every label as `removeAll` does for one: a file a session record
    /// names, an open lease holds, that is modified after `keepModifiedAfter`, or any file when
    /// the records cannot be read cleanly, becomes a tombstone and stays with its folders; every
    /// other file goes. The launch folder goes when it is empty. Callers hold the pick lock.
    static func removeEverything(
        context: ToolContext, snapshot: SessionsSnapshot, leased: Set<String>,
        keepModifiedAfter: Date
    ) throws -> WipeCount {
        var total = WipeCount()
        for label in labels(context: context) {
            let one = try removeAll(
                context: context, label: label, snapshot: snapshot, leased: leased,
                keepModifiedAfter: keepModifiedAfter)
            total.deleted += one.deleted
            total.tombstoned += one.tombstoned
            total.skipped += one.skipped
            total.temporariesLeft += one.temporariesLeft
        }
        try NoFollowWriter(root: context.dataRoot).removeEmptyFolder(parent: [], name: folder)
        return total
    }

    /// How many launch files across every label may still carry a token.
    static func tokenHolderCount(context: ToolContext) throws -> Int {
        try labels(context: context).reduce(0) {
            $0 + (try filesHoldingAToken(context: context, label: $1))
        }
    }
}

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

    /// Whether `name` is the name `fileName` gives a lease id, `l-<8 hex>.json`.
    static func isFileName(_ name: String) -> Bool {
        name.hasSuffix(".json") && isValidLeaseId(String(name.dropLast(5)))
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
            guard isFileName(name), let info = try? writer.info(folders: dir, name: name)
            else { return false }
            return info.isRegularFile && info.ownedByUser
        }
    }

    /// The value a tombstone holds in place of a token. It is not a token, so a session that reads
    /// the file fails to sign in instead of falling back to the stored login.
    static let tombstoneValue = "invalid"

    /// The most bytes of a launch file the tool reads.
    static let launchFileLimit = 65_536

    /// The JSON object of one launch file, or nil when it cannot be read or does not parse.
    private static func object(context: ToolContext, label: String, name: String) -> [String: Any]?
    {
        guard
            let data = try? NoFollowReader(root: context.dataRoot).read(
                folders: folders(label: label), name: name, limit: launchFileLimit)
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

    /// Writes `token`, the one the token store just saved for `label`, into every live launch file
    /// of the label that is not in `skipping`. A tombstone is never revived, and a file that
    /// carries no token, such as one a renamed `login` account's pick left under its old label,
    /// never gains one. A file that does not parse never keeps the old token: one a session record
    /// names (or any, when the records cannot be read cleanly) becomes a tombstone, and any other
    /// is deleted. Callers hold the pick lock.
    static func rewriteToken(
        context: ToolContext, label: String, token secret: TokenSecret, skipping: Set<String>,
        snapshot: SessionsSnapshot
    ) throws -> RewritePass {
        let token = secret.reveal()
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
            // A file with no token belongs to a session that runs on another sign-in.
            guard env[ProtectedEnv.tokenVariable] != nil else { continue }
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
    /// and left alone, and the label's folder goes when nothing else is in it. A name of a launch
    /// file's shape that `lstat` cannot check is not counted as one the tool did not make: it may
    /// be a launch file, and the caller's read-back stops on it. Callers hold the pick lock.
    static func removeAll(
        context: ToolContext, label: String, snapshot: SessionsSnapshot, leased: Set<String>,
        keepModifiedAfter: Date? = nil
    ) throws -> RemovalCount {
        let writer = NoFollowWriter(root: context.dataRoot)
        var count = try clearFiles(
            context: context, label: label, snapshot: snapshot, leased: leased,
            keepModifiedAfter: keepModifiedAfter, keepAll: false)
        count.temporariesLeft = try deleteWriterLeftovers(context: context, label: label)
        count.skipped = try strayCount(context: context, label: label, leavingOutUnchecked: true)
        try writer.removeEmptyFolder(parent: [folder], name: label)
        return count
    }

    /// The pass of `removeAll` over the launch files themselves: each is deleted or kept as a
    /// tombstone, and with `keepAll` every one is kept. The folder is listed again after each
    /// pass, so a file written meanwhile is handled too.
    private static func clearFiles(
        context: ToolContext, label: String, snapshot: SessionsSnapshot, leased: Set<String>,
        keepModifiedAfter: Date?, keepAll: Bool
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
                if keepAll || isNamed(name, label: label, snapshot: snapshot)
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
        return count
    }

    /// Entries in the label's folder that the tool did not make: neither a launch file of its own
    /// nor a name of the writer's temporary shape. With `leavingOutUnchecked`, a name of a launch
    /// file's shape that `lstat` cannot check is not counted either.
    private static func strayCount(
        context: ToolContext, label: String, leavingOutUnchecked: Bool = false
    ) throws -> Int {
        let writer = NoFollowWriter(root: context.dataRoot)
        let dir = folders(label: label)
        let own = Set(try ownFileNames(context: context, label: label))
        let unchecked = Set(
            leavingOutUnchecked ? writer.uncheckedNames(folders: dir, of: isFileName) : [])
        return try writer.listNames(folders: dir).filter {
            !own.contains($0) && !unchecked.contains($0) && !NoFollowWriter.isTemporaryName($0)
        }.count
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

    /// How many names of a launch file's shape in the label's folder `lstat` cannot check, such
    /// as a file whose access list denies its owner `readattr`. Each may hold a token. Nothing is
    /// opened.
    static func uncheckedFileCount(context: ToolContext, label: String) -> Int {
        NoFollowWriter(root: context.dataRoot).uncheckedCount(
            folders: folders(label: label), of: isFileName)
    }

    /// Whether the label's launch folder still holds a launch file that may carry a token, one
    /// that `remove` cannot check included, or a temporary file the writer left behind.
    static func hasLeftovers(context: ToolContext, label: String) throws -> Bool {
        if uncheckedForRemove(context: context, label: label, kept: .nothingDeleted) != nil {
            return true
        }
        if try filesHoldingAToken(context: context, label: label) > 0 { return true }
        let writer = NoFollowWriter(root: context.dataRoot)
        return !(try writer.leftoverTemporaries(folders: folders(label: label)).isEmpty)
    }
}

/// What `remove` does with launch files it cannot check (docs/ARCHITECTURE.md section 4A.4,
/// Removing): each may hold the token, so the remove stops before it deletes the token file, and
/// its text names the label's launch folder and the command that lets the tool check it again.
extension LaunchFiles {
    /// The label's launch folder as a person types it.
    static func typedFolder(label: String) -> String { "~/.agent-balancer/" + folder + "/" + label }

    /// What `remove` stops with when it cannot check the launch files of `label`, or nil when it
    /// can: the label's launch folder cannot be listed or searched, or a name of a launch file's
    /// shape in it cannot be checked with `lstat`. A label folder `lstat` cannot check, such as
    /// one whose access list denies you `readattr`, fails the folder checks, since that list
    /// cannot be read either, so it gets the cannot-be-checked text. Any other trouble with the
    /// launch folders stops the remove with the writer's refusal, as before. `kept` says what the
    /// stop kept.
    static func uncheckedForRemove(context: ToolContext, label: String, kept: TokenAccounts.Kept)
        -> String?
    {
        guard ConfigValidator.isValidLabel(label) else { return nil }
        let writer = NoFollowWriter(root: context.dataRoot)
        guard writer.opensForSearch(folders: [folder]) else { return nil }
        if !writer.opensForSearch(folders: folders(label: label)) {
            switch writer.placeEntry(parent: [folder], name: label) {
            case .problem(.cannotOpen): return folderCannotOpenText(label: label, kept: kept)
            case .problem(.cannotCheck): return folderCannotCheckText(label: label, kept: kept)
            default: break
            }
        }
        let count = uncheckedFileCount(context: context, label: label)
        return count > 0 ? uncheckedFilesText(label: label, count: count, kept: kept) : nil
    }

    /// Throws `uncheckedForRemove`'s text, so `remove` stops while a launch file it cannot check
    /// may hold the token. Callers hold the pick lock.
    static func requireCheckedForRemove(
        context: ToolContext, label: String, kept: TokenAccounts.Kept
    ) throws {
        if let stop = uncheckedForRemove(context: context, label: label, kept: kept) {
            throw ToolError(stop)
        }
    }

    /// What `remove` stops with when its label's launch folder is a real folder of the user's
    /// that cannot be opened or searched, such as one at 0600 or one whose access list denies its
    /// owner `list` or `search`. `lstat` showed it is not a link, so its commands take no `-h`,
    /// and `chmod -N` clears its list without opening it. A lock on it keeps `chmod` from
    /// changing it.
    static func folderCannotOpenText(label: String, kept: TokenAccounts.Kept) -> String {
        let place = typedFolder(label: label)
        return
            "The launch folder `\(place)` cannot be opened or searched, so `remove` cannot check whether a launch file in it holds a token.\(kept.sentence) Run `chmod -N \(place)`, then `chmod 700 \(place)`, and `chflags nouchg,nouappnd \(place)` first if it is locked, then run `agent-balancer remove \(label)` again."
    }

    /// What `remove` stops with when `lstat` cannot check its label's launch folder and the
    /// folder does not open to be searched. It may be a link, so `-h` keeps each command on the
    /// entry itself; `chmod -h -N` opens the entry, so `chmod -N` clears one whose list also
    /// denies its owner `list`, and `-N` goes first because `chmod -h 700` fails while `lstat`
    /// does.
    static func folderCannotCheckText(label: String, kept: TokenAccounts.Kept) -> String {
        let place = typedFolder(label: label)
        return
            "The launch folder `\(place)` cannot be checked, so `remove` cannot tell what it is or whether a launch file in it holds a token.\(kept.sentence) Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, then `chmod -h 700 \(place)`, then run `agent-balancer remove \(label)` again."
    }

    /// What `remove` stops with when names of a launch file's shape in its label's launch folder
    /// cannot be checked with `lstat`, such as a file whose access list denies its owner
    /// `readattr`. Each may be a link, so `-h` keeps `chmod` on the entry itself, and `chmod -N`
    /// clears one whose list also denies its owner `read`. The folder passed the folder checks,
    /// so `chmod -h -N` opens it and clears an entry it would pass on to a file written in it,
    /// and a lock on it would keep the rerun from deleting the files.
    static func uncheckedFilesText(label: String, count: Int, kept: TokenAccounts.Kept) -> String {
        let place = typedFolder(label: label)
        return
            "\(count) launch files of '\(label)' could not be checked and may hold a token.\(kept.sentence) Run `chmod -h -N \(place)`, and run `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg,nouappnd \(place)` first if it is locked. Then run `agent-balancer remove \(label)` again."
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

    /// The labels that have a launch folder: real folders the user owns, never a link.
    static func labels(context: ToolContext) -> [String] {
        let writer = NoFollowWriter(root: context.dataRoot)
        return ((try? writer.listFolders(folders: [folder])) ?? []).filter(
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

    /// Throws, so `uninstall` refuses before it removes anything, when the launch folder is there
    /// but is not a real folder of the user's that passes the folder checks (a link, a file or
    /// another user's folder), or a label's folder in it is a real folder of the user's that
    /// fails them. A link, a file or another user's folder where a label's folder belongs is not
    /// refused: `clearForUninstall` counts it.
    static func requireCheckableForUninstall(context: ToolContext) throws {
        let writer = NoFollowWriter(root: context.dataRoot)
        let place = "~/.agent-balancer/" + folder
        let entry = writer.placeEntry(parent: [], name: folder)
        if let refusal = Messages.uninstallRefusal("The launch folder", place, entry) {
            throw ToolError(refusal)
        }
        for label in labels(context: context) {
            if let problem = writer.folderProblem(parent: [folder], name: label) {
                throw ToolError(
                    Messages.uninstallFolderRefused(
                        "The launch folder", place + "/" + label, problem))
            }
        }
    }

    /// Throws the refusal of the launch folder or the label's folder in it when either is there
    /// and fails the folder checks. A missing one passes, since a token save only rewrites the
    /// launch files that are there.
    static func requireOpenable(context: ToolContext, label: String) throws {
        guard ConfigValidator.isValidLabel(label) else { throw ToolError("Label is not valid.") }
        let dir = try NoFollowWriter.openFolder(
            root: context.dataRoot, folders: folders(label: label), create: false)
        if dir >= 0 { close(dir) }
    }

    /// The launch folder and the label's folder in it, when they are there, which a token save
    /// opens before it deletes the stored reading (`requireOpenable`).
    static func openTargets(context: ToolContext, label: String) -> [NoFollowWriter.Target] {
        guard ConfigValidator.isValidLabel(label) else { return [] }
        let writer = NoFollowWriter(root: context.dataRoot)
        guard (try? writer.folderEntry(parent: [], name: folder)) != .missing else { return [] }
        let labelFolder = try? writer.folderEntry(parent: [folder], name: label)
        return [.folder([folder], [.open])]
            + (labelFolder == .missing ? [] : [.folder(folders(label: label), [.open])])
    }

    /// What a token save does in the label's launch folder (`rewriteToken` and
    /// `deleteWriterLeftovers`): each launch file of the tool's there now is replaced, or deleted
    /// when it does not parse, and each of the writer's leftover temporary files is deleted. A
    /// name of a launch file's shape that `lstat` cannot check is a target too, since its file
    /// may hold the old token and the rewrite cannot reach it. A refusal names the folder, never
    /// a launch file.
    static func rewriteTargets(context: ToolContext, label: String) -> [NoFollowWriter.Target] {
        guard ConfigValidator.isValidLabel(label) else { return [] }
        let writer = NoFollowWriter(root: context.dataRoot)
        let dir = folders(label: label)
        let names = (try? writer.listNames(folders: dir)) ?? []
        let place = NoFollowWriter.place(dir)
        let shown = NoFollowWriter.Shown(
            subject: "a launch file in `\(place)`", path: place + "/l-*.json")
        var targets: [NoFollowWriter.Target] = []
        for name in names where isFileName(name) {
            let own: Bool
            do {
                let info = try writer.checkedInfo(folders: dir, name: name)
                own = info.map { $0.isRegularFile && $0.ownedByUser } ?? false
            } catch {
                own = true
            }
            guard own else { continue }
            var target = NoFollowWriter.Target.file(
                dir, name, [.read, .replace, .delete], readLimit: launchFileLimit)
            target.shown = shown
            targets.append(target)
        }
        let leftovers = (try? writer.leftoverTemporaries(folders: dir)) ?? []
        return targets + leftovers.map { .file(dir, $0, [.delete]) }
    }

    /// What `doctor` says about the launch folder and each label's folder in it when the folder
    /// checks refuse it for its mode or its access list or it cannot be opened, searched or
    /// checked, and about each label's folder that holds a launch file whose access list lets
    /// another user or group in, cannot be read, or keeps `lstat` out, each with the commands
    /// that clear it, and about each writer's temporary file there with such a list, by its
    /// path, as in the token folder. What is in a folder refused for its mode or its list is
    /// checked in the same run; what is in one that cannot be opened or checked, once it can. It
    /// never names a launch file, whose name is a lease id.
    public static func accessListProblems(context: ToolContext) -> [String] {
        let writer = NoFollowWriter.forDoctor(root: context.dataRoot)
        let place = NoFollowWriter.dataFolderPlace + "/" + folder
        let top = writer.doctorVerdict(parent: [], name: folder)
        var found = top.line.map { [$0] } ?? []
        guard top.readable else { return found }
        let names = (try? writer.listNames(folders: [folder])) ?? []
        for label in names where ConfigValidator.isValidLabel(label) {
            let verdict = writer.doctorVerdict(parent: [folder], name: label)
            if let line = verdict.line { found.append(line) }
            guard verdict.readable else { continue }
            let inside = folders(label: label)
            let files = (try? writer.listNames(folders: inside)) ?? []
            let shared = files.contains { name in
                isFileName(name) && writer.fileListProblem(folders: inside, name: name) != nil
            }
            if shared { found.append(Messages.doctorLaunchFilesShared(place + "/" + label)) }
            for name in files where NoFollowWriter.isTemporaryName(name) {
                guard let problem = writer.fileListProblem(folders: inside, name: name) else {
                    continue
                }
                found.append(Messages.doctorFileProblem(place + "/" + label + "/" + name, problem))
            }
        }
        return found
    }

    /// What `clearForUninstall` did, summed over every label.
    struct WipeCount: Equatable {
        var deleted = 0
        var tombstoned = 0
        /// Entries the tool did not make, left alone: a name in the launch folder that is not a
        /// label, and anything among a label's launch files.
        var skipped = 0
        /// Entries named like a label only in other letter case, never opened.
        var otherCase = 0
        /// Entries where a label's folder belongs that are not a real folder of the user's (a
        /// link, a file or another user's folder) or that `lstat` cannot check, never followed or
        /// opened.
        var notFollowed = 0
        /// How many of `notFollowed` `lstat` cannot check.
        var unchecked = 0
    }

    /// How many entries in the launch folder have a label's name but are not a real folder of the
    /// user's: a link, which may lead to the label's launch files, a file, another user's folder,
    /// or one `lstat` cannot check, which `unchecked` counts again. `lstat` only; nothing is
    /// followed or opened.
    static func notFollowedEntryCount(context: ToolContext) -> (all: Int, unchecked: Int) {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard let names = try? writer.listNames(folders: [folder]),
            let real = try? writer.listFolders(folders: [folder])
        else { return (0, 0) }
        let folders = Set(real)
        let entries = names.filter { ConfigValidator.isValidLabel($0) && !folders.contains($0) }
        return (entries.count, entries.filter { isUnchecked(writer, $0) }.count)
    }

    /// Whether `lstat` cannot check `name` in the launch folder, such as a folder whose access
    /// list denies its owner. Such an entry may be anything.
    static func isUnchecked(_ writer: NoFollowWriter, _ name: String) -> Bool {
        do {
            _ = try writer.checkedInfo(folders: [folder], name: name)
            return false
        } catch {
            return true
        }
    }

    /// What `uninstall` says about entries where a label's folder belongs that it did not follow.
    public static func notFollowedEntriesText(_ count: Int) -> String {
        "\(count) entries in `~/.agent-balancer/launch/` where a label's folder belongs are a link, a file or another user's folder, so a launch file with a token may be behind them, and `uninstall` did not follow them. Move the folder each link points to back in place of the link, delete a link that points nowhere, and move any other entry out of `~/.agent-balancer`, then run `agent-balancer uninstall` again."
    }

    /// What `uninstall` says about entries where a label's folder belongs that `lstat` could not
    /// check, so it could not tell what they are. One may be a link with an access list of its
    /// own, so `-h` keeps `chmod` off the folder it points to; `chmod -h -N` opens the entry, so
    /// `chmod -N` clears one whose access list also denies its owner `read`.
    public static func uncheckedEntriesText(_ count: Int) -> String {
        "\(count) entries in `~/.agent-balancer/launch/` where a label's folder belongs could not be checked, so a launch file with a token may be in them, and `uninstall` did not open them. Run `chmod -h -N` on each entry there, or `chmod -N` where that says Permission denied, then run `agent-balancer uninstall` again."
    }

    /// What `uninstall` stops with when a launch file may still hold a token or could not be
    /// overwritten: a folder that is not writable, a lock, or an access list that denies the owner
    /// on a launch file or its folder, inherited or not, stops the step until the person clears
    /// it. It names only the label folders that are real folders, which passed the folder checks
    /// and so open for `chmod -h -N`; a link there is counted on its own.
    public static let notClearedText =
        "A launch file could not be cleared, so the token files were kept. On each label's folder in `~/.agent-balancer/launch/` that is not a link, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg` first on any of them that is locked. Then run `agent-balancer uninstall` again."

    /// Whether `name` in the launch folder is a label only once its letter case is folded, such
    /// as `Pool-a`. On a volume that ignores case, a launch file for that label is written into
    /// such a folder, so it may hold a token.
    static func isOtherCaseLabel(_ name: String) -> Bool {
        !ConfigValidator.isValidLabel(name) && ConfigValidator.isValidLabel(Paths.caseFolded(name))
    }

    /// How many entries in the launch folder are named like a label only in other letter case.
    /// Names only; nothing is opened.
    static func otherCaseEntryCount(context: ToolContext) -> Int {
        let names = (try? NoFollowWriter(root: context.dataRoot).listNames(folders: [folder])) ?? []
        return names.filter(isOtherCaseLabel).count
    }

    /// `uninstall`'s pass over the launch files of every label, as `removeAll` does for one: a
    /// file a session record names, an open lease holds, that is modified after
    /// `keepModifiedAfter`, any file when the records cannot be read cleanly, and every file
    /// with `keepAll`, becomes a tombstone and stays; every other file goes. An entry where the
    /// launch folder belongs that is not a real folder of the user's is counted and never
    /// followed. An entry where a label's folder belongs that is not one, and one named like a
    /// label only in other letter case, may lead to launch files that hold a token: each is
    /// counted on its own and never followed or opened. A folder of the user's that is not
    /// private stops the pass, before any token file goes, and so does a label's launch file that
    /// cannot be cleared, with `notClearedText`. The writer's leftovers and the folders stay for
    /// a later step. Callers hold the pick lock.
    static func clearForUninstall(
        context: ToolContext, snapshot: SessionsSnapshot, leased: Set<String>,
        keepModifiedAfter: Date, keepAll: Bool
    ) throws -> WipeCount {
        let writer = NoFollowWriter(root: context.dataRoot)
        var total = WipeCount()
        switch try writer.folderEntry(parent: [], name: folder) {
        case .missing: return total
        case .other:
            total.skipped += 1
            return total
        case .folder: break
        }
        let real = Set(try writer.listFolders(folders: [folder]))
        for name in try writer.listNames(folders: [folder]) {
            if isOtherCaseLabel(name) {
                total.otherCase += 1
                continue
            }
            guard ConfigValidator.isValidLabel(name) else {
                total.skipped += 1
                continue
            }
            guard real.contains(name) else {
                total.notFollowed += 1
                if isUnchecked(writer, name) { total.unchecked += 1 }
                continue
            }
            let one: RemovalCount
            do {
                one = try clearFiles(
                    context: context, label: name, snapshot: snapshot, leased: leased,
                    keepModifiedAfter: keepModifiedAfter, keepAll: keepAll)
            } catch is ToolError {
                // The writer's text names no fix, and the file may still hold its token.
                throw ToolError(notClearedText)
            }
            total.deleted += one.deleted
            total.tombstoned += one.tombstoned
            total.skipped += try strayCount(context: context, label: name)
        }
        return total
    }

    /// `uninstall`'s writer leftovers step for the launch folders: the writer's leftover
    /// temporary files in each label's folder go, then each folder left empty, then the launch
    /// folder when it is empty. It never throws. Returns how many names of the temporary shape
    /// are still there.
    static func tidyForUninstall(context: ToolContext) -> Int {
        let writer = NoFollowWriter(root: context.dataRoot)
        var left = 0
        for label in labels(context: context) {
            left += (try? deleteWriterLeftovers(context: context, label: label)) ?? 0
            _ = try? writer.removeEmptyFolder(parent: [folder], name: label)
        }
        _ = try? writer.removeEmptyFolder(parent: [], name: folder)
        return left
    }

    /// How many launch files across every label may still carry a token, with each launch file's
    /// name that `lstat` cannot check, such as in a label's folder the user cannot search.
    static func tokenHolderCount(context: ToolContext) throws -> Int {
        try labels(context: context).reduce(uncheckedFileCount(context: context)) {
            $0 + (try filesHoldingAToken(context: context, label: $1))
        }
    }

    /// How many names of a launch file's shape in the labels' folders `lstat` cannot check. Each
    /// may hold a token. Nothing is opened.
    static func uncheckedFileCount(context: ToolContext) -> Int {
        labels(context: context).reduce(0) { $0 + uncheckedFileCount(context: context, label: $1) }
    }

    /// How many names of the writer's temporary shape in the labels' folders `lstat` cannot
    /// check. Each may hold a whole launch file, token included. Nothing is opened.
    static func uncheckedTemporaryCount(context: ToolContext) -> Int {
        let writer = NoFollowWriter(root: context.dataRoot)
        let shape = NoFollowWriter.isTemporaryName
        return labels(context: context).reduce(0) {
            $0 + writer.uncheckedCount(folders: folders(label: $1), of: shape)
        }
    }
}

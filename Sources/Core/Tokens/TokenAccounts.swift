import Foundation

/// What a command may ask of the token store and the launch files of one label: install a token,
/// replace one, remove an account's files. Every call takes the pick lock, so a pick never writes
/// a launch file between the steps (docs/ARCHITECTURE.md section 4A.4). Nothing here returns a
/// token or a path.
public enum TokenAccounts {
    /// What an install did.
    public struct Installed: Equatable, Sendable {
        /// True when a token file was already there, so this was a replace.
        public let replaced: Bool
        /// The launch files of the label that now carry the new token.
        public let launchFilesRewritten: Int
    }

    /// What a removal did.
    public struct Removed: Equatable, Sendable {
        public let tokenFile: Bool
        public let launchFiles: Int
        /// Launch files kept as tombstones: a session record names them, their lease is open, or
        /// the records could not be read cleanly. They hold no token and go once nothing needs
        /// them.
        public let launchFilesKept: Int
        /// Entries among the label's launch files that the tool did not make, left alone.
        public let launchEntriesSkipped: Int
        /// Names of the writer's temporary shape still in `tokens/` or the label's launch folder
        /// after the remove deleted the writer's leftovers there: entries it could not delete.
        public let temporariesLeft: Int

        public init(
            tokenFile: Bool, launchFiles: Int, launchFilesKept: Int = 0,
            launchEntriesSkipped: Int = 0, temporariesLeft: Int = 0
        ) {
            self.tokenFile = tokenFile
            self.launchFiles = launchFiles
            self.launchFilesKept = launchFilesKept
            self.launchEntriesSkipped = launchEntriesSkipped
            self.temporariesLeft = temporariesLeft
        }
    }

    static let lockWaitSeconds: TimeInterval = 30

    private static func takeLock(_ context: ToolContext) throws -> FileLock {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard
            let lock = try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: lockWaitSeconds)
        else { throw ToolError("Another pick is running. Try again in a moment.") }
        return lock
    }

    /// Writes the token file and rewrites every live launch file of the label with the new token.
    /// The label's launch files are listed again until a pass finds none it has not handled, so a
    /// file that appeared during the rewrite is not missed. A tombstone stays a tombstone. The
    /// writer's leftover temporary files in `tokens/` and the label's launch folder are deleted.
    ///
    /// With `requireAccount`, what `login` passes, the registry must still hold `label` as a token
    /// account when the lock is held, right before the write; otherwise nothing is written, so a
    /// `login` that a `remove` overtook never leaves a token file with no account.
    static func install(
        context: ToolContext, label: String, token: String, snapshot: SessionsSnapshot? = nil,
        requireAccount: Bool = false
    ) throws -> Installed {
        guard TokenStore.isPlausible(token) else {
            throw ToolError("The token does not have a usable shape.")
        }
        let lock = try takeLock(context)
        defer { lock.release() }
        try TokenStore.deleteWriterLeftovers(context: context)
        let existed = (try TokenPaths.facts(context: context, label: label)).exists
        if requireAccount {
            let config = try ConfigStore(context: context).load()
            guard config?.account(label)?.kind == Kind.token else {
                throw ToolError(
                    "No account is labelled '\(Display.safe(label))' any more, so the token was not saved."
                )
            }
        }
        try TokenStore.save(context: context, label: label, token: token)
        let records = snapshot ?? SessionsReader.read(context: context)
        var handled = Set<String>()
        var rewritten = 0
        var passes = 0
        while passes < 5 {
            passes += 1
            let pass = try LaunchFiles.rewriteToken(
                context: context, label: label, skipping: handled, snapshot: records)
            if pass.handled.isEmpty { break }
            handled.formUnion(pass.handled)
            rewritten += pass.rewritten
        }
        try LaunchFiles.deleteWriterLeftovers(context: context, label: label)
        return Installed(replaced: existed, launchFilesRewritten: rewritten)
    }

    /// Removes what the tool keeps for `label`, under the pick lock, in this order: the launch
    /// files (each kept as a tombstone when a session record names it, its lease is open or the
    /// records cannot be read cleanly, else deleted, listed again until no new file shows up) and
    /// the writer's leftover temporary files in the label's launch folder, the label's leases, a
    /// read-back that no launch file of the label holds a token, the writer's leftover temporary
    /// files in `tokens/`, the token file, the stored reading, and last `finish`, where the caller
    /// deletes the registry entry while the lock is still held. A crash at any step leaves a state
    /// that a rerun finishes. Works for an account of any kind.
    public static func removeFiles(
        context: ToolContext, label: String,
        leaseMinutes: Int = PickerSettings().leaseMinutes, snapshot: SessionsSnapshot? = nil,
        keepsRecentPicks: Bool = true, finish: () throws -> Void = {}
    ) throws -> Removed {
        let lock = try takeLock(context)
        defer { lock.release() }
        let now = Date()
        let leaseStore = LeaseStore(context: context)
        let leases = try leaseStore.current(now: now, leaseMinutes: 525_600)
        let span = Double(max(1, leaseMinutes)) * 60
        // A recent pick's file is kept as a tombstone so its session can still start. A folder
        // account's files hold no token, so its remove drops them and the leases together.
        let open =
            keepsRecentPicks
            ? Set(
                leases.filter { $0.label == label && now.timeIntervalSince($0.at) < span }.map(\.id)
            )
            : []
        let launch = try LaunchFiles.removeAll(
            context: context, label: label,
            snapshot: snapshot ?? SessionsReader.read(context: context), leased: open)
        if leases.contains(where: { $0.label == label }) {
            try leaseStore.save(leases.filter { $0.label != label })
        }
        guard try LaunchFiles.filesHoldingAToken(context: context, label: label) == 0 else {
            throw ToolError(
                "A launch file of '\(Display.safe(label))' could not be cleared, so its token file and account were kept. Run `agent-balancer remove \(label)` again."
            )
        }
        let temporaries = try TokenStore.deleteWriterLeftovers(context: context)
        let token = try TokenStore.delete(context: context, label: label)
        try ReadingStore(context: context).delete(label: label)
        try finish()
        return Removed(
            tokenFile: token, launchFiles: launch.deleted, launchFilesKept: launch.tombstoned,
            launchEntriesSkipped: launch.skipped,
            temporariesLeft: temporaries + launch.temporariesLeft)
    }

    /// `remove`: everything `removeFiles` deletes, then the registry entry of `label`, dropped from
    /// a config loaded and saved while the pick lock is still held, so a `login` waiting on the
    /// lock finds the entry gone and an entry another command saved after `config` was loaded is
    /// kept. `config` gives only the lease span. With no entry, it finishes a remove that stopped
    /// part way.
    public static func removeAccount(
        context: ToolContext, label: String, config: Config, keepsRecentPicks: Bool = true
    ) throws -> Removed {
        try removeFiles(
            context: context, label: label, leaseMinutes: config.picker.leaseMinutes,
            keepsRecentPicks: keepsRecentPicks
        ) {
            let store = ConfigStore(context: context)
            guard var fresh = try store.load(),
                let index = fresh.accounts.firstIndex(where: { $0.label == label })
            else { return }
            fresh.accounts.remove(at: index)
            try store.save(fresh, backup: true)
        }
    }

    /// Loads the config under the pick lock, applies `change` and saves the result before the
    /// lock goes, so two commands that edit the registry at once never save over each other.
    /// With no config it throws before taking the lock, so nothing is made before `init`.
    /// Returns the config as saved.
    @discardableResult
    public static func updateConfig(
        context: ToolContext, backup: Bool = false, _ change: (inout Config) throws -> Void
    ) throws -> Config {
        let store = ConfigStore(context: context)
        _ = try store.loadRequired()
        let lock = try takeLock(context)
        defer { lock.release() }
        var config = try store.loadRequired()
        try change(&config)
        try store.save(config, backup: backup)
        return config
    }

    /// How many temporary files the writer left in `tokens/` and the launch folders when a write
    /// stopped before its rename. Each may hold a token until the next remove, replace or upkeep
    /// deletes it. Names only; nothing is opened.
    public static func writerLeftovers(context: ToolContext) -> Int {
        TokenStore.writerLeftoverCount(context: context)
            + LaunchFiles.writerLeftoverCount(context: context)
    }

    /// Whether anything `removeFiles` deletes is still there for `label`: the token file, a launch
    /// file that may hold a token, a writer's leftover temporary file, a lease or a stored reading.
    /// A rerun of `remove` for a label that has no registry entry goes ahead only then.
    public static func hasLeftovers(context: ToolContext, label: String) throws -> Bool {
        if try TokenPaths.facts(context: context, label: label).exists { return true }
        if try LaunchFiles.hasLeftovers(context: context, label: label) { return true }
        let leases = try LeaseStore(context: context).current(now: Date(), leaseMinutes: 525_600)
        if leases.contains(where: { $0.label == label }) { return true }
        return (try? ReadingStore(context: context).load(label: label)) != nil
    }

    /// The labels that have a token file but no account in `config`, such as after a `remove`
    /// that stopped before its end. Reads names only, never a file.
    public static func labelsWithoutAccount(context: ToolContext, config: Config) -> [String] {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard let names = try? writer.listNames(folders: TokenPaths.folders) else { return [] }
        return names.compactMap { name -> String? in
            guard name.hasSuffix(".json") else { return nil }
            let label = String(name.dropLast(5))
            guard ConfigValidator.isValidLabel(label), config.account(label) == nil else {
                return nil
            }
            return label
        }
    }

    /// What `uninstall` lists before it asks: counts only, no name and no path.
    public struct Inventory: Equatable, Sendable {
        public var tokenFiles: Int
        public var launchFiles: Int
        /// Launch files a session record still names.
        public var launchFilesNamed: Int
        /// False when the session records could not be read cleanly, so every launch file is kept
        /// as a tombstone.
        public var recordsReadable: Bool
        /// Age in seconds of the oldest launch file, or nil with none.
        public var oldestLaunchAge: TimeInterval?
        public var openLeases: Int
    }

    public static func inventory(
        context: ToolContext, leaseMinutes: Int = PickerSettings().leaseMinutes,
        snapshot: SessionsSnapshot? = nil, now: Date = Date()
    ) -> Inventory {
        let records = snapshot ?? SessionsReader.read(context: context)
        let launch = LaunchFiles.inventory(context: context, snapshot: records, now: now)
        return Inventory(
            tokenFiles: TokenStore.fileCount(context: context), launchFiles: launch.files,
            launchFilesNamed: launch.named, recordsReadable: records.clean,
            oldestLaunchAge: launch.oldestAge,
            openLeases: openLeaseCount(context: context, leaseMinutes: leaseMinutes, now: now))
    }

    /// How many leases are open: a pick younger than `leaseMinutes`.
    public static func openLeaseCount(
        context: ToolContext, leaseMinutes: Int, now: Date = Date()
    ) -> Int {
        ((try? LeaseStore(context: context).current(now: now, leaseMinutes: leaseMinutes)) ?? [])
            .count
    }

    /// What `removeEverything` did.
    public struct Wiped: Equatable, Sendable {
        public let tokenFiles: Int
        public let launchFiles: Int
        /// Launch files kept as tombstones: a session record names them, their lease is open, they
        /// are younger than `leaseMinutes`, or the records could not be read cleanly. They hold
        /// no token.
        public let launchFilesKept: Int
        /// Entries among the token and launch files that the tool did not make, left alone.
        public let entriesSkipped: Int
        public let temporariesLeft: Int
    }

    /// `uninstall`'s step for the token and launch folders, under the pick lock: every launch file
    /// of every label is deleted, or overwritten with a token-free tombstone and kept when a
    /// session record names it, an open lease holds it, it is younger than `leaseMinutes`, or the
    /// records cannot be read cleanly; then a read-back that no launch file holds a token; then
    /// every token file. A crash at any step leaves a state that a rerun finishes.
    public static func removeEverything(
        context: ToolContext, leaseMinutes: Int = PickerSettings().leaseMinutes,
        snapshot: SessionsSnapshot? = nil, now: Date = Date()
    ) throws -> Wiped {
        let lock = try takeLock(context)
        defer { lock.release() }
        let span = Double(max(1, leaseMinutes)) * 60
        let open = try LeaseStore(context: context).current(now: now, leaseMinutes: leaseMinutes)
        let launch = try LaunchFiles.removeEverything(
            context: context, snapshot: snapshot ?? SessionsReader.read(context: context),
            leased: Set(open.map(\.id)), keepModifiedAfter: now.addingTimeInterval(-span))
        guard try LaunchFiles.tokenHolderCount(context: context) == 0 else {
            throw ToolError(
                "A launch file could not be cleared, so the token files were kept. Run `agent-balancer uninstall` again."
            )
        }
        let tokens = try TokenStore.deleteAll(context: context)
        return Wiped(
            tokenFiles: tokens.deleted, launchFiles: launch.deleted,
            launchFilesKept: launch.tombstoned, entriesSkipped: tokens.skipped + launch.skipped,
            temporariesLeft: launch.temporariesLeft)
    }
}

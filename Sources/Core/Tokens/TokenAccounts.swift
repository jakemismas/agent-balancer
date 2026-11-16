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

    static func takeLock(_ context: ToolContext) throws -> FileLock {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard
            let lock = try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: lockWaitSeconds)
        else { throw ToolError("Another pick is running. Try again in a moment.") }
        return lock
    }

    /// How long a command waits for a label's probe lock: a refresh holds it through the plain
    /// probe, the Fable probe and the sign-in checks around them, and also through the status
    /// rebuilds that record them, which this wait does not count.
    static func probeLockWait(_ config: Config?) -> TimeInterval {
        let probe = config?.probe.timeoutSeconds ?? ProbeSettings().timeoutSeconds
        let fable = config?.fable.probeTimeoutSeconds ?? FableSettings().probeTimeoutSeconds
        return Double(probe + fable) + 60
    }

    /// The probe lock of each of `labels`, taken in name order, for a command that changes which
    /// sign-in a label stands for, while it holds the pick lock. A refresh holds a label's probe
    /// lock from its registry check to its saved reading, so with these held no probe of the old
    /// sign-in saves a reading after the change, and one that waited checks the registry anew.
    public static func takeProbeLocks(context: ToolContext, labels: [String], config: Config?)
        throws -> [FileLock]
    {
        let writer = NoFollowWriter(root: context.dataRoot)
        var held: [FileLock] = []
        for label in Set(labels).sorted() {
            guard
                let lock = try writer.acquireLock(
                    folders: Layout.locksFolders, name: Layout.lockName(label),
                    wait: probeLockWait(config))
            else {
                for lock in held { lock.release() }
                throw ToolError(
                    "A check of '\(Display.safe(label))' is still running, so nothing was changed. Try again in a moment."
                )
            }
            held.append(lock)
        }
        return held
    }

    /// Writes the token file and rewrites every live launch file of the label that carries a token
    /// with the new one. The label's launch files are listed again until a pass finds none it has
    /// not handled, so a file that appeared during the rewrite is not missed. A tombstone stays a
    /// tombstone. The writer's leftover temporary files in `tokens/` and the label's launch folder
    /// are deleted. Every save, a first one included, also takes the label's probe lock and then
    /// deletes the label's stored reading before it writes the token file, so the next probe
    /// stores a reading of the new token alone, also when the token file went missing while the
    /// reading stayed.
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
        let config = requireAccount || existed ? try ConfigStore(context: context).load() : nil
        if requireAccount {
            guard config?.account(label)?.kind == Kind.token else {
                throw ToolError(
                    "No account is labelled '\(Display.safe(label))' any more, so the token was not saved."
                )
            }
        }
        let probeLocks = try takeProbeLocks(context: context, labels: [label], config: config)
        defer { for probeLock in probeLocks { probeLock.release() } }
        // A reading taken under another token would judge this one.
        try ReadingStore(context: context).delete(label: label)
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
    /// that a rerun finishes. Works for an account of any kind. `before` runs first, under the
    /// lock; when it throws, nothing is deleted.
    public static func removeFiles(
        context: ToolContext, label: String,
        leaseMinutes: Int = PickerSettings().leaseMinutes, snapshot: SessionsSnapshot? = nil,
        keepsRecentPicks: Bool = true, before: () throws -> Void = {},
        finish: () throws -> Void = {}
    ) throws -> Removed {
        let lock = try takeLock(context)
        defer { lock.release() }
        try before()
        let now = Date()
        let leaseStore = LeaseStore(context: context)
        let leases = try leaseStore.current(now: now, leaseMinutes: 525_600)
        let span = Double(max(1, leaseMinutes)) * 60
        // A recent pick's file is kept as a tombstone so its session can still start. A folder
        // account's files hold no token, so its remove drops them and the leases together.
        let open =
            keepsRecentPicks
            ? Set(leases.filter { now.timeIntervalSince($0.at) < span }.map(\.id)) : []
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
    /// part way. `before` gets the config as it is once the lock is held, ahead of the first
    /// delete, so a check in it sees a role change that `config set-main` saved under the same
    /// lock; when it throws, nothing is deleted. The entry is deleted only while it is still the
    /// account `before` saw under that label (the same `accountKey`); otherwise the remove stops
    /// and keeps it.
    public static func removeAccount(
        context: ToolContext, label: String, config: Config, keepsRecentPicks: Bool = true,
        before: (Config?) throws -> Void = { _ in }
    ) throws -> Removed {
        var checkedKey: String?
        return try removeFiles(
            context: context, label: label, leaseMinutes: config.picker.leaseMinutes,
            keepsRecentPicks: keepsRecentPicks,
            before: {
                let fresh = try ConfigStore(context: context).load()
                try before(fresh)
                checkedKey = fresh?.account(label)?.accountKey
            },
            finish: {
                let store = ConfigStore(context: context)
                guard var fresh = try store.load(),
                    let index = fresh.accounts.firstIndex(where: { $0.label == label })
                else { return }
                guard fresh.accounts[index].accountKey == checkedKey else {
                    throw ToolError(
                        "The account labelled '\(Display.safe(label))' changed while it was being removed, so its entry was kept. Run `agent-balancer remove \(Display.safe(label))` again."
                    )
                }
                fresh.accounts.remove(at: index)
                try store.save(fresh, backup: true)
            })
    }

    /// What a rename moves from a `login` account's old label to its new one, under the pick lock
    /// and both labels' probe locks the caller holds: its stored reading, which replaces any
    /// reading stored earlier under the new label (none is left there when the account has none),
    /// and its leases, so its open picks count for it. No reading stays under the old label. A
    /// launch file stays where its pick wrote it. This call reads the reading and the leases, so a
    /// file that cannot be read stops the rename before anything changes, and deletes a reading
    /// stored earlier under the new label, which no account holds. The step it returns moves
    /// them; the caller runs it once the registry holds the new label, so a refused save moves
    /// nothing.
    public static func moveLabel(context: ToolContext, from old: String, to new: String) throws
        -> () throws -> Void
    {
        let store = ReadingStore(context: context)
        let reading = try store.load(label: old)
        let leases = LeaseStore(context: context)
        let all = try leases.current(now: Date(), leaseMinutes: 525_600)
        try store.delete(label: new)
        return {
            if let reading { try store.save(reading, label: new) }
            try store.delete(label: old)
            guard all.contains(where: { $0.label == old }) else { return }
            try leases.save(
                all.map { lease in
                    var moved = lease
                    if moved.label == old { moved.label = new }
                    return moved
                })
        }
    }

    /// Loads the config under the pick lock, applies `change`, saves the result and then runs
    /// `afterSave` before the lock goes, so two commands that edit the registry at once never
    /// save over each other. With no config it throws before taking the lock, so nothing is made
    /// before `init`. Returns the config as saved.
    @discardableResult
    public static func updateConfig(
        context: ToolContext, backup: Bool = false, _ change: (inout Config) throws -> Void,
        afterSave: () throws -> Void = {}
    ) throws -> Config {
        let store = ConfigStore(context: context)
        _ = try store.loadRequired()
        let lock = try takeLock(context)
        defer { lock.release() }
        var config = try store.loadRequired()
        try change(&config)
        try store.save(config, backup: backup)
        try afterSave()
        return config
    }

    /// `init`'s save, under the pick lock like every other registry writer: `make` gets the
    /// config as it is once the lock is held, or nil when there is none yet, and what it returns
    /// is saved before the lock goes. A config that was there goes to `backups/` first.
    @discardableResult
    public static func setUpConfig(
        context: ToolContext, _ make: (Config?) throws -> Config
    ) throws -> Config {
        let store = ConfigStore(context: context)
        let lock = try takeLock(context)
        defer { lock.release() }
        let config = try make(try store.load())
        try store.save(config, backup: true)
        return config
    }

    /// How many temporary files the writer left in `tokens/` and the launch folders when a write
    /// stopped before its rename. Each may hold a token until the next remove, replace or upkeep
    /// deletes it. Names only; nothing is opened.
    public static func writerLeftovers(context: ToolContext) -> Int {
        TokenStore.writerLeftoverCount(context: context)
            + LaunchFiles.writerLeftoverCount(context: context)
    }

    /// The temporary files `uninstall` counts as may hold a token: those `writerLeftovers` counts,
    /// with each name of their shape in `tokens/` or a label's launch folder that `lstat` cannot
    /// check, such as in a folder the user cannot search.
    static func temporariesForUninstall(context: ToolContext) -> Int {
        writerLeftovers(context: context) + TokenStore.uncheckedTemporaryCount(context: context)
            + LaunchFiles.uncheckedTemporaryCount(context: context)
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
        /// Launch files a session record still names. With records that could not all be read,
        /// at least this many.
        public var launchFilesNamed: Int
        /// False when the session records could not be read cleanly, so every launch file is kept
        /// as a tombstone.
        public var recordsReadable: Bool
        /// False when the lease file is there but cannot be read or decoded, so every launch file
        /// is kept as a tombstone.
        public var leasesReadable: Bool
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
        let leases = LeaseStore(context: context).currentIfReadable(
            now: now, leaseMinutes: leaseMinutes)
        // A launch file's name that cannot be checked may hold a token, so it is listed too.
        let launchFiles = launch.files + LaunchFiles.uncheckedFileCount(context: context)
        return Inventory(
            tokenFiles: TokenStore.fileCount(context: context), launchFiles: launchFiles,
            launchFilesNamed: launch.named, recordsReadable: records.clean,
            leasesReadable: leases != nil, oldestLaunchAge: launch.oldestAge,
            openLeases: openLeaseCount(context: context, leaseMinutes: leaseMinutes, now: now))
    }

    /// How many leases are open: a pick younger than `leaseMinutes`.
    public static func openLeaseCount(
        context: ToolContext, leaseMinutes: Int, now: Date = Date()
    ) -> Int {
        ((try? LeaseStore(context: context).current(now: now, leaseMinutes: leaseMinutes)) ?? [])
            .count
    }

    /// Throws before `uninstall` lists or removes anything when the token folder or the launch
    /// folder is there but is not a real folder of the user's that passes the folder checks (a
    /// link, which is never followed, a file or another user's folder), or a label's folder in
    /// the launch folder is a real folder of the user's that fails them, since a token file or a
    /// launch file in it could be neither counted nor deleted.
    static func requireCheckableForUninstall(context: ToolContext) throws {
        let writer = NoFollowWriter(root: context.dataRoot)
        let entry = writer.placeEntry(parent: [], name: TokenPaths.folderName)
        if let refusal = Messages.uninstallRefusal(
            "The token folder", "~/.agent-balancer/tokens", entry)
        {
            throw ToolError(refusal)
        }
        try LaunchFiles.requireCheckableForUninstall(context: context)
    }

    /// How many entries in the token folder and the launch folder have the name of a token file
    /// or a label's launch folder only once their letter case is folded. Names only; nothing is
    /// opened.
    static func otherCaseEntryCount(context: ToolContext) -> Int {
        TokenStore.otherCaseEntryCount(context: context)
            + LaunchFiles.otherCaseEntryCount(context: context)
    }

    /// What `uninstall`'s launch file step did.
    public struct LaunchCleared: Equatable, Sendable {
        public let deleted: Int
        /// Launch files kept as tombstones: a session record names them, their lease is open, they
        /// are younger than `leaseMinutes`, or the records or the lease file could not be read
        /// cleanly. They hold no token.
        public let kept: Int
        /// Entries the tool did not make, left alone.
        public let left: Int
        /// Entries named like a label's launch folder only in other letter case, never opened.
        /// Each may hold a launch file with a token.
        public let otherCase: Int
        /// Entries where a label's launch folder belongs that are a link, a file or another
        /// user's folder, never followed. A launch file with a token may be behind each.
        public let notFollowed: Int
    }

    /// `uninstall`'s first step, under the pick lock the caller holds (`takeLock`): every launch
    /// file of every label is deleted, or overwritten with a token-free tombstone and kept when a
    /// session record names it, an open lease holds it, it is younger than `leaseMinutes`, or the
    /// records cannot be read cleanly; every one is kept when the lease file is there and cannot
    /// be read or decoded. Then a read-back that no launch file holds a token: when one does, it
    /// throws, and no token file or anything after it goes, so a rerun can finish.
    static func clearLaunchFilesForUninstall(
        context: ToolContext, leaseMinutes: Int, snapshot: SessionsSnapshot, now: Date
    ) throws -> LaunchCleared {
        let span = Double(max(1, leaseMinutes)) * 60
        let open = LeaseStore(context: context).currentIfReadable(
            now: now, leaseMinutes: leaseMinutes)
        let launch = try LaunchFiles.clearForUninstall(
            context: context, snapshot: snapshot, leased: Set((open ?? []).map(\.id)),
            keepModifiedAfter: now.addingTimeInterval(-span), keepAll: open == nil)
        guard try LaunchFiles.tokenHolderCount(context: context) == 0 else {
            throw ToolError(
                "A launch file could not be cleared, so the token files were kept. Run `agent-balancer uninstall` again."
            )
        }
        return LaunchCleared(
            deleted: launch.deleted, kept: launch.tombstoned, left: launch.skipped,
            otherCase: launch.otherCase, notFollowed: launch.notFollowed)
    }

    /// What `uninstall`'s token file step did.
    struct TokenFilesCleared: Equatable {
        var deleted = 0
        /// Token files that could not be deleted, a token file's name that `lstat` cannot check
        /// included. Each may still hold its token.
        var undeleted = 0
        /// Entries the tool did not make, left alone.
        var left = 0
        /// Entries named like a token file only in other letter case, never opened. Each may
        /// hold a token.
        var otherCase = 0
    }

    /// `uninstall`'s token file step (`TokenStore.deleteFilesForUninstall`), under the pick lock
    /// the caller holds.
    static func deleteTokenFilesForUninstall(context: ToolContext) throws -> TokenFilesCleared {
        try TokenStore.deleteFilesForUninstall(context: context)
    }

    /// What `uninstall`'s writer leftovers step left in the token and launch folders.
    struct LeftoversLeft: Equatable {
        /// The writer's temporary files still there. Each may hold a token.
        var temporaries = 0
        /// Other names of that shape, such as a link, which the tool did not make.
        var others = 0
    }

    /// `uninstall`'s writer leftovers step, under the pick lock the caller holds: the writer's
    /// leftover temporary files in the token folder and in each launch folder go, then the
    /// folders left empty. It never throws.
    static func deleteWriterLeftoversForUninstall(context: ToolContext) -> LeftoversLeft {
        let shaped =
            TokenStore.tidyForUninstall(context: context)
            + LaunchFiles.tidyForUninstall(context: context)
        let temporaries = temporariesForUninstall(context: context)
        return LeftoversLeft(temporaries: temporaries, others: max(0, shaped - temporaries))
    }

    /// What `uninstall` says when token files could not be deleted.
    public static func undeletedTokenFilesText(_ count: Int) -> String {
        "\(count) token files could not be deleted and still hold a token. Make `~/.agent-balancer/tokens/` writable and run `agent-balancer uninstall` again."
    }

    /// What `uninstall` says when the writer's temporary files in the token or launch folders
    /// could not be deleted.
    public static func undeletedTemporariesText(_ count: Int) -> String {
        "\(count) temporary files could not be deleted and may hold a token. Make `~/.agent-balancer/tokens/` and the launch folders writable and run `agent-balancer uninstall` again."
    }

    /// What `uninstall` says about entries named like a token file or a label's launch folder
    /// only in other letter case.
    public static func otherCaseEntriesText(_ count: Int) -> String {
        "\(count) entries in `~/.agent-balancer/tokens/` or the launch folder have the name of a token file or a launch folder in other letter case, such as `Pool-a.json`, so each may hold a token, and `uninstall` did not open them. Rename each to the tool's spelling, such as `pool-a.json`, or move it out of `~/.agent-balancer`, then run `agent-balancer uninstall` again."
    }
}

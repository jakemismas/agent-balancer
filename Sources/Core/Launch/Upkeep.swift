import Foundation

/// Launch file upkeep (docs/ARCHITECTURE.md section 4A.6). Callers hold the pick lock, so a file
/// of a pick in progress is never removed.
public enum Upkeep {
    /// Removes launch files this tool made that nothing needs any more. Returns the number
    /// removed.
    ///
    /// With a clean read of the session records, a file goes only when no record names it, no open
    /// lease holds it and it is older than `leaseMinutes`. A file a record names is kept for as
    /// long as the record exists, whatever the session's state. With records that cannot be read,
    /// only files older than `keepDays` go. Only a regular file owned by the user, named
    /// `l-<8 hex>.json` directly under `launch/<label>/`, is removed, through the no-follow writer.
    ///
    /// The writer's leftover temporary files in the token folder and in each launch folder go too:
    /// every writer of those folders holds the pick lock, so under it they belong to a write that
    /// stopped before its rename. They are not counted in the result.
    @discardableResult
    public static func run(
        context: ToolContext, snapshot: SessionsSnapshot, openLeases: [Lease], leaseMinutes: Int,
        keepDays: Int, now: Date
    ) -> Int {
        _ = try? TokenStore.deleteWriterLeftovers(context: context)
        let writer = NoFollowWriter(root: context.dataRoot)
        guard let labels = try? writer.listNames(folders: [LaunchFiles.folder]) else { return 0 }
        let leaseSpan = Double(max(1, leaseMinutes)) * 60
        let keepSpan = Double(max(1, keepDays)) * 86_400
        let leased = Set(openLeases.map { LaunchRef(label: $0.label, leaseId: $0.id) })
        var removed = 0
        for label in labels where ConfigValidator.isValidLabel(label) {
            let folders = LaunchFiles.folders(label: label)
            _ = try? LaunchFiles.deleteWriterLeftovers(context: context, label: label)
            guard let names = try? writer.listNames(folders: folders) else { continue }
            for name in names where name.hasSuffix(".json") {
                let id = String(name.dropLast(5))
                guard LaunchFiles.isValidLeaseId(id),
                    let info = try? writer.info(folders: folders, name: name),
                    info.isRegularFile, info.ownedByUser
                else { continue }
                let age = now.timeIntervalSince(info.modified)
                let ref = LaunchRef(label: label, leaseId: id)
                let due: Bool
                if snapshot.clean {
                    due = !snapshot.named.contains(ref) && !leased.contains(ref) && age > leaseSpan
                } else {
                    due = age > keepSpan
                }
                guard due else { continue }
                if (try? writer.removeOwnRegularFile(folders: folders, name: name)) == true {
                    removed += 1
                }
            }
        }
        return removed
    }

    /// Upkeep for a command that does not hold the pick lock yet, such as `refresh`: takes the
    /// lock, reads the open leases and the session records, and runs the pass. A pick in progress
    /// holds the lock, so a busy lock skips the pass.
    @discardableResult
    public static func runLocked(context: ToolContext, config: Config, now: Date = Date()) -> Int {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard
            let lock = try? writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 5)
        else { return 0 }
        defer { lock.release() }
        // Without a readable lease file the open picks are unknown, so nothing is removed.
        guard
            let leases = LeaseStore(context: context).currentIfReadable(
                now: now, leaseMinutes: config.picker.leaseMinutes)
        else { return 0 }
        return run(
            context: context, snapshot: SessionsReader.read(context: context), openLeases: leases,
            leaseMinutes: config.picker.leaseMinutes, keepDays: config.launch.keepDays, now: now)
    }
}

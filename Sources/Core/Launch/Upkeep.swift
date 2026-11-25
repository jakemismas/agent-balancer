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
    /// Ages and leases are judged at `judgedAt(now:recorded:)`, so a clock that moved forward past
    /// `recorded`, the newest time the tool recorded before the caller began, ends no lease and
    /// ages no file by itself. With no `recorded`, they are judged at `now`.
    ///
    /// The writer's leftover temporary files in the token folder and in each launch folder go too:
    /// every writer of those folders holds the pick lock, so under it they belong to a write that
    /// stopped before its rename. They are not counted in the result.
    @discardableResult
    public static func run(
        context: ToolContext, snapshot: SessionsSnapshot, openLeases: [Lease], leaseMinutes: Int,
        keepDays: Int, now: Date, recorded: Date? = nil
    ) -> Int {
        _ = try? TokenStore.deleteWriterLeftovers(context: context)
        let writer = NoFollowWriter(root: context.dataRoot)
        guard let labels = try? writer.listNames(folders: [LaunchFiles.folder]) else { return 0 }
        let at = judgedAt(now: now, recorded: recorded)
        let leaseSpan = Double(max(1, leaseMinutes)) * 60
        let keepSpan = Double(max(1, keepDays)) * 86_400
        // A lease still open at that time holds its file, as one open now does.
        let held =
            openLeases
            + (LeaseStore(context: context).currentIfReadable(now: at, leaseMinutes: leaseMinutes)
                ?? [])
        let leased = Set(held.map { LaunchRef(label: $0.label, leaseId: $0.id) })
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
                let age = at.timeIntervalSince(info.modified)
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

    /// The time upkeep and the probe folder cleanup judge ages at: the earlier of the clock and
    /// `recorded`, the newest time the tool recorded before the caller began. A clock that moved
    /// forward is held back to that time; one that moved back is used as it is. With no
    /// `recorded`, it is the clock.
    public static func judgedAt(now: Date, recorded: Date?) -> Date {
        recorded.map { min(now, $0) } ?? now
    }

    /// The newest time the tool recorded in its own files under the data folder: the latest
    /// lease in the lease file, open or not, and the latest stored reading of `labels`. A time in
    /// a file's metadata, which the user can set, never counts. Nil when none can be read.
    public static func newestRecorded(context: ToolContext, labels: [String]) -> Date? {
        let store = ReadingStore(context: context)
        let readings = labels.compactMap { (try? store.load(label: $0))?.readAt }
        let lease = LeaseStore(context: context).newestTime()
        return (readings + (lease.map { [$0] } ?? [])).max()
    }

    /// What a pass of `runLocked` did: how many launch files it removed, and for each folder that
    /// still holds a writer's temporary file that may hold a token, the text that names them.
    /// `notRun` says why a pass did not run, with its fix; it is nil when the pass ran.
    public struct Pass: Equatable, Sendable {
        public var removed: Int
        public var temporariesLeft: [String]
        public var notRun: String? = nil
    }

    /// Upkeep for a command that does not hold the pick lock yet, such as `refresh`: takes the
    /// lock, reads the open leases and the session records, and runs the pass, judging ages as
    /// `run` does with `recorded`. A pick in progress holds the lock, so a busy lock skips the
    /// pass, and so does a lock file that does not open or a lease file that cannot be read; then
    /// nothing is removed, `notRun` says why, and the temporary files that may hold a token are
    /// named as `doctor` reads them, without deleting any.
    @discardableResult
    public static func runLocked(
        context: ToolContext, config: Config, now: Date = Date(), recorded: Date?
    ) -> Pass {
        func notRun(_ why: String) -> Pass {
            Pass(
                removed: 0, temporariesLeft: TokenAccounts.temporariesKept(context: context),
                notRun: Messages.upkeepNotRun(why))
        }
        func text(_ error: Error) -> String {
            (error as? ToolError)?.message ?? error.localizedDescription
        }
        let writer = NoFollowWriter(root: context.dataRoot)
        let held: FileLock?
        do {
            held = try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 5)
        } catch {
            return notRun(text(error))
        }
        guard let lock = held else { return notRun(Messages.upkeepLockBusy) }
        defer { lock.release() }
        // Without a readable lease file the open picks are unknown, so nothing is removed.
        let leases: [Lease]
        do {
            leases = try LeaseStore(context: context).current(
                now: now, leaseMinutes: config.picker.leaseMinutes)
        } catch {
            return notRun(text(error))
        }
        let removed = run(
            context: context, snapshot: SessionsReader.read(context: context), openLeases: leases,
            leaseMinutes: config.picker.leaseMinutes, keepDays: config.launch.keepDays, now: now,
            recorded: recorded)
        // Read under the lock, so no write in progress is named.
        return Pass(
            removed: removed, temporariesLeft: TokenAccounts.temporariesLeft(context: context))
    }
}

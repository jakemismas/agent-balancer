import Foundation

extension NoFollowWriter {
    /// What one step that runs after a `login` sign-in does under the data folder, declared once:
    /// each file it changes or reads and how, each folder it makes entries in, and each folder it
    /// only opens. `require` runs the check of every target before the sign-in, and the step runs
    /// under the same plan, so the checks come from what the step declares, and a test that
    /// watches the step sees a write the plan leaves out (docs/ARCHITECTURE.md section 4A.4).
    public struct Plan: Equatable, Sendable {
        /// The step's name, for the test seam.
        public let step: String
        public var targets: [Target]
        /// The time the check of a `scratch` target judges the age of a probe folder another
        /// probe left at, or nil for the clock.
        public var judgedAt: Date?

        public init(step: String, targets: [Target]) {
            self.step = step
            self.targets = targets
        }
    }

    /// One file or folder a step uses under the data folder, and how.
    public struct Target: Hashable, Sendable {
        public enum Use: String, Hashable, Sendable, CaseIterable {
            /// Opened to read, through the folder checks.
            case open
            /// Read whole, through the reader.
            case read
            /// Written whole over what is there, through a temporary file and a rename.
            case replace
            /// New files of the step's own naming made in the folder.
            case create
            case delete
            /// Lines added, the file made when missing.
            case append
            /// Opened to take a lock, the file made when missing.
            case lock
            /// The folder marked as excluded from backups.
            case mark
            /// A probe folder made in the folder and removed.
            case scratch
        }

        /// The folder, as names below the data folder.
        public let folders: [String]
        /// The file, or nil for a target that is the folder itself.
        public let name: String?
        public let uses: Set<Use>
        /// For `scratch`: the probe folder's name prefix, and the age after which one left by
        /// another probe is removed.
        var prefix = ""
        var staleAfter: TimeInterval = 0
        /// For `read`: the most bytes the step reads, as its reader call takes them.
        var readLimit = NoFollowReader.defaultLimit
        /// How a refusal names a file that is not named by its own path, such as a launch file,
        /// which is named by its folder: what the text calls it and the path its commands take.
        var shown: Shown?

        public static func file(_ folders: [String], _ name: String, _ uses: Set<Use>) -> Target {
            Target(folders: folders, name: name, uses: uses)
        }

        public static func folder(_ folders: [String], _ uses: Set<Use>) -> Target {
            Target(folders: folders, name: nil, uses: uses)
        }

        /// `file` for a file the step also reads with a limit other than the reader's default.
        static func file(_ folders: [String], _ name: String, _ uses: Set<Use>, readLimit: Int)
            -> Target
        {
            var target = Target(folders: folders, name: name, uses: uses)
            target.readLimit = readLimit
            return target
        }

        static func scratch(_ folders: [String], prefix: String, staleAfter: TimeInterval)
            -> Target
        {
            var target = Target(folders: folders, name: nil, uses: [.scratch])
            target.prefix = prefix
            target.staleAfter = staleAfter
            return target
        }

        /// The target's path below the data folder, as the test seam names it.
        var path: String { NoFollowWriter.joined(folders + (name.map { [$0] } ?? [])) }

        /// Whether the step writes in the target's folder: it makes, replaces, deletes, adds lines
        /// to or locks something there.
        var writesInFolder: Bool {
            !uses.isDisjoint(with: [.replace, .create, .delete, .append, .lock])
        }
    }

    /// What a refusal calls a file and the path its commands take.
    struct Shown: Hashable, Sendable {
        let subject: String
        let path: String
    }
}

extension NoFollowWriter {
    /// Throws, before a sign-in, the refusal a step that runs under `plan` would meet, from the
    /// check of each target in turn: a folder the step writes in is made when missing, passes the
    /// folder checks, and takes and loses a file of the writer's own shape that the user can read
    /// and write through the reader's and the writer's own opens and whose access list reads as
    /// closed after the writer's clear (`requireWritable`); a lock file opens as a lock opens it,
    /// made when missing; a file the step replaces or deletes can be
    /// (`requireReplaceable`); a file it reads opens as the reader opens it; a file it adds lines
    /// to opens to write; a folder it marks is marked; a probe folder is made in its parent,
    /// judged, and removed; and a folder it only opens passes the folder checks.
    public func require(_ plan: Plan) throws {
        Self.trace.note(root, .required(plan.step, plan.targets))
        var probed = Set<[String]>()
        for target in plan.targets {
            if target.writesInFolder && !probed.contains(target.folders) {
                probed.insert(target.folders)
                try requireWritable(folders: target.folders)
            }
            if target.uses.contains(.open) {
                let dir = try Self.openFolder(root: root, folders: target.folders, create: false)
                if dir >= 0 { close(dir) }
            }
            if target.uses.contains(.mark) { try markExcludedFromBackup(folders: target.folders) }
            if target.uses.contains(.scratch) {
                try requireScratchable(
                    parent: target.folders, prefix: target.prefix, staleAfter: target.staleAfter,
                    judgedAt: plan.judgedAt ?? Date())
            }
            guard let name = target.name else { continue }
            if target.uses.contains(.lock) {
                try requireLockable(folders: target.folders, name: name)
            }
            if !target.uses.isDisjoint(with: [.replace, .delete]) {
                try requireReplaceable(folders: target.folders, name: name, shown: target.shown)
            }
            if target.uses.contains(.read) {
                try requireReadable(
                    folders: target.folders, name: name, limit: target.readLimit,
                    shown: target.shown)
            }
            if target.uses.contains(.append) {
                try requireAppendable(folders: target.folders, name: name)
            }
        }
    }

    /// Runs `body`, a step after a sign-in, under the plan it declares. While a test watches the
    /// data folder `root`, the seam notes the plan around the step's writes, so one the plan
    /// leaves out shows; otherwise the plan is not built.
    static func run<T>(_ root: URL, _ plan: @autoclosure () -> Plan, _ body: () throws -> T)
        rethrows -> T
    {
        guard trace.isWatching(root) else { return try body() }
        let declared = plan()
        trace.note(root, .began(declared.step, declared.targets))
        defer { trace.note(root, .ended(declared.step)) }
        return try body()
    }
}

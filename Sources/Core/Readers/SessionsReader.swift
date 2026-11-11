import Foundation

/// A running session of the default folder: its id, its name and the launch files its records
/// name.
public struct LiveSession: Equatable, Sendable {
    public var id: String
    public var name: String?
    public var refs: [LaunchRef]

    public init(id: String, name: String? = nil, refs: [LaunchRef] = []) {
        self.id = id
        self.name = name
        self.refs = refs
    }
}

/// What one pass over the session records found (docs/ARCHITECTURE.md sections 4A.6 and 8).
public struct SessionsSnapshot: Equatable, Sendable {
    /// False when a record could not be opened or read, is not a regular file, or is too large.
    public var clean: Bool
    /// Sessions whose process is alive, one per session id.
    public var live: [LiveSession]
    /// Every launch file any record names, live or not.
    public var named: Set<LaunchRef>

    public init(clean: Bool, live: [LiveSession] = [], named: Set<LaunchRef> = []) {
        self.clean = clean
        self.live = live
        self.named = named
    }

    public static let unreadable = SessionsSnapshot(clean: false)
    public static let empty = SessionsSnapshot(clean: true)
}

/// Reads `sessions/*.json` and `jobs/*/state.json` of the default folder for ids, names, state and
/// launch file names only. Prompts, paths and every other value are dropped as they are read.
public enum SessionsReader {
    static let recordLimit = 1_048_576
    static let endedStates: Set<String> = [
        "finished", "done", "stopped", "failed", "completed", "cancelled", "canceled", "error",
    ]

    private struct Entry {
        var pid: Int
        var sessionId: String
        var jobId: String?
        var name: String?
        var refs: [LaunchRef]
    }

    private struct Job {
        var folder: String
        var sessionIds: [String]
        var name: String?
        var state: String?
        var refs: [LaunchRef]
    }

    public static func read(
        context: ToolContext, isAlive: (Int) -> Bool = SessionsReader.processIsAlive
    ) -> SessionsSnapshot {
        let base = context.defaultClaudeFolder
        var clean = true
        var entries: [Entry] = []
        var jobs: [Job] = []
        var anonymousRefs: [LaunchRef] = []

        let sessionsFolder = base.appendingPathComponent("sessions", isDirectory: true)
        let sessionNames = list(sessionsFolder)
        if !sessionNames.ok { clean = false }
        do {
            for name in sessionNames.names where name.hasSuffix(".json") {
                guard let object = readObject(folder: sessionsFolder, name: name) else {
                    clean = false
                    continue
                }
                // A record without a session id or pid still protects the files it names.
                guard let id = object["sessionId"] as? String, !id.isEmpty,
                    let pid = (object["pid"] as? NSNumber)?.intValue
                else {
                    anonymousRefs += refs(in: object)
                    continue
                }
                // An id that is not plain is never printed or stored, and the pass is unclean so
                // nothing it names is deleted on a clean read.
                let jobId = object["jobId"] as? String
                guard isValidId(id), jobId.map(isValidId) ?? true else {
                    clean = false
                    anonymousRefs += refs(in: object)
                    continue
                }
                entries.append(
                    Entry(
                        pid: pid, sessionId: id, jobId: jobId,
                        name: cleanName(object["name"]), refs: refs(in: object)))
            }
        }

        let jobsFolder = base.appendingPathComponent("jobs", isDirectory: true)
        let jobNames = list(jobsFolder)
        if !jobNames.ok { clean = false }
        do {
            for folder in jobNames.names where isValidId(folder) {
                let dir = jobsFolder.appendingPathComponent(folder, isDirectory: true)
                let data: Data?
                do {
                    data = try NoFollowReader.readEntryOutside(
                        folder: dir, name: "state.json", limit: recordLimit)
                } catch {
                    clean = false
                    continue
                }
                guard let data else { continue }
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else {
                    clean = false
                    continue
                }
                let rawIds = ["sessionId", "resumeSessionId", "jobId"].compactMap {
                    object[$0] as? String
                }
                if !rawIds.allSatisfy(isValidId) { clean = false }
                jobs.append(
                    Job(
                        folder: folder,
                        sessionIds: ["sessionId", "resumeSessionId"].compactMap {
                            object[$0] as? String
                        }.filter(isValidId),
                        name: cleanName(object["name"]),
                        state: (object["state"] as? String)?.lowercased(),
                        refs: refs(in: object)))
            }
        }

        var named = Set<LaunchRef>(anonymousRefs)
        for entry in entries { named.formUnion(entry.refs) }
        for job in jobs { named.formUnion(job.refs) }

        var live: [LiveSession] = []
        var seen = Set<String>()
        for entry in entries where isAlive(entry.pid) && !seen.contains(entry.sessionId) {
            let job =
                jobs.first { $0.folder == entry.jobId }
                ?? jobs.first { $0.sessionIds.contains(entry.sessionId) }
            if let state = job?.state, endedStates.contains(state) { continue }
            seen.insert(entry.sessionId)
            var all = entry.refs
            for ref in job?.refs ?? [] where !all.contains(ref) { all.append(ref) }
            live.append(LiveSession(id: entry.sessionId, name: entry.name ?? job?.name, refs: all))
        }
        return SessionsSnapshot(clean: clean, live: live, named: named)
    }

    /// The names in a folder. A missing folder is an empty, clean read; one that cannot be listed
    /// is not clean.
    private static func list(_ url: URL) -> (names: [String], ok: Bool) {
        do {
            return (try NoFollowReader.listOutside(url) ?? [], true)
        } catch {
            return ([], false)
        }
    }

    public static func processIsAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private static func readObject(folder: URL, name: String) -> [String: Any]? {
        guard
            let data = try? NoFollowReader.readEntryOutside(
                folder: folder, name: name, limit: recordLimit),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }

    /// The shape of a session id, a job id and a job folder name, which is the job id: 1 to 128
    /// letters, digits, dots, underscores or hyphens, starting with a letter or digit.
    static func isValidId(_ id: String) -> Bool {
        id.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z"#, options: .regularExpression) != nil
    }

    private static func cleanName(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return Display.safe(Scrubber.scrubText(text), limit: 80)
    }

    /// Every launch file named by any string anywhere in a record, whatever its shape.
    private static func refs(in value: Any, depth: Int = 0) -> [LaunchRef] {
        guard depth < 12 else { return [] }
        if let text = value as? String { return LaunchFiles.references(in: text) }
        if let list = value as? [Any] { return list.flatMap { refs(in: $0, depth: depth + 1) } }
        if let object = value as? [String: Any] {
            return object.values.flatMap { refs(in: $0, depth: depth + 1) }
        }
        return []
    }
}

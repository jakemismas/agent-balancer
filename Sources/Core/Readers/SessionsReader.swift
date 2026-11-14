import Foundation

/// A running session of the default folder: its id, its name and the launch files its records
/// name.
public struct LiveSession: Equatable, Sendable {
    public var id: String
    public var name: String?
    public var refs: [LaunchRef]
    /// The folder account whose own folder holds this session's record, or nil for the default
    /// folder. A session in an account's folder counts toward that account.
    public var folderLabel: String?

    public init(
        id: String, name: String? = nil, refs: [LaunchRef] = [], folderLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.refs = refs
        self.folderLabel = folderLabel
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

    /// The default folder and the folder of every folder account, one pass each. A session in an
    /// account's folder is tagged with that account.
    public static func read(
        context: ToolContext, isAlive: (Int) -> Bool = SessionsReader.processIsAlive
    ) -> SessionsSnapshot {
        var snapshot = readFolder(context.defaultClaudeFolder, owner: nil, isAlive: isAlive)
        let labels: [String]
        do {
            labels = try accountLabels(context)
        } catch {
            snapshot.clean = false
            return snapshot
        }
        for label in labels {
            guard let dir = try? FolderPaths.configDir(context: context, label: label) else {
                snapshot.clean = false
                continue
            }
            let more = readFolder(dir, owner: label, isAlive: isAlive)
            snapshot.clean = snapshot.clean && more.clean
            snapshot.live += more.live
            snapshot.named.formUnion(more.named)
        }
        return snapshot
    }

    /// The names under `accounts/` that are valid labels. A missing folder is an empty list.
    static func accountLabels(_ context: ToolContext) throws -> [String] {
        let folder = context.dataRoot.appendingPathComponent("accounts", isDirectory: true)
        return (try NoFollowReader.listOutside(folder) ?? []).filter(ConfigValidator.isValidLabel)
    }

    static func readFolder(_ base: URL, owner: String?, isAlive: (Int) -> Bool) -> SessionsSnapshot
    {
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
            live.append(
                LiveSession(
                    id: entry.sessionId, name: entry.name ?? job?.name, refs: all,
                    folderLabel: owner))
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

/// Where the caller's own session runs, judged from variables and file names only, never from a
/// file's content. A typed `pick` or `run --print-command` writes a line with no
/// folder prefix for a `login` or `token` account, and that line is only right in the default
/// folder.
public enum SessionFolder {
    /// True when `path` is exactly `<folder>/jobs/<one segment>`, judged by the text of the path
    /// alone: absolute, with no empty, `.` or `..` segment. No link is resolved and no file is
    /// read.
    static func isJobFolder(_ path: String, of folder: URL) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        let base = folder.path.split(separator: "/").map(String.init)
        guard parts.first == "", parts.count == base.count + 3 else { return false }
        let rest = Array(parts.dropFirst())
        return Array(rest.prefix(base.count)) == base && rest[base.count] == "jobs"
    }

    /// True when `path` is exactly `<default folder>/jobs/<one segment>` (`isJobFolder`).
    static func isDefaultJobFolder(_ path: String, context: ToolContext) -> Bool {
        isJobFolder(path, of: context.defaultClaudeFolder)
    }

    private static func sessionNames(_ folder: URL) -> [String]? {
        do { return try NoFollowReader.listOutside(folder) ?? [] } catch { return nil }
    }

    /// Why a prefix-less recipe is not offered, or nil when the caller's folder is shown to be the
    /// default one or no proof is asked for.
    public static func prefixlessReason(context: ToolContext) -> String? {
        let configDir = context.ambient[ProtectedEnv.configDirVariable]
        let jobDir = context.ambient["CLAUDE_JOB_DIR"]
        if configDir != nil { return "ambient CLAUDE_CONFIG_DIR set" }
        if let jobDir {
            return isDefaultJobFolder(jobDir, context: context)
                ? nil : "ambient session folder not default"
        }
        guard context.inChatShell else { return nil }
        let notConfirmed = "chat folder not confirmed default"
        guard let pid = context.ambient["CLAUDE_PID"], !pid.isEmpty,
            pid.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return notConfirmed }
        let name = pid + ".json"
        let own = context.defaultClaudeFolder.appendingPathComponent("sessions", isDirectory: true)
        guard let here = sessionNames(own), here.contains(name) else { return notConfirmed }
        guard let labels = try? SessionsReader.accountLabels(context) else { return notConfirmed }
        for label in labels {
            guard let dir = try? FolderPaths.configDir(context: context, label: label),
                let there = sessionNames(dir.appendingPathComponent("sessions", isDirectory: true)),
                !there.contains(name)
            else { return notConfirmed }
        }
        return nil
    }

    /// For `doctor`: `default`, `folder <label>` or `not confirmed`. Labels only, no path. A job
    /// folder names a folder account only when it is exactly `<its folder>/jobs/<one segment>`.
    public static func describe(context: ToolContext, config: Config) -> String {
        if let dir = context.ambient[ProtectedEnv.configDirVariable] {
            for account in config.accounts where account.kind == Kind.folder {
                if let own = try? FolderPaths.configDir(context: context, label: account.label),
                    own.path == dir
                {
                    return "folder \(account.label)"
                }
            }
            return "not confirmed"
        }
        if let jobDir = context.ambient["CLAUDE_JOB_DIR"] {
            if isDefaultJobFolder(jobDir, context: context) { return "default" }
            for account in config.accounts where account.kind == Kind.folder {
                if let own = try? FolderPaths.configDir(context: context, label: account.label),
                    isJobFolder(jobDir, of: own)
                {
                    return "folder \(account.label)"
                }
            }
            return "not confirmed"
        }
        return prefixlessReason(context: context) == nil ? "default" : "not confirmed"
    }
}

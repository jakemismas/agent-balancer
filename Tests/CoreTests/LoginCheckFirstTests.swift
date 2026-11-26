import Foundation
import Testing

@testable import Core

/// Where the sign-in starts: the count of the seam's events when `announce` runs or the paste
/// prompt asks whether it is on a terminal.
private final class Split: @unchecked Sendable {
    private let lock = NSLock()
    private var cut: Int?

    func take(_ count: Int) {
        lock.lock()
        if cut == nil { cut = count }
        lock.unlock()
    }

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return cut
    }
}

/// One run of the seam test: the sign-in or the paste, on a first use or on a renewal (a token
/// file, a stored reading and launch files there before).
struct LoginRun: Sendable, CustomTestStringConvertible {
    let paste: Bool
    let renewal: Bool

    var testDescription: String {
        (paste ? "paste" : "sign-in") + (renewal ? " renewal" : " first use")
    }

    static let all = [false, true].flatMap { paste in
        [false, true].map { LoginRun(paste: paste, renewal: $0) }
    }
}

/// What the seam saw that breaks the rules: each a path below the data folder.
struct SeamFindings: Equatable {
    /// Folders checked after the sign-in that did not pass a check before it.
    var uncheckedFolders: [String] = []
    /// Folders changed after the sign-in whose write probe did not pass before it.
    var unprovedFolders: [String] = []
    /// Files changed after the sign-in without the check of that change before it.
    var unmatchedFiles: [String] = []
    /// Changes after the sign-in outside a step, or that the step's plan does not declare.
    var undeclared: [String] = []
    /// Refusals of a folder or a file after the sign-in.
    var refusals: [String] = []
    /// Steps whose run declared another plan than the one checked before the sign-in.
    var drifted: [String] = []
    /// Targets of the plans checked before the sign-in that the run never reached.
    var unreached: [String] = []
}

/// The rules of `login`'s checks before the sign-in, read from the seam's events and the point the
/// sign-in started. Every folder checked after it passed a check before it; every folder changed
/// after it was proved before it; every file changed after it had the check of that change before
/// it (the delete right and the flags for a replace or a delete, the probe file's list and opens
/// for a new file, the open for a file that takes lines or a lock), unless the run itself made the
/// file after the sign-in; every change after it ran inside a step and was declared by that step's
/// plan, the plan the checks before used; nothing was refused after it; and every target of the
/// plans was reached, so no rule is empty.
enum SeamRules {
    typealias Event = NoFollowWriter.Trace.Event
    typealias Target = NoFollowWriter.Target

    static func folder(of path: String) -> String {
        guard let cut = path.lastIndex(of: "/") else { return "" }
        return String(path[..<cut])
    }

    /// Whether `targets` declare `change` of `path`. A new file is declared by a target that
    /// names it, by a folder the plan makes new files in, or, for the writer's temporary file, by
    /// a whole-file write in its folder. A file the step made after the sign-in is declared by
    /// its folder for what it does to it next.
    static func declares(
        _ targets: [Target], _ path: String, _ change: NoFollowWriter.Trace.FileChange,
        made: Bool = false
    ) -> Bool {
        let dir = folder(of: path)
        let makers: Set<Target.Use> = [.create, .replace, .append, .lock, .delete]
        return targets.contains { target in
            let here = NoFollowWriter.joined(target.folders) == dir
            if made && here && !target.uses.isDisjoint(with: makers) { return true }
            switch change {
            case .create:
                let name = String(path.dropFirst(dir.isEmpty ? 0 : dir.count + 1))
                return (target.path == path && !target.uses.isDisjoint(with: makers))
                    || (here && target.name == nil && target.uses.contains(.create))
                    || (here && NoFollowWriter.isTemporaryName(name)
                        && target.uses.contains(.replace))
            case .replace: return target.path == path && target.uses.contains(.replace)
            case .delete: return target.path == path && target.uses.contains(.delete)
            case .append: return target.path == path && target.uses.contains(.append)
            case .lockOpen: return target.path == path && target.uses.contains(.lock)
            }
        }
    }

    static func declaresFolder(_ targets: [Target], _ folder: String) -> Bool {
        targets.contains { target in
            let path = NoFollowWriter.joined(target.folders)
            return path == folder || path.hasPrefix(folder.isEmpty ? "" : folder + "/")
        }
    }

    static func findings(_ events: [Event], cut: Int) -> SeamFindings {
        var found = SeamFindings()
        let before = events.prefix(cut)
        let after = events.dropFirst(cut)
        var passed = Set<String>()
        var proved = Set<String>()
        var checked = Set<String>()
        var required: [String: [Target]] = [:]
        for event in before {
            switch event {
            case .passed(let path): passed.insert(path)
            case .proved(let path): proved.insert(path)
            case .checked(let path, let kind): checked.insert(kind.rawValue + " " + path)
            case .required(let step, let targets): required[step] = targets
            default: break
            }
        }
        func has(_ kind: NoFollowWriter.Trace.FileCheck, _ path: String) -> Bool {
            checked.contains(kind.rawValue + " " + path)
        }
        var steps: [(String, [Target])] = []
        var made = Set<String>()
        var changedFiles = Set<String>()
        var changedFolders = Set<String>()
        var passedAfter = Set<String>()
        for event in after {
            switch event {
            case .began(let step, let targets):
                steps.append((step, targets))
                if required[step] != targets { found.drifted.append(step) }
            case .ended(let step):
                if steps.last?.0 == step { steps.removeLast() }
            case .passed(let path):
                passedAfter.insert(path)
                if !passed.contains(path) { found.uncheckedFolders.append(path) }
            case .refused(let path):
                found.refusals.append(path)
                if !passed.contains(path) { found.uncheckedFolders.append(path) }
            case .fileRefused(let path):
                found.refusals.append(path)
            case .changed(let path):
                changedFolders.insert(path)
                if !proved.contains(path) { found.unprovedFolders.append(path) }
                if !(steps.last.map { declaresFolder($0.1, path) } ?? false) {
                    found.undeclared.append("folder " + path)
                }
            case .file(let path, let change):
                changedFiles.insert(path)
                let ours = made.contains(path)
                if !(steps.last.map { declares($0.1, path, change, made: ours) } ?? false) {
                    found.undeclared.append(change.rawValue + " " + path)
                }
                let matched: Bool
                switch change {
                case .create:
                    matched = has(.probeList, folder(of: path)) && proved.contains(folder(of: path))
                    made.insert(path)
                case .replace, .delete:
                    matched = ours || (has(.deleteRight, path) && has(.flags, path))
                case .append:
                    matched = ours || has(.appendable, path)
                case .lockOpen:
                    matched = ours || has(.lockable, path)
                }
                if !matched { found.unmatchedFiles.append(change.rawValue + " " + path) }
            default:
                break
            }
        }
        for target in required.values.flatMap({ $0 }) {
            let path = target.path
            let reached: Bool
            if target.name != nil && target.writesInFolder {
                reached = changedFiles.contains(path)
            } else if target.uses.contains(.create) {
                reached = changedFiles.contains { folder(of: $0) == path }
            } else if target.uses.contains(.scratch) {
                reached = changedFolders.contains(path)
            } else if target.name == nil {
                reached = passedAfter.contains(path)
            } else {
                // A file only read: its read is not on the seam; its folder is.
                reached = passedAfter.contains(NoFollowWriter.joined(target.folders))
            }
            if !reached {
                found.unreached.append(
                    target.uses.map(\.rawValue).sorted().joined(
                        separator: ",") + " " + path)
            }
        }
        found.unreached = Array(Set(found.unreached)).sorted()
        return found
    }
}

/// `login` for a token account checks before the sign-in everything a step after it does under
/// the data folder: each step declares its plan once, the checks before the sign-in come from the
/// plans, and the steps run under the same plans, which the writer's seam shows down to each file.
@Suite struct LoginCheckFirstTests {
    func context(_ t: TestHome) -> ToolContext {
        t.context(ambient: ["HOME": t.home.path, "PATH": "/usr/bin:/bin"])
    }

    /// A name of the writer's temporary shape.
    func leftoverName() -> String { NoFollowWriter.temporaryPrefix + Paths.randomHex(8) }

    /// A home where each step after a sign-in reaches every target of its plan: the token account
    /// `lab`, a folder account `work` (not linked, so each status rebuild that sees no record of
    /// it drafts an event), `main` with a reading and a history file, a config backup, a writer's
    /// leftover in the token folder, a `state/current.json` that does not parse and a rejection of
    /// `lab` that a working new token ends. On a renewal `lab` is signed in once, with a launch
    /// file to rewrite, one that does not parse, a leftover in its launch folder, a history file
    /// whose last line does not parse and an events record that does not parse; on a first use it
    /// has none.
    func home(renewal: Bool, lease: String = "l-0a0b0c0d") throws -> TestHome {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        try t.fakeProbe("ok.jsonl")
        let context = context(t)
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                expectedPlanTier: "max_20x"),
            Account(label: "lab", kind: Kind.token, role: Role.pool),
            Account(label: "work", kind: Kind.folder, role: Role.pool),
        ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        // A saved copy, so `backups/` is there for a step that might open it.
        try ConfigStore(context: context).save(config, backup: true)
        let writer = NoFollowWriter(root: context.dataRoot)
        try writer.prepare(folders: FolderPaths.folders(label: "work"))
        try HookRecord(context: context).record(.empty)
        let main = try #require(config.account("main"))
        let read = Refresher(context: context, config: config)
            .refresh(account: main, force: true, fable: .none)
        guard case .probed = read.status else {
            Issue.record("main: \(read.status)")
            return t
        }
        let launch = [LaunchFiles.folder, "lab"]
        if renewal {
            try t.fake("setup-token.out", "Your token is \(Canaries.oauthRealShape())\n")
            let first = try TokenLogin.signIn(
                context: context, label: "lab", runner: ClaudeRunner(context: context),
                announce: {}, saved: { _ in })
            #expect(first.unfinished.isEmpty)
            let lab = try #require(try ConfigStore(context: context).loadRequired().account("lab"))
            _ = try LaunchFiles.create(
                context: context, account: lab, leaseId: lease, caller: .none)
            try writer.put(Data("not json\n".utf8), folders: launch, name: "l-0e0f0a0b.json")
            try writer.put(Data(), folders: launch, name: leftoverName())
            try writer.append(
                Data("not json\n".utf8), folders: ReadingHistory.folders,
                name: ReadingHistory.fileName("lab"))
            try writer.put(
                Data("not json\n".utf8), folders: Layout.stateFolders, name: EventLog.fileName)
            // `main`'s history ends in a line that does not parse, so the rebuild rewrites it.
            try writer.append(
                Data("not json\n".utf8), folders: ReadingHistory.folders,
                name: ReadingHistory.fileName("main"))
        } else {
            try StatusBuilder.rebuild(context: context)
            // `main`'s history ends in another state's line, so the rebuild adds one to it.
            let stored = try #require(try ReadingStore(context: context).load(label: "main"))
            let line = StatusBuilder.historyLine(account: main, reading: stored, state: "error")
            try writer.append(
                try EventLog.encoder().encode(line) + Data([0x0A]),
                folders: ReadingHistory.folders, name: ReadingHistory.fileName("main"))
        }
        try writer.put(Data(), folders: TokenPaths.folders, name: leftoverName())
        try writer.put(
            Data("not json\n".utf8), folders: Layout.stateFolders, name: StatusBuilder.currentName)
        let lab = try #require(try ConfigStore(context: context).loadRequired().account("lab"))
        let rejections = StatusBuilder.RejectionsFile(tokens: [
            "lab": StatusBuilder.RejectionRecord(
                accountKey: lab.accountKey, at: Date().addingTimeInterval(-60))
        ])
        try writer.put(
            try EventLog.encoder().encode(rejections) + Data([0x0A]), folders: Layout.stateFolders,
            name: StatusBuilder.rejectionsName)
        // A kept new-token check of the same shape, which the rebuild folds and rewrites.
        try writer.put(
            try EventLog.encoder().encode(rejections) + Data([0x0A]), folders: Layout.stateFolders,
            name: StatusBuilder.checksName)
        try t.fake("setup-token.out", "Your token is \(Canaries.oauthRealShape())\n")
        return t
    }

    /// Runs `login lab` in `run`'s form, watching the seam, and returns its outcome, the events and
    /// where the sign-in started.
    func login(_ t: TestHome, _ run: LoginRun, saved: (TokenCapture.Result) -> Void = { _ in })
        throws -> (TokenLogin.Outcome, [NoFollowWriter.Trace.Event], Int?)
    {
        let context = context(t)
        let root = context.dataRoot
        let split = Split()
        NoFollowWriter.trace.watch(root)
        defer { NoFollowWriter.trace.stop(root) }
        let outcome: TokenLogin.Outcome
        if run.paste {
            let token = Canaries.oauthRealShape()
            let terminal = PasteTerminal(
                isTerminal: {
                    split.take(NoFollowWriter.trace.events(root).count)
                    return true
                }, echoOff: { termios() }, restore: { _ in }, readLine: { token })
            outcome = try TokenLogin.paste(
                context: context, label: "lab", terminal: terminal, saved: saved)
        } else {
            outcome = try TokenLogin.signIn(
                context: context, label: "lab", runner: ClaudeRunner(context: context),
                announce: { split.take(NoFollowWriter.trace.events(root).count) }, saved: saved)
        }
        return (outcome, NoFollowWriter.trace.events(root), split.value)
    }

    @Test(arguments: LoginRun.all)
    func nothingIsCheckedOrChangedAfterTheSignInThatTheStepsPlansDidNotProveBeforeIt(
        _ run: LoginRun
    ) throws {
        let t = try home(renewal: run.renewal)
        let (outcome, events, split) = try login(t, run)
        let cut = try #require(split, "\(run.testDescription)")
        let found = SeamRules.findings(events, cut: cut)
        #expect(found == SeamFindings(), "\(run.testDescription): \(found)")
        // The plans the checks used are the steps' own, each checked once before the sign-in.
        let steps = events.prefix(cut).compactMap { event -> String? in
            if case .required(let step, _) = event { return step }
            return nil
        }
        #expect(steps == ["token save", "check", "status rebuild"], "\(run.testDescription)")
        let ran = events.dropFirst(cut).compactMap { event -> String? in
            if case .began(let step, _) = event { return step }
            return nil
        }
        #expect(Set(ran) == Set(steps), "\(run.testDescription): \(ran)")
        #expect(outcome.unfinished.isEmpty, "\(run.testDescription)")
        guard case .probed = outcome.firstCheck.status else {
            Issue.record("\(run.testDescription): \(outcome.firstCheck.status)")
            return
        }
        #expect(outcome.captured.replaced == run.renewal, "\(run.testDescription)")
        #expect(outcome.captured.launchFilesRewritten == (run.renewal ? 1 : 0))
    }

    @Test func eachStepsOwnChangesAreWhatTheSeamTestCounts() throws {
        // A change a step's plan leaves out shows, for a file and for a folder, so the rules above
        // are not met by a seam that notes nothing.
        let folder = TokenPaths.folderName
        let plan = NoFollowWriter.Plan(
            step: "token save", targets: [.file([folder], "lab.json", [.replace])])
        let file = folder + "/lab.json"
        let other = folder + "/other.json"
        let copy = folder + "/copy.json"
        let events: [NoFollowWriter.Trace.Event] = [
            .required("token save", plan.targets), .passed(folder), .proved(folder),
            .checked(folder, .probeList), .checked(file, .deleteRight), .checked(file, .flags),
            .began("token save", plan.targets), .changed(folder),
            .file(folder + "/" + NoFollowWriter.temporaryPrefix + "0a0b0c0d0e0f0a0b", .create),
            .file(file, .replace), .file(other, .replace), .file(copy, .create),
            .changed("backups"), .ended("token save"),
        ]
        let found = SeamRules.findings(events, cut: 6)
        // A new file the plan names nowhere, in a folder the plan only replaces a file in.
        #expect(found.undeclared == ["replace " + other, "create " + copy, "folder backups"])
        #expect(found.unmatchedFiles == ["replace " + other])
        #expect(found.unprovedFolders == ["backups"])
        #expect(found.unreached.isEmpty && found.drifted.isEmpty && found.refusals.isEmpty)
    }

    @Test func aFolderAStepAfterTheSaveReachesFirstIsCheckedBeforeTheSignIn() throws {
        // A list on the status rebuild's own folder, which no earlier step opens, stops the run
        // before the sign-in.
        let t = try home(renewal: true)
        let context = context(t)
        let before = t.fakeLines("args.log").filter { $0 == "setup-token" }.count
        let folder = context.dataRoot.appendingPathComponent("logs")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = ["+a", "everyone allow list", folder.path]
        try task.run()
        task.waitUntilExit()
        defer {
            let clear = Process()
            clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
            clear.arguments = ["-R", "-N", t.home.path]
            try? clear.run()
            clear.waitUntilExit()
        }
        #expect(throws: ToolError(Messages.folderSharedByAccessList("~/.agent-balancer/logs"))) {
            _ = try TokenLogin.signIn(
                context: context, label: "lab", runner: ClaudeRunner(context: context),
                announce: { Issue.record("the sign-in started") }, saved: { _ in })
        }
        #expect(t.fakeLines("args.log").filter { $0 == "setup-token" }.count == before)
    }

    /// Runs `/bin/chmod` with `arguments`.
    func chmod(_ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = arguments
        try? task.run()
        task.waitUntilExit()
    }

    @Test func aLaunchRewriteAndItsCleanupThatFailAfterTheSaveNameNoNewSignIn() throws {
        // The two steps after the save that only a change during the save itself can make fail:
        // an entry lands on the label's launch folder while its launch file is renamed into place,
        // so the rewrite's next pass and the cleanup of the writer's leftovers are refused there.
        let lease = "l-5eedf00d"
        let t = try home(renewal: true, lease: lease)
        let context = context(t)
        let folder = context.dataRoot.appendingPathComponent(LaunchFiles.folder)
            .appendingPathComponent("lab").path
        NoFollowWriter.beforeRename.set(lease + ".json") {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/chmod")
            task.arguments = ["+a", "everyone allow list", folder]
            try task.run()
            task.waitUntilExit()
        }
        defer {
            NoFollowWriter.beforeRename.set(lease + ".json", nil)
            chmod(["-R", "-N", t.home.path])
        }
        let outcome = try TokenLogin.signIn(
            context: context, label: "lab", runner: ClaudeRunner(context: context),
            announce: {}, saved: { _ in })
        let refusal = Messages.folderSharedByAccessList(
            NoFollowWriter.place([LaunchFiles.folder, "lab"]))
        #expect(
            outcome.unfinished == [
                Messages.launchFilesNotRewritten("lab", refusal),
                Messages.launchLeftoversNotDeleted("lab", refusal),
            ], "\(outcome.unfinished)")
        for text in outcome.unfinished {
            #expect(!text.contains("agent-balancer login") && !text.contains("again"), "\(text)")
        }
        guard case .probed = outcome.firstCheck.status else {
            Issue.record("\(outcome.firstCheck.status)")
            return
        }
        #expect(outcome.captured.launchFilesRewritten == 1)
    }

    @Test func theLaunchRewriteUsesTheTokenTheSaveHoldsNeverTheFileReadBack() throws {
        // The new token file is widened as it is renamed into place, so a read back of it would
        // refuse it; the launch files still get the new token and nothing names a new sign-in.
        let t = try home(renewal: true, lease: "l-0c0ffee0")
        let context = context(t)
        let folder = context.dataRoot.appendingPathComponent(TokenPaths.folderName).path
        NoFollowWriter.beforeRename.set("lab.json") {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            where NoFollowWriter.isTemporaryName(name) {
                _ = Darwin.chmod(folder + "/" + name, 0o644)
            }
        }
        defer { NoFollowWriter.beforeRename.set("lab.json", nil) }
        let outcome = try TokenLogin.signIn(
            context: context, label: "lab", runner: ClaudeRunner(context: context),
            announce: {}, saved: { _ in })
        NoFollowWriter.beforeRename.set("lab.json", nil)
        #expect(outcome.unfinished.isEmpty, "\(outcome.unfinished)")
        #expect(outcome.captured.launchFilesRewritten == 1)
        guard case .failed(let issue) = outcome.firstCheck.status else {
            Issue.record("\(outcome.firstCheck.status)")
            return
        }
        #expect(!TokenLogin.afterSave(issue, label: "lab").text.contains("agent-balancer login"))
    }

    @Test func aSavedTokenTheFirstCheckCannotUseNamesDoctorAndNoNewSignIn() throws {
        let t = try home(renewal: false)
        let context = context(t)
        let file = try TokenPaths.fileURL(context: context, label: "lab").path
        // The new token file is widened after the save, before the first check reads it.
        let outcome = try TokenLogin.signIn(
            context: context, label: "lab", runner: ClaudeRunner(context: context),
            announce: {}, saved: { _ in _ = Darwin.chmod(file, 0o644) })
        guard case .failed(let issue) = outcome.firstCheck.status else {
            Issue.record("\(outcome.firstCheck.status)")
            return
        }
        #expect(issue.code == .tokenMissing && issue.text.contains("agent-balancer login"))
        let shown = TokenLogin.afterSave(issue, label: "lab")
        #expect(shown == Issue(.tokenMissing, .error, Messages.savedTokenNotUsable("lab")))
        #expect(!shown.text.contains("agent-balancer login") && !shown.text.contains("sign in"))
    }

    @Test func afterASaveARejectionNamesOneRefreshFirstAndOtherIssuesStayAsTheyAre() {
        let rejected = TokenLogin.afterSave(
            Issue(.loginRejected, .error, Messages.probeLoginRejected), label: "lab")
        #expect(
            rejected.text
                == "The service rejected the new token for 'lab'. Run `agent-balancer refresh --label lab` once; if the service rejects it again, run `agent-balancer login lab` in Terminal."
        )
        let other = Issue(.checkFailed, .error, "Check failed: probe timed out.")
        #expect(TokenLogin.afterSave(other, label: "lab") == other)
        let shared = Issue(.tokenMissing, .error, Messages.tokenFileShared("lab"))
        #expect(TokenLogin.afterSave(shared, label: "lab") == shared)
    }
}

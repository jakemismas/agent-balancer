import Foundation
import Testing

@testable import Core

/// What `uninstall` deletes inside the folders it empties (only the names the tool writes), the
/// token and temporary files it could not delete, the session records and lease window it reads
/// once the lock is held, a link record it cannot save, and the data folder itself.
extension UninstallTests {
    /// Every path under the data folder, relative to it, folders included.
    func entries(_ t: TestHome) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: t.context.dataRoot.path) else {
            return []
        }
        return walker.compactMap { $0 as? String }.sorted()
    }

    /// A job record of the default folder that names `launch`, as a running session's does.
    func record(_ t: TestHome, naming launch: URL) throws {
        let jobs = t.home.appendingPathComponent(".claude/jobs/j1")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "sessionId": "s1", "state": "running", "respawnFlags": ["--settings", launch.path],
        ]
        try JSONSerialization.data(withJSONObject: record).write(
            to: jobs.appendingPathComponent("state.json"))
    }

    // MARK: Only the names the tool writes

    @Test func filesTheToolDidNotMakeInItsFoldersStayAndAreCounted() throws {
        let (t, _) = try setUp()
        let own: [URL] = [
            try plant(t, Layout.stateFolders, Layout.picksLogName, "line\n"),
            try plant(t, Layout.readingsFolders, "pool-a.json"),
            try plant(t, ReadingHistory.folders, "pool-a.jsonl"),
            try plant(t, Layout.logsFolders, Layout.logName, "line\n"),
            try plant(t, Layout.backupsFolders, "config-2026-11-13-2.json"),
            try plant(t, Layout.probeFolders + ["p-0123456789abcdef", "deep"], "x.jsonl"),
            try plant(t, Layout.locksFolders, Layout.lockName("pool-a"), ""),
        ]
        let mine: [URL] = [
            try plant(t, Layout.stateFolders, "my-notes.txt"),
            try plant(t, Layout.stateFolders, "status.json.bak"),
            try plant(t, Layout.stateFolders, ".tmp-notes"),
            try plant(t, Layout.stateFolders, "events-damaged-mine.jsonl"),
            try plant(t, Layout.readingsFolders, "POOL-B.json"),
            try plant(t, ReadingHistory.folders, "pool-a.txt"),
            try plant(t, ReadingHistory.folders, "Not_A_Label.jsonl"),
            try plant(t, Layout.logsFolders, "mine.txt"),
            try plant(t, Layout.logsFolders, ".tmp-0123456789abcdef"),
            try plant(t, Layout.backupsFolders, "config-mine.json"),
            try plant(t, Layout.probeFolders, "notes.txt"),
            try plant(t, Layout.locksFolders, "mine.txt"),
            try plant(t, Layout.locksFolders, "probe-.lock", ""),
            try plant(t, Layout.locksFolders, "xxxxxxpool-a.lock", ""),
        ]
        // A folder the tool never makes is counted once and never opened, whatever is inside,
        // and one with nothing in it is never removed.
        let inside = try plant(t, Layout.stateFolders + ["mine"], StatusBuilder.statusName)
        let alsoInside = try plant(t, Layout.stateFolders + ["mine"], "notes.txt")
        let empty = t.context.dataRoot.appendingPathComponent("state").appendingPathComponent(
            "empty")
        try FileManager.default.createDirectory(
            at: empty, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let emptyProbe = t.context.dataRoot.appendingPathComponent(Layout.probeFolders[0])
            .appendingPathComponent("p-mine")
        try FileManager.default.createDirectory(
            at: emptyProbe, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let folders: [URL] = [
            inside.deletingLastPathComponent(), empty,
            try plant(t, Layout.probeFolders + ["p-not-a-probe"], "x.jsonl")
                .deletingLastPathComponent(),
            emptyProbe,
        ]
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30)
        #expect(plan.stateFiles == 3 && plan.logFiles == 1 && plan.backupFiles == 1)
        #expect(plan.probeFiles == 1 && plan.lockFiles == 2)
        let done = try run(t)
        for url in own { #expect(!exists(url), "\(url.lastPathComponent)") }
        for url in mine + folders + [inside, alsoInside] {
            #expect(exists(url), "\(url.lastPathComponent)")
        }
        #expect(done.entriesLeft == mine.count + folders.count)
        #expect(!done.dataFolderRemoved)

        // The listing removes nothing, an empty folder of the tool's included, at the top or
        // inside another of its folders.
        let bare = try TestHome()
        let empties: [[String]] = [
            Layout.logsFolders, ReadingHistory.folders,
            Layout.probeFolders + ["p-0123456789abcdef", "inner"],
        ]
        for folders in empties {
            try NoFollowWriter(root: bare.context.dataRoot).prepare(folders: folders)
        }
        _ = try Uninstall.plan(context: bare.context, leaseMinutes: 30)
        for folders in empties {
            let url = folders.reduce(bare.context.dataRoot) { $0.appendingPathComponent($1) }
            #expect(exists(url), "\(folders)")
        }
    }

    @Test func aRunOfTheRealWritersThenUninstallLeavesNoneOfTheToolsFiles() throws {
        let t = try TestHome()
        let context = t.context
        let store = ConfigStore(context: context)
        try store.save(Config(accounts: [token()]))
        // Two backups on one day: the second gets its own number.
        try store.save(Config(accounts: [token()]), backup: true)
        try store.save(Config(accounts: [token()]), backup: true)
        _ = try TokenAccounts.install(context: context, label: "pool-a", token: Canaries.oauth())
        let launch = try launchFile(t, "l-0a0b0c0d")
        let hooks = HookRecord(context: context)
        try hooks.record(.empty)
        _ = try hooks.readSettings()
        let now = Date()
        let reading = Reading(
            readAt: now,
            windows: [
                WindowName.sevenDay: WindowReading(
                    usedPercent: 20, resetsAt: now.addingTimeInterval(86_400), readAt: now)
            ])
        try ReadingStore(context: context).save(reading, label: "pool-a")
        try ReadingHistory(context: context).append(
            StatusBuilder.historyLine(account: token(), reading: reading, state: "ok"),
            label: "pool-a")
        try StatusBuilder.rebuild(context: context, now: now)
        StatusBuilder.log(context, "one line")
        try LeaseStore(context: context).save([
            Lease(
                id: "l-0a0b0c0d", label: "pool-a", model: "default",
                at: Date(timeIntervalSince1970: 0))
        ])
        let writer = NoFollowWriter(root: context.dataRoot)
        PickService(context: context).logPick(
            time: now, model: "default", label: "pool-a", leaseId: "l-0a0b0c0d", reason: "picked",
            writer: writer)
        // A damaged events record is set aside under a name of its own.
        try writer.put(
            Data("damaged\n{}\n".utf8), folders: Layout.stateFolders, name: EventLog.fileName)
        let draft = EventDraft(
            label: "pool-a", accountKey: "k-pool-a", type: EventType.accountAdded, code: nil,
            window: nil, resetsAt: nil, notBefore: nil, text: "Added.")
        try EventLog(context: context).append([draft], now: now)
        // A probe folder a stopped probe left, with what it wrote, and the probe's lock.
        let probe = try writer.makeScratchFolder(
            parent: Layout.probeFolders, prefix: Layout.probeFolderPrefix, staleAfter: 3600)
        try writer.put(Data("{}".utf8), folders: Layout.probeFolders + [probe], name: "out.jsonl")
        try writer.put(
            Data("{}".utf8), folders: Layout.probeFolders + [probe, "inner"], name: "x.json")
        let probeLock = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.lockName("pool-a"), wait: 1))
        probeLock.release()
        // What a write stopped before its rename leaves, wherever a whole-file write goes, from a
        // write that stopped two minutes ago.
        let stopped: [[String]] = [
            [], Layout.stateFolders, Layout.readingsFolders, ReadingHistory.folders,
            Layout.backupsFolders, TokenPaths.folders, LaunchFiles.folders(label: "pool-a"),
        ]
        let leftovers = try stopped.map { try plant(t, $0, ".tmp-0123456789abcdef") }
        setTimes(leftovers, to: now.addingTimeInterval(-120))

        let written = entries(t)
        for path in [
            "state/status.json", "state/current.json", "state/events.jsonl", "state/leases.json",
            "state/picks.log", "state/settings-seen.json", "state/readings/pool-a.json",
            "state/history/pool-a.jsonl", "logs/agent-balancer.log", "locks/pick.lock",
            "locks/links.lock", "locks/history.lock", "locks/probe-pool-a.lock",
            "probe/\(probe)/inner/x.json", "links.json", "config.json",
        ] {
            #expect(written.contains(path), "\(path)")
        }
        #expect(written.contains { $0.hasPrefix("state/events-damaged-") })
        #expect(written.filter { $0.hasPrefix("backups/config-") }.count == 2)
        let plan = try Uninstall.plan(context: context, leaseMinutes: 30)
        #expect(plan.temporaries == 2 && plan.dataFolderTemporaries == 1)

        let done = try Uninstall.run(context: context, leaseMinutes: 30, snapshot: .empty)
        #expect(done.launchFiles == 1 && done.tokenFiles == 1 && done.launchFilesKept == 0)
        #expect(done.entriesLeft == 0 && done.temporariesLeft == 0 && done.tokenFilesLeft == 0)
        #expect(!exists(launch))
        #expect(entries(t).isEmpty, "\(entries(t))")
        #expect(done.dataFolderRemoved && !exists(context.dataRoot))
    }

    @Test func theListingCountsWhatTheRemovalDeletes() throws {
        let (t, _) = try setUp()
        let tokenFolder = try tokenFile(t).deletingLastPathComponent()
        let outside = t.home.appendingPathComponent("outside.json")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        // Entries the tool did not make that an older count took for its own.
        try "mine".write(
            to: tokenFolder.appendingPathComponent("Notes.json"), atomically: true,
            encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: tokenFolder.appendingPathComponent("pool-b.json"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: t.context.dataRoot.appendingPathComponent("links.json"),
            withDestinationURL: outside)
        _ = try plant(
            t, Layout.stateFolders, Layout.leasesName, #"{"schemaVersion":1,"leases":[]}"#)
        _ = try plant(t, Layout.stateFolders, "mine.txt")
        _ = try plant(t, Layout.backupsFolders, "config-2026-11-13.json")
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30)
        #expect(plan.tokenFiles == 1 && !plan.hasLinksFile && plan.hasConfig)
        // `Notes.json` is a token file's name in other letter case, so it may hold a token.
        #expect(plan.otherCaseEntries == 1)
        let done = try run(t)
        #expect(done.tokenFiles == plan.tokenFiles)
        #expect(done.launchFiles + done.launchFilesKept == plan.launchFiles)
        #expect(done.otherCaseEntries == plan.otherCaseEntries)
        let listed =
            plan.stateFiles + plan.logFiles + plan.backupFiles + plan.probeFiles + plan.lockFiles
            + (plan.hasLinksFile ? 1 : 0) + (plan.hasConfig ? 1 : 0) + plan.dataFolderTemporaries
        #expect(done.otherFiles == listed)
        // The link in the token folder, the links.json link and the state note.
        #expect(done.entriesLeft == 3)
        #expect(text(outside) == "outside")
    }

    // MARK: A token file or a temporary file uninstall could not delete

    @Test func aTokenFileThatCannotBeDeletedIsCountedOnItsOwnAndListedAgain() throws {
        let (t, _) = try setUp()
        let file = try tokenFile(t)
        let folder = file.deletingLastPathComponent()
        chmod(folder.path, 0o500)
        defer { chmod(folder.path, 0o700) }
        try #require(access(folder.path, W_OK) != 0)
        let done = try run(t)
        #expect(done.tokenFiles == 0 && done.tokenFilesLeft == 1)
        #expect(done.entriesLeft == 0)
        #expect(exists(file))
        let again = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(again.tokenFiles == 1 && !again.isEmpty)
    }

    @Test func aTemporaryFileThatMayHoldATokenIsListedAndARerunStillSeesIt() throws {
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: [token()]))
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let file = try tokenFile(t)
        let folder = file.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".tmp-0123456789abcdef")
        try FileManager.default.copyItem(at: file, to: temporary)
        try FileManager.default.removeItem(at: file)
        #expect(try Uninstall.plan(context: t.context, leaseMinutes: 30).temporaries == 1)
        chmod(folder.path, 0o500)
        defer { chmod(folder.path, 0o700) }
        try #require(access(folder.path, W_OK) != 0)
        let first = try run(t)
        #expect(first.temporariesLeft == 1 && first.entriesLeft == 0)
        #expect(exists(temporary))
        let again = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(again.temporaries == 1 && !again.isEmpty)
    }

    @Test func aLinkOfTheTemporaryShapeIsNotCountedAsATemporaryFile() throws {
        let (t, launch) = try setUp()
        let outside = t.home.appendingPathComponent("outside.json")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let link = launch.deletingLastPathComponent().appendingPathComponent(
            ".tmp-0123456789abcdef")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(try Uninstall.plan(context: t.context, leaseMinutes: 30).temporaries == 0)
        let done = try run(t)
        #expect(done.temporariesLeft == 0 && done.entriesLeft == 1)
        #expect(isLink(link) && text(outside) == "outside")
    }

    // MARK: Read once the lock is held

    @Test func aRecordWrittenWhileUninstallWaitsForTheLockKeepsItsLaunchFile() throws {
        let (t, launch) = try setUp()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 1))
        let context = t.context
        let finished = DispatchSemaphore(value: 0)
        let outcome = Box<Uninstall.Result>()
        onOwnThread {
            outcome.value = try? Uninstall.run(context: context, leaseMinutes: 30)
            finished.signal()
        }
        // The uninstall waits for the lock while a session starts and names the launch file.
        Thread.sleep(forTimeInterval: 0.3)
        try record(t, naming: launch)
        held.release()
        #expect(finished.wait(timeout: .now() + 40) == .success)
        let done = try #require(outcome.value)
        #expect(done.launchFiles == 0 && done.launchFilesKept == 1)
        #expect(try isTombstone(launch))
    }

    @Test func theLeaseWindowIsTheLongerOfTheListedOneAndTheSavedOne() throws {
        // The listing showed 30 minutes; the config now says 6 hours, which covers the 3 hour
        // old file.
        let (t, launch) = try setUp()
        let store = ConfigStore(context: t.context)
        var longer = try store.loadRequired()
        longer.picker.leaseMinutes = 360
        try store.save(longer)
        let done = try run(t)
        #expect(done.launchFiles == 0 && done.launchFilesKept == 1)
        #expect(try isTombstone(launch))
        // A shorter saved window never shortens the one the listing showed.
        let (u, other) = try setUp()
        let shortStore = ConfigStore(context: u.context)
        var shorter = try shortStore.loadRequired()
        shorter.picker.leaseMinutes = 1
        try shortStore.save(shorter)
        let kept = try Uninstall.run(context: u.context, leaseMinutes: 600, snapshot: .empty)
        #expect(kept.launchFiles == 0 && kept.launchFilesKept == 1)
        #expect(try isTombstone(other))
    }

    // MARK: A link record that cannot be saved

    @Test func aLinkRecordThatCannotBeSavedNeverStopsUninstall() throws {
        for body in [#"{"schemaVersion":2,"links":[],"linkedLabels":[]}"#, "not json"] {
            let (t, _) = try setUp()
            _ = try plant(t, [], "links.json", body)
            let done = try run(t)
            #expect(done.tokenFiles == 1, "\(body)")
            #expect(try !exists(tokenFile(t)), "\(body)")
            for name in ["links.json", "config.json", "locks"] {
                #expect(!exists(t.context.dataRoot.appendingPathComponent(name)), "\(name)")
            }
        }
    }

    // MARK: The data folder

    @Test func theDataFolderGoesOnlyWhenNothingIsLeftInIt() throws {
        let (t, _) = try setUp()
        let done = try run(t)
        #expect(done.dataFolderRemoved && done.entriesLeft == 0)
        #expect(!exists(t.context.dataRoot))

        let (u, _) = try setUp()
        let note = u.context.dataRoot.appendingPathComponent("notes.txt")
        try "mine".write(to: note, atomically: true, encoding: .utf8)
        let kept = try run(u)
        #expect(!kept.dataFolderRemoved && kept.entriesLeft == 1)
        #expect(text(note) == "mine")
        // The token and launch folders the run emptied go, even while the data folder stays.
        #expect(!exists(LaunchFiles.rootURL(context: u.context)))
        #expect(try !exists(tokenFile(u).deletingLastPathComponent()))
    }

    @Test func anEmptyDataFolderIsListedAndGoes() throws {
        let t = try TestHome()
        try FileManager.default.createDirectory(
            at: t.context.dataRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30)
        #expect(plan.dataFolderEmpty && !plan.isEmpty)
        let done = try run(t)
        #expect(done.dataFolderRemoved && !exists(t.context.dataRoot))
        #expect(try Uninstall.plan(context: t.context, leaseMinutes: 30).isEmpty)
    }

    @Test func aHomeWithOnlyLocksOrOnlyAProbeFolderStillHasSomethingToRemove() throws {
        let locks = try TestHome()
        _ = try plant(locks, Layout.locksFolders, Layout.pickLockName, "")
        let probe = try TestHome()
        _ = try plant(probe, Layout.probeFolders + ["p-0123456789abcdef"], "x.jsonl")
        for t in [locks, probe] {
            let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30)
            #expect(!plan.isEmpty && !plan.dataFolderEmpty)
            _ = try run(t)
            #expect(!exists(t.context.dataRoot))
        }
    }

    // MARK: Folders that stop the run, and the counts the docs promise

    @Test func aTokenOrLaunchFolderThatIsNotPrivateStopsUninstallBeforeAnyTokenFileGoes() throws {
        for launchSide in [false, true] {
            let (t, launch) = try setUp()
            let folder: URL
            if launchSide {
                folder = LaunchFiles.rootURL(context: t.context)
            } else {
                folder = try tokenFile(t).deletingLastPathComponent()
            }
            let before = try Data(contentsOf: launch)
            chmod(folder.path, 0o755)
            defer { chmod(folder.path, 0o700) }
            #expect(throws: ToolError.self) { _ = try run(t) }
            chmod(folder.path, 0o700)
            #expect(try exists(tokenFile(t)), "\(launchSide)")
            #expect(exists(t.context.dataRoot.appendingPathComponent("config.json")))
            // The check comes before the launch files, so even one nothing names stays as it was.
            #expect(try Data(contentsOf: launch) == before, "\(launchSide)")
            #expect(try !isTombstone(launch), "\(launchSide)")
        }
    }

    @Test func entriesTheToolLeavesAreCountedAndAWriterLeftoverIsNot() throws {
        let (t, launch) = try setUp()
        let root = t.context.dataRoot
        let outside = t.home.appendingPathComponent("outside.json")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        // A link under a name the tool writes in state/, and config.json as a link.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("state"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let stateLink = root.appendingPathComponent("state").appendingPathComponent(
            StatusBuilder.statusName)
        try FileManager.default.createSymbolicLink(at: stateLink, withDestinationURL: outside)
        let config = root.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: outside)
        // A real folder in the launch folder whose name is not a label.
        let odd = LaunchFiles.rootURL(context: t.context).appendingPathComponent("Not_A_Label")
        try FileManager.default.createDirectory(
            at: odd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A writer leftover in the token folder, which its own step deletes.
        let leftover = try tokenFile(t).deletingLastPathComponent().appendingPathComponent(
            ".tmp-0123456789abcdef")
        try "{}".write(to: leftover, atomically: false, encoding: .utf8)
        let done = try run(t)
        #expect(done.tokenFiles == 1 && done.launchFiles == 1 && !exists(launch))
        #expect(done.entriesLeft == 3)
        #expect(isLink(stateLink) && isLink(config) && exists(odd))
        #expect(!exists(leftover))
        #expect(text(outside) == "outside")
    }
}

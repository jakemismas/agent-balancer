import Foundation
import Testing

@testable import Core

/// A data folder, token folder or launch folder that `uninstall` cannot check stops it before it
/// lists or removes anything, and a rerun after the config is gone starts from the default lease
/// window.
extension UninstallTests {
    /// Every file under `folder`, relative to it, with its content; folders as empty data.
    func tree(_ folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return [:] }
        for case let path as String in walker {
            let url = folder.appendingPathComponent(path)
            found[path] = isLink(url) ? Data("link".utf8) : (try? Data(contentsOf: url)) ?? Data()
        }
        return found
    }

    func refusal(_ subject: String, _ place: String, _ mode: mode_t) -> ToolError {
        let problem: NoFollowWriter.FolderProblem =
            mode & 0o077 != 0 ? .widerThanPrivate : .cannotOpen
        return ToolError(Messages.uninstallFolderRefused(subject, place, problem))
    }

    @Test func aDataFolderThatIsALinkIsRefusedAndNothingBehindItChanges() throws {
        let (t, _) = try setUp()
        let moved = t.home.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: t.context.dataRoot, to: moved)
        try FileManager.default.createSymbolicLink(
            at: t.context.dataRoot, withDestinationURL: moved)
        let before = tree(moved)
        #expect(before.keys.contains { $0.hasSuffix("pool-a.json") })
        let refused = ToolError(Messages.uninstallDataFolderIsALink)
        #expect(throws: refused) { _ = try Uninstall.plan(context: t.context, leaseMinutes: 30) }
        #expect(throws: refused) { _ = try run(t) }
        #expect(isLink(t.context.dataRoot))
        #expect(tree(moved) == before)
    }

    /// Adds, or with `on` false clears, an access list entry that denies the owner search access
    /// to `folder` while its mode stays 0700.
    func denySearch(_ folder: URL, _ on: Bool) throws {
        let arguments: [String] =
            on ? ["+a", NSUserName() + " deny search", folder.path] : ["-N", folder.path]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0, "\(folder.lastPathComponent) \(on)")
    }

    @Test func aDataFolderWiderThan0700OrThatCannotBeOpenedIsRefusedAndNothingChanges() throws {
        // At 0600 and 0400 it opens for reading, but nothing in it can be checked.
        let modes: [mode_t] = [0o755, 0o711, 0o705, 0o000, 0o600, 0o400]
        for mode in modes {
            let (t, _) = try setUp()
            let root = t.context.dataRoot
            let before = tree(root)
            chmod(root.path, mode)
            defer { chmod(root.path, 0o700) }
            let refused = refusal("The data folder", "~/.agent-balancer", mode)
            #expect(throws: refused) {
                _ = try Uninstall.plan(context: t.context, leaseMinutes: 30)
            }
            #expect(throws: refused) { _ = try run(t) }
            if mode & 0o100 == 0 {
                // A folder in it that cannot be looked at is never read as missing: one the
                // data folder opens for but `lstat` cannot check, or one it does not open for.
                let entry = NoFollowWriter(root: root).placeEntry(
                    parent: [], name: TokenPaths.folderName)
                let problem: NoFollowWriter.FolderProblem =
                    mode & 0o400 != 0 ? .cannotCheck : .cannotOpen
                #expect(entry == .problem(problem), "\(mode)")
            }
            chmod(root.path, 0o700)
            #expect(tree(root) == before, "\(mode)")
        }
    }

    @Test func aFileWhereTheDataFolderBelongsIsRefused() throws {
        let t = try TestHome()
        try "mine".write(to: t.context.dataRoot, atomically: true, encoding: .utf8)
        let refused = ToolError(Messages.uninstallDataFolderIsNotAFolder)
        #expect(throws: refused) { _ = try Uninstall.plan(context: t.context, leaseMinutes: 30) }
        #expect(throws: refused) { _ = try run(t) }
        #expect(text(t.context.dataRoot) == "mine")
    }

    @Test func aDataFolderInAHomeThatCannotBeSearchedIsRefusedAndNothingChanges() throws {
        let (t, _) = try setUp()
        let before = tree(t.context.dataRoot)
        chmod(t.home.path, 0o000)
        defer { chmod(t.home.path, 0o700) }
        // The data folder cannot even be looked at, which is not the same as missing: `lstat`
        // cannot check it.
        let refused = ToolError(
            Messages.uninstallFolderRefused("The data folder", "~/.agent-balancer", .cannotCheck))
        #expect(throws: refused) { _ = try Uninstall.plan(context: t.context, leaseMinutes: 30) }
        #expect(throws: refused) { _ = try run(t) }
        chmod(t.home.path, 0o700)
        #expect(tree(t.context.dataRoot) == before)
    }

    @Test func aMissingDataFolderHasNothingToRemove() throws {
        let t = try TestHome()
        #expect(try Uninstall.plan(context: t.context, leaseMinutes: 30).isEmpty)
        #expect(!exists(t.context.dataRoot))
    }

    @Test func aTokenOrLaunchFolderThatFailsTheChecksIsRefusedBeforeAnythingGoes() throws {
        let modes: [mode_t] = [0o755, 0o705, 0o000, 0o600, 0o400]
        for which in 0..<3 {
            for mode in modes {
                let (t, launch) = try setUp()
                let folder: URL
                let subject: String
                let place: String
                switch which {
                case 0:
                    folder = try tokenFile(t).deletingLastPathComponent()
                    subject = "The token folder"
                    place = "~/.agent-balancer/" + TokenPaths.folderName
                case 1:
                    folder = LaunchFiles.rootURL(context: t.context)
                    subject = "The launch folder"
                    place = "~/.agent-balancer/" + LaunchFiles.folder
                default:
                    folder = launch.deletingLastPathComponent()
                    subject = "The launch folder"
                    place = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"
                }
                let root = t.context.dataRoot
                let before = tree(root)
                chmod(folder.path, mode)
                defer { chmod(folder.path, 0o700) }
                let refused = refusal(subject, place, mode)
                #expect(throws: refused) {
                    _ = try Uninstall.plan(context: t.context, leaseMinutes: 30)
                }
                #expect(throws: refused) { _ = try run(t) }
                chmod(folder.path, 0o700)
                #expect(tree(root) == before, "\(which) \(mode)")
            }
        }
    }

    @Test func aFolderWhoseAccessListDeniesItsOwnerSearchIsRefusedBeforeAnythingGoes() throws {
        // The mode stays 0700, so only a check of the access itself finds it.
        for which in 0..<4 {
            let (t, launch) = try setUp()
            let root = t.context.dataRoot
            let tokens = try tokenFile(t).deletingLastPathComponent()
            let launchRoot = LaunchFiles.rootURL(context: t.context)
            let label = launch.deletingLastPathComponent()
            let typed = "~/.agent-balancer/"
            let launchPlace = typed + LaunchFiles.folder
            let places: [(folder: URL, subject: String, place: String)] = [
                (root, "The data folder", "~/.agent-balancer"),
                (tokens, "The token folder", typed + TokenPaths.folderName),
                (launchRoot, "The launch folder", launchPlace),
                (label, "The launch folder", launchPlace + "/pool-a"),
            ]
            let item = places[which]
            let before = tree(root)
            try denySearch(item.folder, true)
            defer { try? denySearch(item.folder, false) }
            let refused = refusal(item.subject, item.place, 0o700)
            #expect(throws: refused) {
                _ = try Uninstall.plan(context: t.context, leaseMinutes: 30)
            }
            #expect(throws: refused) { _ = try run(t) }
            try denySearch(item.folder, false)
            #expect(tree(root) == before, "\(item.place)")
        }
    }

    @Test func anUncheckableTokenFileOrTemporaryIsCountedAsOneThatMayHoldAToken() throws {
        let (t, _) = try setUp()
        let file = try tokenFile(t)
        let folder = file.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".tmp-0123456789abcdef")
        try "{}".write(to: temporary, atomically: false, encoding: .utf8)
        defer { chmod(folder.path, 0o700) }
        // The folder passes the check, then stops being searchable during the run.
        let done = try run(t) { step in
            if step == .launchFiles { chmod(folder.path, 0o600) }
        }
        #expect(done.tokenFiles == 0 && done.tokenFilesLeft == 1)
        #expect(done.temporariesLeft == 1 && done.entriesLeft == 0)
        // What the listing counts while it cannot be searched.
        let listed = TokenAccounts.inventory(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(listed.tokenFiles == 1)
        #expect(TokenAccounts.temporariesForUninstall(context: t.context) == 1)
        chmod(folder.path, 0o700)
        #expect(exists(file) && exists(temporary))
    }

    @Test func anUncheckableLaunchFileOrTemporaryIsCountedAsOneThatMayHoldAToken() throws {
        // A label's folder that stops being searchable after the check: the launch step, called
        // past the refusal, stops before any token file goes.
        let (t, launch) = try setUp()
        let folder = launch.deletingLastPathComponent()
        chmod(folder.path, 0o600)
        defer { chmod(folder.path, 0o700) }
        let listed = TokenAccounts.inventory(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(listed.launchFiles == 1)
        let stopped = ToolError(Self.launchStop)
        #expect(throws: stopped) {
            _ = try TokenAccounts.clearLaunchFilesForUninstall(
                context: t.context, leaseMinutes: 30, snapshot: .empty, now: Date())
        }
        chmod(folder.path, 0o700)
        #expect(try exists(launch) && !isTombstone(launch))
        #expect(exists(try tokenFile(t)))
        // A temporary file in a label's folder that stops being searchable during the run.
        let (u, other) = try setUp()
        let labelFolder = other.deletingLastPathComponent()
        let temporary = labelFolder.appendingPathComponent(".tmp-fedcba9876543210")
        try "{}".write(to: temporary, atomically: false, encoding: .utf8)
        defer { chmod(labelFolder.path, 0o700) }
        let done = try run(u) { step in
            if step == .tokenFiles { chmod(labelFolder.path, 0o600) }
        }
        #expect(done.tokenFiles == 1 && done.temporariesLeft == 1 && done.entriesLeft == 0)
        #expect(TokenAccounts.temporariesForUninstall(context: u.context) == 1)
        chmod(labelFolder.path, 0o700)
        #expect(exists(temporary))
    }

    @Test func anEmptyToolFolderThatIsNotPrivateGoesAndIsNotCountedAsLeft() throws {
        let emptied: [[String]] = [
            Layout.logsFolders, Layout.backupsFolders, Layout.probeFolders, ReadingHistory.folders,
        ]
        for folders in emptied {
            let (t, _) = try setUp()
            try NoFollowWriter(root: t.context.dataRoot).prepare(folders: folders)
            let url = folders.reduce(t.context.dataRoot) { $0.appendingPathComponent($1) }
            chmod(url.path, 0o755)
            let done = try run(t)
            #expect(done.entriesLeft == 0, "\(folders)")
            #expect(!exists(url) && done.dataFolderRemoved, "\(folders)")
        }
        // An empty one inside a folder that stays goes too, and only what stays is counted.
        let (u, _) = try setUp()
        let mine = try plant(u, Layout.stateFolders, "mine.txt")
        try NoFollowWriter(root: u.context.dataRoot).prepare(folders: ReadingHistory.folders)
        let history = ReadingHistory.folders.reduce(u.context.dataRoot) {
            $0.appendingPathComponent($1)
        }
        chmod(history.path, 0o755)
        let kept = try run(u)
        #expect(kept.entriesLeft == 1 && !exists(history) && !kept.dataFolderRemoved)
        #expect(text(mine) == "{}")
        // One with something in it is never opened, stays, and is counted.
        let (t, _) = try setUp()
        let note = try plant(t, Layout.logsFolders, "mine.txt")
        let logs = note.deletingLastPathComponent()
        chmod(logs.path, 0o755)
        defer { chmod(logs.path, 0o700) }
        let done = try run(t)
        #expect(done.entriesLeft == 1 && !done.dataFolderRemoved)
        chmod(logs.path, 0o700)
        #expect(text(note) == "{}")
    }

    @Test func aDataFolderTemporaryGoesOnlyUnderTheLinksLockItsWriterHolds() throws {
        let (t, _) = try setUp()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        // A save of links.json in progress: its temporary file is there, and it holds the lock.
        let temporary = try plant(t, [], ".tmp-0123456789abcdef")
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.linksLockName, wait: 1))
        let waited = Uninstall.removeDataFolderTemporaries(writer, lockWait: 0.2)
        #expect(waited == Uninstall.Swept(files: 0, left: 1))
        #expect(exists(temporary))
        held.release()
        let freed = Uninstall.removeDataFolderTemporaries(writer, lockWait: 0.2)
        #expect(freed == Uninstall.Swept(files: 1, left: 0))
        #expect(!exists(temporary))
    }

    @Test func aLinkOfTheTemporaryShapeInTheDataFolderIsCountedOnce() throws {
        let (t, _) = try setUp()
        let outside = t.home.appendingPathComponent("outside.json")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let link = t.context.dataRoot.appendingPathComponent(".tmp-0123456789abcdef")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(try Uninstall.plan(context: t.context, leaseMinutes: 30).dataFolderTemporaries == 0)
        let done = try run(t)
        #expect(done.entriesLeft == 1 && !done.dataFolderRemoved)
        #expect(isLink(link) && text(outside) == "outside")
    }

    @Test func aHomeWithOnlyATemporaryOfTheConfigStillHasSomethingToRemove() throws {
        let t = try TestHome()
        let temporary = try plant(t, [], ".tmp-0123456789abcdef")
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30)
        #expect(plan.dataFolderTemporaries == 1 && !plan.dataFolderEmpty && !plan.isEmpty)
        let done = try run(t)
        #expect(done.entriesLeft == 0)
        #expect(!exists(temporary) && done.dataFolderRemoved)
    }

    @Test func aLeaseWindowSavedWhileUninstallWaitsForTheLockIsTheOneItUses() throws {
        let (t, launch) = try setUp()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 1))
        let context = t.context
        let finished = DispatchSemaphore(value: 0)
        let outcome = Box<Uninstall.Result>()
        onOwnThread {
            outcome.value = try? Uninstall.run(context: context, leaseMinutes: 30, snapshot: .empty)
            finished.signal()
        }
        // While the run waits for the lock, the window grows past the launch file's 3 hours.
        Thread.sleep(forTimeInterval: 0.3)
        let store = ConfigStore(context: context)
        var config = try store.loadRequired()
        config.picker.leaseMinutes = 360
        try store.save(config)
        held.release()
        #expect(finished.wait(timeout: .now() + 40) == .success)
        let done = try #require(outcome.value)
        #expect(done.launchFiles == 0 && done.launchFilesKept == 1)
        #expect(try isTombstone(launch))
    }

    @Test func aRerunStartsFromTheDefaultLeaseWindowOnceTheConfigIsGone() throws {
        let t = try TestHome()
        var config = Config(accounts: [token()])
        config.picker.leaseMinutes = 5
        try ConfigStore(context: t.context).save(config)
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let launch = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-0a0b0c0d", caller: .none)
        #expect(Uninstall.leaseWindow(context: t.context) == 5)
        let first = try Uninstall.run(context: t.context, leaseMinutes: 5, snapshot: .empty)
        #expect(first.launchFilesKept == 1 && first.tokenFiles == 1)
        // The run deleted the config, so a rerun starts from the default window, not from 5.
        let window = Uninstall.leaseWindow(context: t.context)
        #expect(window == PickerSettings().leaseMinutes && window > 7)
        let early = try Uninstall.run(
            context: t.context, leaseMinutes: window, snapshot: .empty,
            now: Date().addingTimeInterval(7 * 60))
        #expect(early.launchFilesKept == 1 && early.launchFiles == 0)
        let late = try Uninstall.run(
            context: t.context, leaseMinutes: window, snapshot: .empty,
            now: Date().addingTimeInterval(Double(window + 2) * 60))
        #expect(late.launchFiles == 1 && late.launchFilesKept == 0)
        #expect(!exists(launch))
    }
}

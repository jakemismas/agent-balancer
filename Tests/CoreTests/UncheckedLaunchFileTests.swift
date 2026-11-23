import Foundation
import Testing

@testable import Core

/// A launch file that `lstat` cannot check may hold a token, so it never reads as gone: the
/// presence check calls it unchecked, a token save names each one its rewrite passed by, and the
/// cleanup of a pick that did not finish names one it could not check or delete.
@Suite struct UncheckedLaunchFileTests {
    func tool(_ path: String, _ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Adds an access list entry that denies the owner `rights` on `url`.
    func deny(_ url: URL, _ rights: String) throws {
        #expect(try tool("/bin/chmod", ["+a", NSUserName() + " deny " + rights, url.path]) == 0)
    }

    /// Removes the access list of `url`, so the home can be checked and removed.
    func clear(_ url: URL) { _ = try? tool("/bin/chmod", ["-N", url.path]) }

    func make(
        _ t: TestHome, _ leaseId: String, kind: String = Kind.token, label: String = "pool-a"
    ) throws -> URL {
        try LaunchFiles.create(
            context: t.context, account: Account(label: label, kind: kind, role: Role.pool),
            leaseId: leaseId, caller: .none)
    }

    func holds(_ url: URL, _ secret: String) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(secret)
    }

    @Test func aLaunchFileLstatCannotCheckIsUncheckedAndNeverMissing() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        func presence(_ id: String) -> LaunchFiles.Presence {
            LaunchFiles.presence(context: t.context, ref: LaunchRef(label: "pool-a", leaseId: id))
        }
        #expect(presence("l-00000001") == .missing)
        let file = try make(t, "l-00000001")
        let folder = file.deletingLastPathComponent()
        defer {
            clear(folder)
            clear(file)
        }
        #expect(presence("l-00000001") == .there)
        #expect(presence("l-00000002") == .missing)
        try deny(file, "readattr")
        #expect(presence("l-00000001") == .unchecked)
        clear(file)
        // In a folder you cannot search, a name that is there and one that is not read the same.
        try deny(folder, "search")
        #expect(presence("l-00000001") == .unchecked)
        #expect(presence("l-00000002") == .unchecked)
        clear(folder)
        #expect(presence("l-00000001") == .there)
    }

    @Test func aTokenSaveNamesEachLaunchFileItsRewritePassedByAndNotOneItRewrote() throws {
        let t = try TestHome()
        let old = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: old)
        let seen = try make(t, "l-00000001")
        let hidden = [try make(t, "l-00000002"), try make(t, "l-00000003")]
        let folder = seen.deletingLastPathComponent()
        for url in hidden { try deny(url, "readattr") }
        // The rewritten file takes this entry from its folder, with the new token in it.
        try deny(folder, "readattr,file_inherit,only_inherit")
        func clearAll() {
            clear(folder)
            for url in [seen] + hidden { clear(url) }
        }
        defer { clearAll() }
        let fresh = Canaries.oauth()
        let saved = try TokenAccounts.install(context: t.context, label: "pool-a", token: fresh)
        #expect(saved.replaced && saved.launchFilesRewritten == 1)
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"
        #expect(
            saved.unfinished == [
                "2 launch files of 'pool-a' could not be checked, rewritten or deleted: `\(place)/l-00000002.json` and `\(place)/l-00000003.json`. Each may keep the old token, and a session that uses one keeps that token until it ends. Run `chflags -h nouchg,nouappnd` first on `\(place)` and on each of these files that is locked. Then run `chmod -h -N \(place)` and `chmod -h 700 \(place)`, and on each of these files `chmod -h -N`, or `chmod -N` where that says Permission denied, then `chmod -h 600`."
            ])
        clearAll()
        let rewritten = holds(seen, fresh)
        let kept = hidden.filter { holds($0, old) }.count
        #expect(rewritten && kept == 2)
    }

    @Test func aTokenSaveNamesEachPathOfALongListInOrder() {
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"
        let one = LaunchFiles.notRewrittenText(label: "pool-a", names: ["l-0000000a.json"])
        #expect(
            one
                == "1 launch file of 'pool-a' could not be checked, rewritten or deleted: `\(place)/l-0000000a.json`. It may keep the old token, and a session that uses the file keeps that token until it ends. Run `chflags -h nouchg,nouappnd` first on `\(place)` and on that file if either is locked. Then run `chmod -h -N \(place)` and `chmod -h 700 \(place)`, and on that file `chmod -h -N`, or `chmod -N` if that says Permission denied, then `chmod -h 600`."
        )
        let three = LaunchFiles.notRewrittenText(
            label: "pool-a", names: ["l-0000000a.json", "l-0000000b.json", "l-0000000c.json"])
        #expect(
            three.hasPrefix(
                "3 launch files of 'pool-a' could not be checked, rewritten or deleted: `\(place)/l-0000000a.json`, `\(place)/l-0000000b.json` and `\(place)/l-0000000c.json`. Each"
            ))
    }

    @Test func theCleanupOfAPickThatDidNotFinishNamesAFileItCouldNotCheckOrDelete() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        func discard(_ id: String, token: Bool = true) -> String? {
            LaunchFiles.discard(
                context: t.context, label: "pool-a", leaseId: id, holdsToken: token,
                command: "pick", rerun: "agent-balancer pick")
        }
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"
        // A file that is not there, or that the delete takes, needs no word.
        #expect(discard("l-00000009") == nil)
        let gone = try make(t, "l-00000001")
        #expect(discard("l-00000001") == nil)
        #expect(!FileManager.default.fileExists(atPath: gone.path))

        let hidden = try make(t, "l-00000002")
        try deny(hidden, "readattr")
        defer { clear(hidden) }
        let unchecked = place + "/l-00000002.json"
        #expect(
            discard("l-00000002")
                == "The launch file `\(unchecked)` that `pick` wrote could not be checked, so it was not deleted and may still hold the token of 'pool-a'. Run `chmod -h -N \(place)` and `chmod -h -N \(unchecked)`, or `chmod -N \(unchecked)` if that says Permission denied. Run `chflags -h nouchg,nouappnd \(place)` first if it is locked. Then run your `agent-balancer pick` command again. The upkeep that `agent-balancer pick` and `agent-balancer refresh` run deletes the file later, as it deletes the file of any pick that holds no lease."
        )
        let listed = try FileManager.default.contentsOfDirectory(
            atPath: hidden.deletingLastPathComponent().path)
        #expect(listed.contains(hidden.lastPathComponent))
        clear(hidden)
        #expect(discard("l-00000002") == nil)

        // A folder with the append-only flag keeps a file it took from being deleted.
        let stuck = try make(t, "l-00000003", kind: Kind.login)
        let folder = stuck.deletingLastPathComponent()
        #expect(try tool("/usr/bin/chflags", ["uappnd", folder.path]) == 0)
        defer { _ = try? tool("/usr/bin/chflags", ["nouappnd", folder.path]) }
        let file = place + "/l-00000003.json"
        #expect(
            discard("l-00000003", token: false)
                == "The launch file `\(file)` that `pick` wrote could not be deleted. Run `chmod -h -N \(place)`, `chmod -h 700 \(place)` and `chmod -h -N \(file)`, or `chmod -N \(file)` if that says Permission denied. Run `chflags -h nouchg,nouappnd \(place)` and `chflags -h nouchg,nouappnd \(file)` first if either is locked. Then run your `agent-balancer pick` command again. The upkeep that `agent-balancer pick` and `agent-balancer refresh` run deletes the file later, as it deletes the file of any pick that holds no lease."
        )
        #expect(try tool("/usr/bin/chflags", ["nouappnd", folder.path]) == 0)
        #expect(discard("l-00000003", token: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: stuck.path))

        // A folder the folder checks refuse once the file is written keeps both the delete and the
        // check out, so the file reads as one that cannot be checked and stays.
        let wide = try make(t, "l-00000004")
        #expect(try tool("/bin/chmod", ["755", folder.path]) == 0)
        defer { _ = try? tool("/bin/chmod", ["700", folder.path]) }
        let refused = place + "/l-00000004.json"
        #expect(
            discard("l-00000004")
                == "The launch file `\(refused)` that `pick` wrote could not be checked, so it was not deleted and may still hold the token of 'pool-a'. Run `chmod -h -N \(place)` and `chmod -h -N \(refused)`, or `chmod -N \(refused)` if that says Permission denied. Run `chflags -h nouchg,nouappnd \(place)` first if it is locked. Then run your `agent-balancer pick` command again. The upkeep that `agent-balancer pick` and `agent-balancer refresh` run deletes the file later, as it deletes the file of any pick that holds no lease."
        )
        #expect(FileManager.default.fileExists(atPath: wide.path))
        #expect(try tool("/bin/chmod", ["700", folder.path]) == 0)
        #expect(discard("l-00000004") == nil)
        #expect(!FileManager.default.fileExists(atPath: wide.path))

        // A link, a folder or another user's file at the name is no file the command wrote, so it
        // gets no word.
        let link = folder.appendingPathComponent("l-0000000e.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: hidden)
        #expect(discard("l-0000000e") == nil)
        let inner = folder.appendingPathComponent("l-0000000f.json")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        #expect(discard("l-0000000f") == nil)
        // root's regular file, linked in where the volume allows it; the delete leaves it alone.
        let rootsFile = URL(fileURLWithPath: "/private/etc/shells")
        let foreign = folder.appendingPathComponent("l-00000010.json")
        if (try? FileManager.default.linkItem(at: rootsFile, to: foreign)) != nil {
            #expect(discard("l-00000010") == nil)
            let listed = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(listed.contains(foreign.lastPathComponent))
        }
    }

    @Test func doctorExitsOneForEachLaunchFileOrFolderItCannotCheck() {
        let clean = DoctorChecks.LaunchSummary(count: 2, oldestAge: 60)
        #expect(!DoctorChecks.launchFilesFail(clean, sessionNamesUnchecked: false))
        #expect(DoctorChecks.launchFilesFail(clean, sessionNamesUnchecked: true))
        var file = clean
        file.unchecked = 1
        #expect(DoctorChecks.launchFilesFail(file, sessionNamesUnchecked: false))
        var refused = clean
        refused.refusedFolders = ["~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"]
        #expect(DoctorChecks.launchFilesFail(refused, sessionNamesUnchecked: false))
        var unlisted = clean
        unlisted.unlistedFolders = ["~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"]
        #expect(DoctorChecks.launchFilesFail(unlisted, sessionNamesUnchecked: false))
    }

    @Test func aTokenSaveGoesOnPastAFileItCannotRewriteOrDeleteAndNamesIt() throws {
        let t = try TestHome()
        let old = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: old)
        let locked = try make(t, "l-00000001")
        let plain = try make(t, "l-00000002")
        let unread = try make(t, "l-00000003")
        // A lock keeps the rewrite's rename out; no mode and a lock keep its read and its delete
        // out, since a file the rewrite cannot read is deleted.
        #expect(try tool("/usr/bin/chflags", ["uchg", locked.path]) == 0)
        #expect(try tool("/bin/chmod", ["000", unread.path]) == 0)
        #expect(try tool("/usr/bin/chflags", ["uchg", unread.path]) == 0)
        func unlock() {
            for url in [locked, unread] { _ = try? tool("/usr/bin/chflags", ["nouchg", url.path]) }
            _ = try? tool("/bin/chmod", ["600", unread.path])
        }
        defer { unlock() }
        let fresh = Canaries.oauth()
        let saved = try TokenAccounts.install(context: t.context, label: "pool-a", token: fresh)
        #expect(saved.launchFilesRewritten == 1)
        #expect(
            saved.unfinished == [
                LaunchFiles.notRewrittenText(
                    label: "pool-a", names: ["l-00000001.json", "l-00000003.json"])
            ])
        unlock()
        let rewritten = holds(plain, fresh)
        let kept = [locked, unread].filter { holds($0, old) }.count
        #expect(rewritten && kept == 2)

        // A session record names the file it cannot read, so the rewrite turns it into a
        // tombstone, and the lock keeps that write out too.
        let named = try TestHome()
        _ = try TokenAccounts.install(context: named.context, label: "pool-a", token: old)
        let used = try make(named, "l-00000004")
        let other = try make(named, "l-00000005")
        #expect(try tool("/bin/chmod", ["000", used.path]) == 0)
        #expect(try tool("/usr/bin/chflags", ["uchg", used.path]) == 0)
        defer {
            _ = try? tool("/usr/bin/chflags", ["nouchg", used.path])
            _ = try? tool("/bin/chmod", ["600", used.path])
            _ = named
        }
        let snapshot = SessionsSnapshot(
            clean: true, named: [LaunchRef(label: "pool-a", leaseId: "l-00000004")])
        let again = try TokenAccounts.install(
            context: named.context, label: "pool-a", token: fresh, snapshot: snapshot)
        #expect(again.launchFilesRewritten == 1)
        #expect(
            again.unfinished == [
                LaunchFiles.notRewrittenText(label: "pool-a", names: ["l-00000004.json"])
            ])
        #expect(try tool("/usr/bin/chflags", ["nouchg", used.path]) == 0)
        #expect(try tool("/bin/chmod", ["600", used.path]) == 0)
        let keptOld = holds(used, old)
        let tookNew = holds(other, fresh)
        #expect(keptOld && tookNew)
    }

    @Test func aTokenSaveNamesAFileWhoseDeleteItsFolderRefusesDuringThePass() throws {
        // The folder turns wider than 0700 while the pass rewrites the first file, so the delete
        // of the next one, a file it cannot read, is refused, and that file keeps the old token.
        let t = try TestHome()
        let old = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: old)
        let first = try make(t, "l-5eed0a01")
        let unread = try make(t, "l-5eed0a02")
        let folder = first.deletingLastPathComponent()
        #expect(try tool("/bin/chmod", ["000", unread.path]) == 0)
        let path = folder.path
        NoFollowWriter.beforeRename.set(first.lastPathComponent) { _ = Darwin.chmod(path, 0o755) }
        defer {
            NoFollowWriter.beforeRename.set(first.lastPathComponent, nil)
            _ = try? tool("/bin/chmod", ["700", folder.path])
            _ = try? tool("/bin/chmod", ["600", unread.path])
        }
        let fresh = Canaries.oauth()
        let saved = try TokenAccounts.install(context: t.context, label: "pool-a", token: fresh)
        NoFollowWriter.beforeRename.set(first.lastPathComponent, nil)
        let refusal = Messages.folderRefused(
            NoFollowWriter.place([LaunchFiles.folder, "pool-a"]), .widerThanPrivate)
        #expect(saved.launchFilesRewritten == 1)
        #expect(
            saved.unfinished == [
                Messages.launchFilesNotRewritten("pool-a", refusal),
                LaunchFiles.notRewrittenText(label: "pool-a", names: [unread.lastPathComponent]),
                Messages.launchLeftoversNotDeleted("pool-a", refusal),
            ])
        #expect(try tool("/bin/chmod", ["700", folder.path]) == 0)
        #expect(try tool("/bin/chmod", ["600", unread.path]) == 0)
        let keptOld = holds(unread, old)
        let tookNew = holds(first, fresh)
        #expect(keptOld && tookNew)
    }

    @Test func theInventoryNamesALaunchFolderItRefusesOrCannotListAndCountsWhatItCan() throws {
        let t = try TestHome()
        let wide = try make(t, "l-0000000a", kind: Kind.login, label: "pool-a")
        _ = try make(t, "l-0000000b", kind: Kind.login, label: "pool-a")
        let shut = try make(t, "l-0000000c", kind: Kind.login, label: "pool-b")
        _ = try make(t, "l-0000000d", kind: Kind.login, label: "pool-c")
        let wideFolder = wide.deletingLastPathComponent()
        let shutFolder = shut.deletingLastPathComponent()
        // Only a name of a launch file's shape counts: not a temporary file, not any other name.
        for name in [".tmp-0123456789abcdef", "notes.txt"] {
            try Data("x\n".utf8).write(to: wideFolder.appendingPathComponent(name))
        }
        #expect(try tool("/bin/chmod", ["755", wideFolder.path]) == 0)
        try deny(shutFolder, "list")
        defer {
            _ = try? tool("/bin/chmod", ["700", wideFolder.path])
            clear(shutFolder)
        }
        let named: Set = [
            LaunchRef(label: "pool-b", leaseId: "l-0000000c"),
            LaunchRef(label: "pool-c", leaseId: "l-0000000d"),
        ]
        let found = LaunchFiles.inventory(
            context: t.context, snapshot: SessionsSnapshot(clean: true, named: named), now: Date())
        let place = "~/.agent-balancer/" + LaunchFiles.folder
        #expect(found.files == 1 && found.named == 1 && found.oldestAge != nil)
        #expect(found.unchecked == 3)
        #expect(found.refusedFolders == [place + "/pool-a"])
        #expect(found.unlistedFolders == [place + "/pool-b"])

        let summary = DoctorChecks.launchFiles(
            context: t.context, snapshot: SessionsSnapshot(clean: true, named: named))
        #expect(summary.count == 4 && summary.unchecked == 3)
        let line = DoctorChecks.launchFilesLine(
            DoctorChecks.LaunchSummary(
                count: 4, oldestAge: 30, unchecked: 3,
                refusedFolders: [place + "/pool-a", place + "/pool-d"],
                unlistedFolders: [place + "/pool-b"]))
        #expect(
            line
                == "launch files: 4, oldest under a minute old, 3 cannot be checked, and the launch folders `\(place)/pool-a` and `\(place)/pool-d` cannot be checked, so each launch file in them counts as one that cannot be checked, and the launch folder `\(place)/pool-b` cannot be checked or listed, so a launch file in it counts only when a session record names it"
        )

        // The launch folder itself, refused for its mode: it is named alone, and each launch file
        // in it counts as one that cannot be checked, a session record naming it or not.
        let wideHome = try TestHome()
        _ = try make(wideHome, "l-0000000a", kind: Kind.login, label: "pool-a")
        _ = try make(wideHome, "l-0000000b", kind: Kind.login, label: "pool-a")
        _ = try make(wideHome, "l-0000000c", kind: Kind.login, label: "pool-b")
        let wideRoot = LaunchFiles.rootURL(context: wideHome.context)
        #expect(try tool("/bin/chmod", ["755", wideRoot.path]) == 0)
        defer {
            _ = try? tool("/bin/chmod", ["700", wideRoot.path])
            _ = wideHome
        }
        let wideSnapshot = SessionsSnapshot(
            clean: true, named: [LaunchRef(label: "pool-b", leaseId: "l-0000000c")])
        let refusedRoot = LaunchFiles.inventory(
            context: wideHome.context, snapshot: wideSnapshot, now: Date())
        #expect(refusedRoot.files == 0 && refusedRoot.named == 0 && refusedRoot.oldestAge == nil)
        #expect(refusedRoot.unchecked == 3)
        #expect(refusedRoot.refusedFolders == [place])
        #expect(refusedRoot.unlistedFolders.isEmpty)
        let refusedSummary = DoctorChecks.launchFiles(
            context: wideHome.context, snapshot: wideSnapshot)
        #expect(refusedSummary.count == 3 && refusedSummary.unchecked == 3)
        #expect(
            DoctorChecks.launchFilesLine(refusedSummary)
                == "launch files: 3, 3 cannot be checked, and the launch folder `\(place)` cannot be checked, so each launch file in it counts as one that cannot be checked"
        )

        // The launch folder itself, with no listing for you: it is named alone, and only the
        // launch files a session record names count, each as one that cannot be checked.
        let shutHome = try TestHome()
        _ = try make(shutHome, "l-0000000a", kind: Kind.login, label: "pool-a")
        _ = try make(shutHome, "l-0000000b", kind: Kind.login, label: "pool-a")
        _ = try make(shutHome, "l-0000000c", kind: Kind.login, label: "pool-b")
        let shutRoot = LaunchFiles.rootURL(context: shutHome.context)
        try deny(shutRoot, "list")
        defer {
            clear(shutRoot)
            _ = shutHome
        }
        let shutSnapshot = SessionsSnapshot(
            clean: true, named: [LaunchRef(label: "pool-b", leaseId: "l-0000000c")])
        let unlistedRoot = LaunchFiles.inventory(
            context: shutHome.context, snapshot: shutSnapshot, now: Date())
        #expect(unlistedRoot.files == 0 && unlistedRoot.named == 0 && unlistedRoot.oldestAge == nil)
        #expect(unlistedRoot.unchecked == 1)
        #expect(unlistedRoot.refusedFolders.isEmpty)
        #expect(unlistedRoot.unlistedFolders == [place])
        let unlistedSummary = DoctorChecks.launchFiles(
            context: shutHome.context, snapshot: shutSnapshot)
        #expect(unlistedSummary.count == 1 && unlistedSummary.unchecked == 1)
        #expect(
            DoctorChecks.launchFilesLine(unlistedSummary)
                == "launch files: 1, 1 cannot be checked, and the launch folder `\(place)` cannot be checked or listed, so a launch file in it counts only when a session record names it"
        )
    }

    @Test func theInventoryCountsNoLinkFolderOrFileOfAnotherUserAsALaunchFile() throws {
        let t = try TestHome()
        let own = try make(t, "l-0000000a", kind: Kind.login)
        let folder = own.deletingLastPathComponent()
        let notFiles = [
            folder.appendingPathComponent("l-0000000b.json"),
            folder.appendingPathComponent("l-0000000c.json"),
            folder.appendingPathComponent("l-0000000d.json"),
        ]
        try FileManager.default.createSymbolicLink(
            at: notFiles[0], withDestinationURL: URL(fileURLWithPath: "/nonexistent"))
        try FileManager.default.createDirectory(
            at: notFiles[1], withIntermediateDirectories: false)
        // root's regular file, linked in where the volume allows it.
        _ = try? FileManager.default.linkItem(
            at: URL(fileURLWithPath: "/private/etc/shells"), to: notFiles[2])
        let named = Set(
            ["l-0000000a", "l-0000000b", "l-0000000c", "l-0000000d"].map {
                LaunchRef(label: "pool-a", leaseId: $0)
            })
        let found = LaunchFiles.inventory(
            context: t.context, snapshot: SessionsSnapshot(clean: true, named: named), now: Date())
        #expect(found.files == 1 && found.named == 1)
        #expect(found.unchecked == 0)
        #expect(found.refusedFolders.isEmpty && found.unlistedFolders.isEmpty)
        let line = DoctorChecks.launchFilesLine(
            DoctorChecks.launchFiles(
                context: t.context, snapshot: SessionsSnapshot(clean: true, named: named)))
        #expect(line == "launch files: 1, oldest under a minute old")
    }
}

/// The menu shows that a launch file cannot be checked as a note on the account's row.
extension ViewModelTests {
    @Test func aLaunchFileThatCannotBeCheckedIsANoteOnTheRow() throws {
        let a = """
            { "label": "p", "role": "pool", "state": "ok",
              "weekly": { "usedPercent": 10, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" },
              "fable": null, "readingsAge": 60,
              "warnings": [ { "code": "launch_file_unchecked",
                              "text": "1 live session names a launch file that cannot be checked. Run `agent-balancer doctor` in Terminal." },
                            { "code": "launch_file_missing",
                              "text": "1 live session names a launch file that is gone." } ] }
            """
        let row = try #require(Self.rows(Self.json(a)).first)
        let texts = row.notes.map(\.text)
        #expect(
            texts.contains {
                $0.hasPrefix("1 live session names a launch file that cannot be checked.")
            },
            "\(texts)")
        #expect(!texts.contains("1 live session names a launch file that is gone."))
    }
}

/// `run`'s abandon names a launch file it could not check, with the pick lock and without it, and
/// only a token account's text says the file may hold a token.
extension RunSettingsVerdictTests {
    @Test func anAbandonedRunNamesALaunchFileItCouldNotCheckWithOrWithoutThePickLock() throws {
        let (t, base) = try setUp(settings: hookBody)
        try installToken(t)
        var service = base
        service.lockWaitSeconds = 0.2
        func chmod(_ arguments: [String]) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/chmod")
            task.arguments = arguments
            try? task.run()
            task.waitUntilExit()
        }
        for (label, holdsToken) in [("pool-a", true), ("main", false)] {
            for holding in [false, true] {
                let name = "\(label) holding the lock \(holding)"
                let launch = try service.prepareRun(label: label, arguments: [])
                let file = launch.arguments[1]
                chmod(["+a", NSUserName() + " deny readattr", file])
                defer { chmod(["-N", file]) }
                var lock: FileLock?
                if holding {
                    lock = try NoFollowWriter(root: t.context.dataRoot).acquireLock(
                        folders: Layout.locksFolders, name: Layout.pickLockName, wait: 5)
                    #expect(lock != nil, "\(name)")
                }
                let left = service.abandon(launch)
                lock?.release()
                #expect(
                    left
                        == LaunchFiles.notDiscardedText(
                            label: label, leaseId: launch.leaseId, holdsToken: holdsToken,
                            checked: false, command: "run", rerun: "agent-balancer run \(label)"),
                    "\(name)")
                #expect(left?.contains("may still hold the token") == holdsToken, "\(name)")
            }
        }

        // A folder account's launch file holds no token either.
        let id = "l-f01de201"
        let spare = Account(label: "spare", kind: Kind.folder, role: Role.pool)
        let file = try LaunchFiles.create(
            context: t.context, account: spare, leaseId: id, caller: .none)
        let launch = RunLaunch(
            label: "spare", kind: Kind.folder, leaseId: id, arguments: ["--settings", file.path],
            line: "", configDir: nil)
        chmod(["+a", NSUserName() + " deny readattr", file.path])
        defer { chmod(["-N", file.path]) }
        let left = service.abandon(launch)
        #expect(
            left
                == LaunchFiles.notDiscardedText(
                    label: "spare", leaseId: id, holdsToken: false, checked: false,
                    command: "run", rerun: "agent-balancer run spare"))
        #expect(left?.contains("may still hold the token") == false)
    }
}

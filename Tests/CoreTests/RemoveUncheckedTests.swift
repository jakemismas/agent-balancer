import Foundation
import Testing

@testable import Core

/// A name of a launch file's shape that `lstat` cannot check may hold the token, so
/// `removeFiles` stops on it before it deletes anything and again at its read-back, keeps the
/// token file, and never counts it among the entries the tool did not make.
@Suite struct RemoveUncheckedTests {
    func chmod(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Adds an access list entry that denies the owner `rights` on `url`.
    func deny(_ url: URL, _ rights: String) throws {
        #expect(try chmod(["+a", NSUserName() + " deny " + rights, url.path]) == 0)
    }

    /// Removes the access list of `url`, so the home can be checked and removed.
    func clear(_ url: URL) { _ = try? chmod(["-N", url.path]) }

    func make(_ t: TestHome, _ leaseId: String) throws -> URL {
        try LaunchFiles.create(
            context: t.context,
            account: Account(label: "pool-a", kind: Kind.token, role: Role.pool),
            leaseId: leaseId, caller: .none)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// What a remove of `pool-a` stops with while `count` launch files cannot be checked, with
    /// `kept` as the sentence on what it kept.
    func stop(_ count: Int, _ kept: String) -> ToolError {
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"
        return ToolError(
            "\(count) launch files of 'pool-a' could not be checked and may hold a token." + kept
                + " Run `chmod -h -N " + place
                + "`, and run `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg,nouappnd "
                + place + "` first if it is locked. Then run `agent-balancer remove pool-a` again."
        )
    }

    @Test func removeFilesStopsBeforeItDeletesAnythingAndCountsEachFileItCannotCheck() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let open = try make(t, "l-00000001")
        let hidden = [try make(t, "l-00000002"), try make(t, "l-00000003")]
        for url in hidden { try deny(url, "readattr") }
        defer { for url in hidden { clear(url) } }
        let leases = LeaseStore(context: t.context)
        try leases.save([Lease(id: "l-00000001", label: "pool-a", model: "m", at: Date())])
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-a")

        #expect(throws: stop(2, " Nothing was deleted.")) {
            try TokenAccounts.removeFiles(context: t.context, label: "pool-a", snapshot: .empty)
        }
        #expect(exists(token) && exists(open))
        #expect(try leases.current(now: Date(), leaseMinutes: 525_600).count == 1)

        for url in hidden { clear(url) }
        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-a", snapshot: .empty)
        #expect(removed.tokenFile && removed.launchFiles == 2 && removed.launchFilesKept == 1)
        #expect(!exists(token))
        let left = t.allText().contains(secret)
        #expect(!left)
    }

    @Test func aTombstoneThatTakesAnAccessListFromItsFolderStopsTheReadBack() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let named = try make(t, "l-00000001")
        let folder = named.deletingLastPathComponent()
        // Passed on to each file written in the folder after this, the tombstone included.
        try deny(folder, "readattr,file_inherit,only_inherit")
        defer {
            clear(folder)
            clear(named)
        }
        let snapshot = SessionsSnapshot(
            clean: true, named: [LaunchRef(label: "pool-a", leaseId: "l-00000001")])

        // The token file is still there and this call deletes no registry entry.
        #expect(throws: stop(1, " The token file was kept.")) {
            try TokenAccounts.removeFiles(context: t.context, label: "pool-a", snapshot: snapshot)
        }
        clear(folder)
        clear(named)
        #expect(exists(try TokenPaths.fileURL(context: t.context, label: "pool-a")))
        let object =
            try JSONSerialization.jsonObject(with: Data(contentsOf: named)) as? [String: Any]
        #expect(object.map(LaunchFiles.isTombstone) == true)

        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-a", snapshot: snapshot)
        #expect(removed.tokenFile && removed.launchFilesKept == 1)
        let left = t.allText().contains(secret)
        #expect(!left)
    }

    @Test func aStopAtTheReadBackNamesNoTokenFileOrAccountThatIsNotThere() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let named = try make(t, "l-00000001")
        try TokenStore.delete(context: t.context, label: "pool-a")
        let folder = named.deletingLastPathComponent()
        try deny(folder, "readattr,file_inherit,only_inherit")
        defer {
            clear(folder)
            clear(named)
        }
        let snapshot = SessionsSnapshot(
            clean: true, named: [LaunchRef(label: "pool-a", leaseId: "l-00000001")])

        #expect(throws: stop(1, "")) {
            try TokenAccounts.removeFiles(context: t.context, label: "pool-a", snapshot: snapshot)
        }
    }

    @Test func aLaunchFileItCannotCheckIsNotCountedAmongTheEntriesTheToolDidNotMake() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let hidden = try make(t, "l-00000001")
        let note = hidden.deletingLastPathComponent().appendingPathComponent("note.txt")
        try "mine".write(to: note, atomically: true, encoding: .utf8)
        try deny(hidden, "readattr")
        defer { clear(hidden) }

        let count = try LaunchFiles.removeAll(
            context: t.context, label: "pool-a", snapshot: .empty, leased: [])
        #expect(count.skipped == 1)
        #expect(count.deleted == 0 && count.tombstoned == 0)
    }

    @Test func aLabelLeftWithOnlyALaunchFileItCannotCheckStillHasLeftoversToRemove() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let hidden = try make(t, "l-00000001")
        // What a remove that counted the file as not the tool's left: no token file, no lease.
        try TokenStore.delete(context: t.context, label: "pool-a")
        try deny(hidden, "readattr")
        defer { clear(hidden) }

        #expect(try TokenAccounts.hasLeftovers(context: t.context, label: "pool-a"))
    }
}

/// A token file that `remove` cannot check may hold the token, so `removeFiles` stops on it before
/// it deletes anything; one it cannot delete, or can no longer check once it tried, stops it
/// before `finish`, so the account stays. Every stop keeps the leases.
extension RemoveUncheckedTests {
    func flags(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// What a remove of `pool-a` stops with while its token file cannot be checked, with `kept`
    /// as the sentence on what it kept.
    func tokenStop(_ kept: String) -> String {
        let file = "~/.agent-balancer/" + TokenPaths.folderName + "/pool-a.json"
        return "The token file `" + file
            + "` cannot be checked, so `remove` cannot tell what it is or whether it still holds the token of 'pool-a'."
            + kept + " Run `chmod -h -N " + file + "`, or `chmod -N " + file
            + "` if that says Permission denied, then run `agent-balancer remove pool-a` again."
    }

    /// What a remove of `pool-a` with no registry entry to keep stops with while its token file is
    /// still there after its delete.
    func notDeletedStop() -> String {
        let tokens = "~/.agent-balancer/" + TokenPaths.folderName
        return "The token file `" + tokens
            + "/pool-a.json` could not be deleted, so it still holds the token of 'pool-a'. On `"
            + tokens
            + "`, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on the token file, or `chmod -N` if that says Permission denied. Run `chflags -h nouchg,nouappnd` first on either of them that is locked. Then run `agent-balancer remove pool-a` again."
    }

    @Test func removeFilesStopsBeforeItDeletesAnythingWhileItCannotCheckTheTokenFile() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let launch = try make(t, "l-00000001")
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        try deny(token, "readattr")
        defer { clear(token) }
        var finished = false

        do {
            _ = try TokenAccounts.removeFiles(
                context: t.context, label: "pool-a", snapshot: .empty, finish: { finished = true })
            Issue.record("the remove did not stop")
        } catch let error as ToolError {
            #expect(error.message == tokenStop(" Nothing was deleted."))
        }
        #expect(!finished && exists(launch))
        clear(token)
        #expect(exists(token))
        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-a", snapshot: .empty, finish: { finished = true })
        #expect(removed.tokenFile && finished && !exists(token))
        let left = t.allText().contains(secret)
        #expect(!left)
    }

    @Test func aTokenFileTheRemoveCannotDeleteStopsItBeforeTheAccountGoes() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        #expect(try flags(["uchg", token.path]) == 0)
        defer { _ = try? flags(["nouchg", token.path]) }
        var finished = false

        do {
            _ = try TokenAccounts.removeFiles(
                context: t.context, label: "pool-a", snapshot: .empty, finish: { finished = true })
            Issue.record("the remove did not stop")
        } catch let error as ToolError {
            #expect(error.message == notDeletedStop())
        }
        #expect(!finished && exists(token))
        #expect(try flags(["nouchg", token.path]) == 0)
        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-a", snapshot: .empty, finish: { finished = true })
        #expect(removed.tokenFile && finished && !exists(token))
    }

    @Test func aStopAtTheTokenFileKeepsTheLeasesSoTheRerunKeepsARecentPicksFile() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let launch = try make(t, "l-00000001")
        let leases = LeaseStore(context: t.context)
        try leases.save([Lease(id: "l-00000001", label: "pool-a", model: "m", at: Date())])
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        #expect(try flags(["uchg", token.path]) == 0)
        defer { _ = try? flags(["nouchg", token.path]) }

        #expect(throws: ToolError(notDeletedStop())) {
            try TokenAccounts.removeFiles(context: t.context, label: "pool-a", snapshot: .empty)
        }
        #expect(try leases.current(now: Date(), leaseMinutes: 525_600).count == 1)
        #expect(try flags(["nouchg", token.path]) == 0)
        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-a", snapshot: .empty)
        #expect(removed.tokenFile && removed.launchFiles == 0 && removed.launchFilesKept == 1)
        #expect(exists(launch))
        #expect(try leases.current(now: Date(), leaseMinutes: 525_600).isEmpty)
        let left = t.allText().contains(secret)
        #expect(!left)
    }

    @Test func theCheckAfterTheDeleteStopsOnATokenFileItCannotCheck() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        try deny(token, "readattr")
        defer { clear(token) }

        for account in [true, false] {
            do {
                try TokenStore.requireDeletedForRemove(
                    context: t.context, label: "pool-a", account: account)
                Issue.record("the check did not stop: \(account)")
            } catch let error as ToolError {
                #expect(error.message == tokenStop(account ? " The account was kept." : ""))
            }
        }
    }

    @Test func aTokenFileItCannotCheckOnceItsDeleteWasTriedKeepsTheAccount() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let launch = try make(t, "l-89dead01")
        let leases = LeaseStore(context: t.context)
        try leases.save([Lease(id: "l-89dead01", label: "pool-a", model: "m", at: Date())])
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        let name = launch.lastPathComponent
        // The recent pick's tombstone is written after the checks before any delete, so only
        // the check after the token file's delete sees this.
        NoFollowWriter.beforeRename.set(name) {
            _ = try chmod(["+a", NSUserName() + " deny readattr", token.path])
        }
        defer {
            NoFollowWriter.beforeRename.set(name, nil)
            clear(token)
        }
        var finished = false

        do {
            _ = try TokenAccounts.removeFiles(
                context: t.context, label: "pool-a", snapshot: .empty, finish: { finished = true })
            Issue.record("the remove did not stop")
        } catch let error as ToolError {
            #expect(error.message == tokenStop(""))
        }
        NoFollowWriter.beforeRename.set(name, nil)
        clear(token)
        #expect(!finished && exists(token))
        #expect(try leases.current(now: Date(), leaseMinutes: 525_600).count == 1)
        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-a", snapshot: .empty, finish: { finished = true })
        #expect(removed.tokenFile && finished && removed.launchFilesKept == 1)
        let left = t.allText().contains(secret)
        #expect(!left)
    }

    @Test func aTokenFileItCannotCheckIsALeftoverARemoveGoesAheadFor() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        try deny(token, "readattr")
        defer { clear(token) }

        #expect(try TokenAccounts.hasLeftovers(context: t.context, label: "pool-a"))
    }
}

import Foundation
import Testing

@testable import Core

private func fileText(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func leaseFiles(_ t: TestHome) -> [URL] {
    let root = LaunchFiles.rootURL(context: t.context)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
}

private func tokenAccount(_ label: String = "pool-a") -> Account {
    Account(label: label, kind: Kind.token, role: Role.pool)
}

private struct Interrupted: Error {}

private func fileMode(_ url: URL) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// The env object of a launch file, or nil when it does not parse.
private func launchEnv(_ url: URL) -> [String: String]? {
    guard let data = try? Data(contentsOf: url),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        object.count == 1
    else { return nil }
    return object["env"] as? [String: String]
}

/// A tombstone's env: the token variable holds a value that is no token, and the label stays.
private func tombstone(_ label: String) -> [String: String] {
    [ProtectedEnv.tokenVariable: "invalid", LaunchFiles.accountVariable: label]
}

/// Dates that `add --ends` and `config set ends` accept.
@Suite struct EndsDateTests {
    @Test func refusesDaysThatDoNotExist() {
        for text in ["2026-13-45", "2026-02-30", "2026-00-10", "2026-04-31", "2027-02-29", "x"] {
            #expect(!ConfigValidator.isValidDate(text), "\(text)")
        }
        #expect(ConfigValidator.isValidDate("2028-02-29"))
        #expect(ConfigValidator.isValidDate("2026-12-31"))
    }

    @Test func acceptsTodayAndLaterButNotThePast() {
        let now = ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z") ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        #expect(ConfigValidator.isTodayOrLater(today, now: now))
        #expect(ConfigValidator.isTodayOrLater("2099-01-01", now: now))
        #expect(!ConfigValidator.isTodayOrLater("2020-01-01", now: now))
        #expect(!ConfigValidator.isTodayOrLater("2026-13-45", now: now))
        let yesterday = formatter.string(from: now.addingTimeInterval(-86_400))
        #expect(!ConfigValidator.isTodayOrLater(yesterday, now: now))
    }

    @Test func aStoredImpossibleDateFailsConfigValidation() {
        let config = Config(accounts: [
            Account(label: "a", kind: Kind.token, role: Role.pool, endsAt: "2026-13-45")
        ])
        #expect(throws: ToolError.self) { try ConfigValidator.validate(config) }
    }
}

@Suite struct TokenWriteInterruptionTests {
    @Test func aFailureBeforeTheRenameLeavesTheOldTokenWhole() throws {
        let t = try TestHome()
        let old = Canaries.oauth()
        let fresh = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-int", token: old)
        let file = try TokenPaths.fileURL(context: t.context, label: "pool-int")
        let before = fileText(file)
        NoFollowWriter.beforeRename.set("pool-int.json") { throw Interrupted() }
        defer { NoFollowWriter.beforeRename.set("pool-int.json", nil) }
        #expect(throws: Interrupted.self) {
            try TokenAccounts.install(context: t.context, label: "pool-int", token: fresh)
        }
        NoFollowWriter.beforeRename.set("pool-int.json", nil)
        #expect(fileText(file) == before)
        #expect(fileText(file).contains(old) && !t.allText().contains(fresh))
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: file.deletingLastPathComponent().path)
        #expect(leftovers.allSatisfy { !$0.hasPrefix(".tmp-") })
    }

    @Test func aFailureBeforeTheRenameOfAFirstTokenLeavesNoFile() throws {
        let t = try TestHome()
        let fresh = Canaries.oauth()
        NoFollowWriter.beforeRename.set("pool-int2.json") { throw Interrupted() }
        defer { NoFollowWriter.beforeRename.set("pool-int2.json", nil) }
        #expect(throws: Interrupted.self) {
            try TokenAccounts.install(context: t.context, label: "pool-int2", token: fresh)
        }
        NoFollowWriter.beforeRename.set("pool-int2.json", nil)
        let file = try TokenPaths.fileURL(context: t.context, label: "pool-int2")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let leftovers =
            (try? FileManager.default.contentsOfDirectory(
                atPath: file.deletingLastPathComponent().path)) ?? []
        #expect(leftovers.allSatisfy { !$0.hasPrefix(".tmp-") })
        #expect(!t.allText().contains(fresh))
    }

    @Test func aReaderDuringTheWriteSeesTheOldFileWhole() throws {
        let t = try TestHome()
        let old = Canaries.oauth()
        let fresh = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-int3", token: old)
        let file = try TokenPaths.fileURL(context: t.context, label: "pool-int3")
        let seen = Box<String>()
        NoFollowWriter.beforeRename.set("pool-int3.json") { seen.value = fileText(file) }
        defer { NoFollowWriter.beforeRename.set("pool-int3.json", nil) }
        _ = try TokenAccounts.install(context: t.context, label: "pool-int3", token: fresh)
        NoFollowWriter.beforeRename.set("pool-int3.json", nil)
        #expect(seen.value?.contains(old) == true && seen.value?.contains(fresh) == false)
        #expect(fileText(file).contains(fresh))
    }
}

/// Runs `body` on its own thread: a race test must not wait on the shared dispatch pool, which
/// other tests in the same run can use up.
func onOwnThread(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.stackSize = 1 << 20
    thread.start()
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

@Suite struct TokenPickRaceTests {
    func setUp(_ label: String) throws -> (TestHome, PickService) {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        try t.fakeProbe("ok.jsonl")
        var config = Config(accounts: [tokenAccount(label)])
        config.fable.probe = false
        let context = t.context
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return (t, PickService(context: context))
    }

    @Test func aPickStartedDuringAReplaceNeverLeavesAFileWithTheOldToken() throws {
        let (t, service) = try setUp("pool-race")
        let old = Canaries.oauth()
        let fresh = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-race", token: old)
        _ = try service.pick(PickRequest())
        #expect(leaseFiles(t).count == 1)

        let inside = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        NoFollowWriter.beforeRename.set("pool-race.json") {
            inside.signal()
            _ = release.wait(timeout: .now() + 20)
        }
        defer { NoFollowWriter.beforeRename.set("pool-race.json", nil) }
        let group = DispatchGroup()
        let context = t.context
        group.enter()
        onOwnThread {
            _ = try? TokenAccounts.install(context: context, label: "pool-race", token: fresh)
            group.leave()
        }
        #expect(inside.wait(timeout: .now() + 20) == .success)
        group.enter()
        onOwnThread {
            _ = try? service.pick(PickRequest())
            group.leave()
        }
        Thread.sleep(forTimeInterval: 0.4)
        release.signal()
        #expect(group.wait(timeout: .now() + 40) == .success)
        NoFollowWriter.beforeRename.set("pool-race.json", nil)

        let files = leaseFiles(t)
        #expect(files.count == 2)
        for url in files {
            #expect(fileText(url).contains(fresh) && !fileText(url).contains(old))
        }
        #expect(!t.allText().contains(old))
    }

    @Test func aPickStartedDuringARemoveFindsNoFileHoldingTheOldToken() throws {
        for round in 0..<8 {
            let (t, service) = try setUp("pool-rm")
            let old = Canaries.oauth()
            _ = try TokenAccounts.install(context: t.context, label: "pool-rm", token: old)
            _ = try service.pick(PickRequest())
            let group = DispatchGroup()
            let context = t.context
            group.enter()
            onOwnThread {
                _ = try? TokenAccounts.removeFiles(
                    context: context, label: "pool-rm", snapshot: .empty)
                group.leave()
            }
            for _ in 0..<3 {
                group.enter()
                onOwnThread {
                    _ = try? service.pick(PickRequest())
                    group.leave()
                }
            }
            #expect(group.wait(timeout: .now() + 60) == .success, "round \(round)")
            for url in leaseFiles(t) {
                #expect(!fileText(url).contains(old), "round \(round)")
            }
            #expect(!t.allText().contains(old), "round \(round)")
        }
    }
}

@Suite struct RemoveNamedLaunchFileTests {
    @Test func aFileASessionNamesIsOverwrittenWithoutTheTokenAndKept() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let named = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-00000001", caller: .none)
        let free = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-00000002", caller: .none)
        #expect(fileText(named).contains(secret))

        let snapshot = SessionsSnapshot(
            clean: true, named: [LaunchRef(label: "pool-a", leaseId: "l-00000001")])
        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-a", snapshot: snapshot)
        #expect(
            removed == TokenAccounts.Removed(tokenFile: true, launchFiles: 1, launchFilesKept: 1))
        #expect(!FileManager.default.fileExists(atPath: free.path))
        #expect(FileManager.default.fileExists(atPath: named.path))
        let kept = fileText(named)
        #expect(!kept.contains(secret))
        #expect(launchEnv(named) == tombstone("pool-a"))
        #expect(fileMode(named) == 0o600)
        #expect(!t.allText().contains(secret))

        // Once no record names it, upkeep removes it.
        let gone = Upkeep.run(
            context: t.context, snapshot: .empty, openLeases: [], leaseMinutes: 1, keepDays: 1,
            now: Date().addingTimeInterval(3_600))
        #expect(gone == 1)
        #expect(!FileManager.default.fileExists(atPath: named.path))
    }

    @Test func anUnreadableRecordSetKeepsEveryFileTokenFree() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let one = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-00000001", caller: .none)
        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-a", snapshot: .unreadable)
        #expect(removed.launchFiles == 0 && removed.launchFilesKept == 1)
        #expect(FileManager.default.fileExists(atPath: one.path))
        #expect(!t.allText().contains(secret))
    }

    @Test func theDefaultReadsTheRealSessionRecords() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let named = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-0000000a", caller: .none)
        let sessions = t.context.defaultClaudeFolder.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record =
            "{\"sessionId\":\"s1\",\"pid\":1,\"args\":[\"--settings\",\"\(named.path)\"]}"
        try record.write(
            to: sessions.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        let removed = try TokenAccounts.removeFiles(context: t.context, label: "pool-a")
        #expect(removed.launchFilesKept == 1 && removed.launchFiles == 0)
        #expect(!fileText(named).contains(secret))
    }
}

extension TokenPickRaceTests {
    @Test func aPickBetweenTheFirstListingAndTheEndOfARemoveLeavesNoOldToken() throws {
        let (t, service) = try setUp("pool-mid")
        let old = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-mid", token: old)
        _ = try service.pick(PickRequest())
        let first = try #require(leaseFiles(t).first)
        let context = t.context
        let late = Box<URL>()
        let group = DispatchGroup()
        // The pick's lease is open, so the remove overwrites its file, after the first listing.
        // At that point a file appears as if a pick wrote it, and a real pick starts.
        NoFollowWriter.beforeRename.set(first.lastPathComponent) {
            late.value = try? LaunchFiles.create(
                context: context, account: tokenAccount("pool-mid"), leaseId: "l-0dd0dd01",
                caller: .none)
            group.enter()
            onOwnThread {
                _ = try? service.pick(PickRequest())
                group.leave()
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        defer { NoFollowWriter.beforeRename.set(first.lastPathComponent, nil) }
        let removed = try TokenAccounts.removeFiles(context: context, label: "pool-mid")
        NoFollowWriter.beforeRename.set(first.lastPathComponent, nil)
        #expect(group.wait(timeout: .now() + 60) == .success)

        let written = try #require(late.value)
        #expect(!exists(written))
        #expect(removed.launchFiles == 1 && removed.launchFilesKept == 1)
        #expect(launchEnv(first) == tombstone("pool-mid"))
        for url in leaseFiles(t) {
            #expect(!fileText(url).contains(old))
        }
        #expect(!t.allText().contains(old))
    }
}

/// Remove and replace keep or clear each launch file by the rules of docs/ARCHITECTURE.md
/// section 4A.4, and a remove that stops part way is finished by a rerun.
@Suite struct RemoveAndReplaceRuleTests {
    @Test func aFileWithAnOpenLeaseBecomesATombstoneAndOthersAreDeleted() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-ls", token: secret)
        let account = tokenAccount("pool-ls")
        let open = try LaunchFiles.create(
            context: t.context, account: account, leaseId: "l-00000001", caller: .none)
        let ended = try LaunchFiles.create(
            context: t.context, account: account, leaseId: "l-00000002", caller: .none)
        let none = try LaunchFiles.create(
            context: t.context, account: account, leaseId: "l-00000003", caller: .none)
        let leases = LeaseStore(context: t.context)
        try leases.save([
            Lease(id: "l-00000001", label: "pool-ls", model: "m", at: Date()),
            Lease(
                id: "l-00000002", label: "pool-ls", model: "m",
                at: Date().addingTimeInterval(-3_600)),
        ])
        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-ls", leaseMinutes: 10, snapshot: .empty)
        #expect(
            removed == TokenAccounts.Removed(tokenFile: true, launchFiles: 2, launchFilesKept: 1))
        #expect(launchEnv(open) == tombstone("pool-ls"))
        #expect(fileMode(open) == 0o600)
        #expect(!exists(ended) && !exists(none))
        #expect(try leases.current(now: Date(), leaseMinutes: 525_600).isEmpty)
        #expect(!t.allText().contains(secret))
    }

    @Test func aRemoveStoppedPartWayKeepsItsTokenFileAndARerunFinishes() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-cr", token: secret)
        let account = tokenAccount("pool-cr")
        let named = try LaunchFiles.create(
            context: t.context, account: account, leaseId: "l-c0ffee01", caller: .none)
        let other = try LaunchFiles.create(
            context: t.context, account: account, leaseId: "l-c0ffee02", caller: .none)
        try ReadingStore(context: t.context).save(
            Reading(readAt: Date(), windows: [:], fable: nil), label: "pool-cr")
        try LeaseStore(context: t.context).save([
            Lease(id: "l-c0ffee0f", label: "pool-cr", model: "m", at: Date())
        ])
        let snapshot = SessionsSnapshot(
            clean: true, named: [LaunchRef(label: "pool-cr", leaseId: "l-c0ffee01")])
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-cr")

        // The process stops while it turns the named file into a tombstone.
        NoFollowWriter.beforeRename.set("l-c0ffee01.json") { throw Interrupted() }
        defer { NoFollowWriter.beforeRename.set("l-c0ffee01.json", nil) }
        #expect(throws: Interrupted.self) {
            try TokenAccounts.removeFiles(context: t.context, label: "pool-cr", snapshot: snapshot)
        }
        NoFollowWriter.beforeRename.set("l-c0ffee01.json", nil)
        #expect(exists(token))
        #expect(try TokenAccounts.hasLeftovers(context: t.context, label: "pool-cr"))

        let rerun = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-cr", snapshot: snapshot)
        #expect(rerun.tokenFile && rerun.launchFilesKept == 1)
        #expect(!exists(token) && !exists(other))
        #expect(launchEnv(named) == tombstone("pool-cr"))
        #expect(try ReadingStore(context: t.context).load(label: "pool-cr") == nil)
        let leases = try LeaseStore(context: t.context).current(now: Date(), leaseMinutes: 525_600)
        #expect(leases.isEmpty)
        #expect(!(try TokenAccounts.hasLeftovers(context: t.context, label: "pool-cr")))
        #expect(!t.allText().contains(secret))
    }

    @Test func aLaunchFileStillHoldingATokenStopsTheRemoveBeforeTheTokenFile() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-rb", token: secret)
        let first = try LaunchFiles.create(
            context: t.context, account: tokenAccount("pool-rb"), leaseId: "l-0b0b0b01",
            caller: .none)
        let dir = first.deletingLastPathComponent()
        let body = try String(contentsOf: first, encoding: .utf8)
        let ids = (1...6).map { "l-0b0b0b0\($0)" }
        // Each tombstone write lets another file holding the token appear, more often than the
        // remove lists again, so one is still there at the read-back.
        for (id, next) in zip(ids, ids.dropFirst()) {
            NoFollowWriter.beforeRename.set(id + ".json") {
                try body.write(
                    to: dir.appendingPathComponent(next + ".json"), atomically: true,
                    encoding: .utf8)
            }
        }
        defer { for id in ids { NoFollowWriter.beforeRename.set(id + ".json", nil) } }
        let snapshot = SessionsSnapshot(
            clean: true, named: Set(ids.map { LaunchRef(label: "pool-rb", leaseId: $0) }))
        #expect(throws: ToolError.self) {
            try TokenAccounts.removeFiles(context: t.context, label: "pool-rb", snapshot: snapshot)
        }
        for id in ids { NoFollowWriter.beforeRename.set(id + ".json", nil) }
        let token = try TokenPaths.fileURL(context: t.context, label: "pool-rb")
        #expect(exists(token))

        let rerun = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-rb", snapshot: snapshot)
        #expect(rerun.tokenFile)
        #expect(!exists(token))
        for id in ids {
            #expect(launchEnv(dir.appendingPathComponent(id + ".json")) == tombstone("pool-rb"))
        }
        #expect(!t.allText().contains(secret))
    }

    @Test func removeDeletesTheWritersLeftoversAndCountsWhatItDidNotMake() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-lo", token: secret)
        let launched = try LaunchFiles.create(
            context: t.context, account: tokenAccount("pool-lo"), leaseId: "l-00000001",
            caller: .none)
        let dir = launched.deletingLastPathComponent()
        let leftover = dir.appendingPathComponent(".tmp-0123456789abcdef")
        try "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(secret)\"}}".write(
            to: leftover, atomically: false, encoding: .utf8)
        let outside = t.home.appendingPathComponent("outside.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("l-00000002.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let note = dir.appendingPathComponent("note.txt")
        try "mine".write(to: note, atomically: true, encoding: .utf8)
        #expect(try TokenAccounts.hasLeftovers(context: t.context, label: "pool-lo"))

        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-lo", snapshot: .empty)
        #expect(removed.launchFiles == 1 && removed.launchEntriesSkipped == 2)
        #expect(!exists(leftover) && !exists(launched))
        #expect(fileText(outside) == "keep" && fileText(note) == "mine")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(!t.allText().contains(secret))
    }

    @Test func aReplaceRewritesOnlyLiveFilesAndNeverKeepsTheOldTokenInABrokenOne() throws {
        let t = try TestHome()
        let old = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-rp", token: old)
        let account = tokenAccount("pool-rp")
        func make(_ id: String) throws -> URL {
            try LaunchFiles.create(context: t.context, account: account, leaseId: id, caller: .none)
        }
        let live = try make("l-00000001")
        let grave = try make("l-00000002")
        let brokenNamed = try make("l-00000003")
        let brokenOther = try make("l-00000004")
        let graveBody =
            "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"invalid\",\"\(LaunchFiles.accountVariable)\":\"pool-rp\"}}"
        try graveBody.write(to: grave, atomically: true, encoding: .utf8)
        let broken = "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(old)\""
        for url in [brokenNamed, brokenOther] {
            try broken.write(to: url, atomically: true, encoding: .utf8)
        }
        for url in [grave, brokenNamed, brokenOther] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let snapshot = SessionsSnapshot(
            clean: true,
            named: [
                LaunchRef(label: "pool-rp", leaseId: "l-00000002"),
                LaunchRef(label: "pool-rp", leaseId: "l-00000003"),
            ])

        let fresh = Canaries.oauth()
        let installed = try TokenAccounts.install(
            context: t.context, label: "pool-rp", token: fresh, snapshot: snapshot)
        #expect(installed.replaced && installed.launchFilesRewritten == 1)
        #expect(launchEnv(live)?[ProtectedEnv.tokenVariable] == fresh)
        #expect(launchEnv(grave) == tombstone("pool-rp"))
        #expect(launchEnv(brokenNamed) == tombstone("pool-rp"))
        #expect(fileMode(brokenNamed) == 0o600)
        #expect(!exists(brokenOther))
        #expect(!t.allText().contains(old))
    }

    @Test func aTokenFileWithNoAccountIsListedByLabel() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        _ = try TokenAccounts.install(context: t.context, label: "pool-b", token: Canaries.oauth())
        let config = Config(accounts: [tokenAccount("pool-a")])
        #expect(
            TokenAccounts.labelsWithoutAccount(context: t.context, config: config) == ["pool-b"])
        let both = Config(accounts: [tokenAccount("pool-a"), tokenAccount("pool-b")])
        #expect(TokenAccounts.labelsWithoutAccount(context: t.context, config: both).isEmpty)
    }
}

extension RemoveAndReplaceRuleTests {
    @Test func aReplaceWithUnreadableRecordsTombstonesEveryBrokenFile() throws {
        let t = try TestHome()
        let old = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-ur", token: old)
        let account = tokenAccount("pool-ur")
        let live = try LaunchFiles.create(
            context: t.context, account: account, leaseId: "l-00000001", caller: .none)
        let broken = try LaunchFiles.create(
            context: t.context, account: account, leaseId: "l-00000002", caller: .none)
        try "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(old)\"".write(
            to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: broken.path)

        // No record names the broken file, but the records could not be read, so a session may.
        let fresh = Canaries.oauth()
        let installed = try TokenAccounts.install(
            context: t.context, label: "pool-ur", token: fresh,
            snapshot: SessionsSnapshot(clean: false, named: []))
        #expect(installed.replaced && installed.launchFilesRewritten == 1)
        #expect(launchEnv(live)?[ProtectedEnv.tokenVariable] == fresh)
        #expect(launchEnv(broken) == tombstone("pool-ur"))
        #expect(fileMode(broken) == 0o600)
        #expect(!t.allText().contains(old))
    }
}

/// A write stopped between its temporary file and its rename leaves a file of the writer's
/// temporary shape that may hold a whole token. Remove, replace and upkeep delete them.
@Suite struct WriterLeftoverTests {
    /// A file of the writer's temporary shape holding `secret`, as a killed write leaves it.
    func plant(_ dir: URL, _ secret: String, name: String = ".tmp-0123456789abcdef") throws -> URL {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(name)
        try "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(secret)\"}}".write(
            to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func tokenFolder(_ t: TestHome) throws -> URL {
        try TokenPaths.fileURL(context: t.context, label: "pool-a").deletingLastPathComponent()
    }

    @Test func removeDeletesTheLeftoversInBothFoldersAndLeavesTheTokenNowhere() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-tl", token: secret)
        let launched = try LaunchFiles.create(
            context: t.context, account: tokenAccount("pool-tl"), leaseId: "l-00000001",
            caller: .none)
        let inTokens = try plant(try tokenFolder(t), secret)
        let inLaunch = try plant(
            launched.deletingLastPathComponent(), secret, name: ".tmp-fedcba9876543210")
        #expect(TokenAccounts.writerLeftovers(context: t.context) == 2)

        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-tl", snapshot: .empty)
        #expect(removed.tokenFile && removed.temporariesLeft == 0)
        #expect(!exists(inTokens) && !exists(inLaunch))
        #expect(TokenAccounts.writerLeftovers(context: t.context) == 0)
        #expect(!t.allText().contains(secret))
    }

    @Test func removeCountsALeftoverItCouldNotDeleteAndNeverFollowsIt() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-tc", token: Canaries.oauth())
        let outside = t.home.appendingPathComponent("outside.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        let link = try tokenFolder(t).appendingPathComponent(".tmp-00112233aabbccdd")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let removed = try TokenAccounts.removeFiles(
            context: t.context, label: "pool-tc", snapshot: .empty)
        #expect(removed.tokenFile && removed.temporariesLeft == 1)
        #expect(fileText(outside) == "keep")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        // A link is not a leftover of the writer, so it is never reported as one.
        #expect(TokenAccounts.writerLeftovers(context: t.context) == 0)
    }

    @Test func aReplaceDeletesTheLeftoversAndLeavesTheOldTokenNowhere() throws {
        let t = try TestHome()
        let old = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-tr", token: old)
        let launched = try LaunchFiles.create(
            context: t.context, account: tokenAccount("pool-tr"), leaseId: "l-00000001",
            caller: .none)
        let inTokens = try plant(try tokenFolder(t), old)
        let inLaunch = try plant(
            launched.deletingLastPathComponent(), old, name: ".tmp-fedcba9876543210")

        let fresh = Canaries.oauth()
        let installed = try TokenAccounts.install(
            context: t.context, label: "pool-tr", token: fresh, snapshot: .empty)
        #expect(installed.replaced && installed.launchFilesRewritten == 1)
        #expect(!exists(inTokens) && !exists(inLaunch))
        #expect(!t.allText().contains(old))
    }

    @Test func upkeepDeletesTheLeftoversOfEveryLabelAndCountsOnlyLaunchFiles() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-tu", token: secret)
        let launched = try LaunchFiles.create(
            context: t.context, account: tokenAccount("pool-tu"), leaseId: "l-00000001",
            caller: .none)
        let inTokens = try plant(try tokenFolder(t), secret)
        let inLaunch = try plant(
            launched.deletingLastPathComponent(), secret, name: ".tmp-fedcba9876543210")
        let other = LaunchFiles.rootURL(context: t.context).appendingPathComponent("gone-label")
        let inOther = try plant(other, secret, name: ".tmp-aaaaaaaaaaaaaaaa")

        // The launch file is new and its records are clean, so only the leftovers go.
        let removed = Upkeep.run(
            context: t.context, snapshot: .empty, openLeases: [], leaseMinutes: 60, keepDays: 1,
            now: Date())
        #expect(removed == 0)
        #expect(exists(launched))
        #expect(!exists(inTokens) && !exists(inLaunch) && !exists(inOther))
        #expect(TokenAccounts.writerLeftovers(context: t.context) == 0)
    }
}

/// `login` and `remove` both take the pick lock; the registry entry decides which one wins.
@Suite struct LoginRemoveRaceTests {
    @Test func aLoginWaitingOnTheLockWritesNothingWhenItsAccountWasRemoved() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        try store.save(Config(accounts: [tokenAccount("pool-lr")]))
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let lock = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 1))
        let failure = Box<String>()
        let done = DispatchSemaphore(value: 0)
        let context = t.context
        let token = Canaries.oauth()
        onOwnThread {
            do {
                _ = try TokenAccounts.install(
                    context: context, label: "pool-lr", token: token, requireAccount: true)
            } catch let error as ToolError {
                failure.value = error.message
            } catch {
                failure.value = "other"
            }
            done.signal()
        }
        // The login is waiting on the lock while the remove drops the entry and lets go.
        Thread.sleep(forTimeInterval: 0.3)
        try store.save(Config(accounts: []))
        lock.release()
        #expect(done.wait(timeout: .now() + 40) == .success)
        #expect(failure.value?.contains("No account is labelled 'pool-lr'") == true)
        #expect(!exists(try TokenPaths.fileURL(context: t.context, label: "pool-lr")))
        #expect(!t.allText().contains(token))
    }

    @Test func removeDropsTheEntryWhileItStillHoldsThePickLock() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        try store.save(Config(accounts: [tokenAccount("pool-rl")]))
        _ = try TokenAccounts.install(context: t.context, label: "pool-rl", token: Canaries.oauth())
        let root = t.context.dataRoot
        let me = UInt(bitPattern: pthread_self())
        let seen = HookCalls()
        // Every test shares the hook, so it looks only at the config write on this thread.
        NoFollowWriter.beforeRename.set(ConfigStore.fileName) {
            guard UInt(bitPattern: pthread_self()) == me else { return }
            let other = try NoFollowWriter(root: root).acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 0)
            seen.add(other == nil ? "held" : "free")
            other?.release()
        }
        defer { NoFollowWriter.beforeRename.set(ConfigStore.fileName, nil) }
        _ = try TokenAccounts.removeAccount(
            context: t.context, label: "pool-rl", config: try store.loadRequired())
        #expect(seen.labels == ["held"])
        #expect(try store.loadRequired().account("pool-rl") == nil)
        #expect(!exists(try TokenPaths.fileURL(context: t.context, label: "pool-rl")))
    }

    @Test func removeKeepsAnAccountAddedAndSignedInAfterItsCallerLoadedTheConfig() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        try store.save(Config(accounts: [tokenAccount("pool-ra")]))
        _ = try TokenAccounts.install(context: t.context, label: "pool-ra", token: Canaries.oauth())
        // `remove pool-ra` reads the config before it waits on the lock.
        let loadedByRemove = try store.loadRequired()
        // `add pool-rb` and `login pool-rb` land while that remove waits.
        try TokenAccounts.updateConfig(context: t.context, backup: true) {
            $0.accounts.append(tokenAccount("pool-rb"))
        }
        let token = Canaries.oauth()
        _ = try TokenAccounts.install(
            context: t.context, label: "pool-rb", token: token, requireAccount: true)
        _ = try TokenAccounts.removeAccount(
            context: t.context, label: "pool-ra", config: loadedByRemove)
        let after = try store.loadRequired()
        #expect(after.account("pool-ra") == nil)
        #expect(after.account("pool-rb")?.kind == Kind.token)
        #expect(TokenAccounts.labelsWithoutAccount(context: t.context, config: after).isEmpty)
        #expect(
            fileText(try TokenPaths.fileURL(context: t.context, label: "pool-rb")).contains(token))
        #expect(!exists(try TokenPaths.fileURL(context: t.context, label: "pool-ra")))
    }

    @Test func aLoginForAnAccountThatIsStillThereSavesTheToken() throws {
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: [tokenAccount("pool-lk")]))
        let token = Canaries.oauth()
        _ = try TokenAccounts.install(
            context: t.context, label: "pool-lk", token: token, requireAccount: true)
        #expect(
            fileText(try TokenPaths.fileURL(context: t.context, label: "pool-lk")).contains(token))
        // A login account of that label is not a token account, so nothing is saved for it.
        try ConfigStore(context: t.context).save(
            Config(accounts: [Account(label: "pool-ll", kind: Kind.login, role: Role.pool)]))
        #expect(throws: ToolError.self) {
            try TokenAccounts.install(
                context: t.context, label: "pool-ll", token: Canaries.oauth(),
                requireAccount: true)
        }
        #expect(!exists(try TokenPaths.fileURL(context: t.context, label: "pool-ll")))
    }
}

import Foundation
import Testing

@testable import Core

/// The result of a refresh run on a thread of its own, once it ends.
private final class Ended: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: AccountRefresh?

    func set(_ result: AccountRefresh) {
        condition.lock()
        value = result
        condition.broadcast()
        condition.unlock()
    }

    /// The result, waiting up to `seconds` for it.
    func get(within seconds: TimeInterval) -> AccountRefresh? {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        defer { condition.unlock() }
        while value == nil && condition.wait(until: deadline) {}
        return value
    }
}

/// A wall clock that moves forward makes nothing in use look old: launch file upkeep and the probe
/// folder cleanup judge ages at the earlier of the clock and the newest time the tool recorded,
/// read from its own files, never from a time a file's metadata holds.
@Suite struct ClockJumpTests {
    func main() -> Account {
        Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
    }

    func home(_ accounts: [Account]) throws -> (TestHome, Config) {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        try t.fakeProbe("ok.jsonl")
        var config = Config(accounts: accounts)
        config.fable.probe = false
        // A held probe or a pick's probes outlast no bound on a loaded machine.
        config.probe.timeoutSeconds = 300
        config.picker.deadlineSeconds = 300
        try ConfigStore(context: t.context).save(config)
        try HookRecord(context: t.context).record(.empty)
        return (t, config)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Waits up to two minutes for `check` to hold.
    func wait(_ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(120)
        while !check() {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    @Test func aPickAfterTheClockMovedForwardKeepsTheLaunchFileOfAPickNoRecordNamesYet() throws {
        let (t, config) = try home([main()])
        var service = PickService(context: t.context)
        let first = try service.pick(PickRequest(caller: .launcher))
        let file = URL(fileURLWithPath: try #require(first.args).last ?? "")
        #expect(exists(file))

        // The clock moves past the lease, and no session record names the file yet.
        let moved = Date().addingTimeInterval(Double(config.picker.leaseMinutes) * 60 + 600)
        service.clock = { moved }
        let second = try service.pick(PickRequest(caller: .launcher))
        #expect(second.label == "main")
        #expect(exists(file))

        // Once the tool has recorded a time after the move, the file is judged by it, as by a
        // steady clock.
        let third = try service.pick(PickRequest(caller: .launcher))
        #expect(third.label == "main")
        #expect(!exists(file))
    }

    @Test func upkeepJudgesAgesAtTheNewestTimeTheToolRecorded() throws {
        let t = try TestHome()
        let file = try LaunchFiles.fileURL(
            context: t.context, label: "pool-a", leaseId: "l-00000001")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let now = Date()
        let moved = now.addingTimeInterval(40 * 86_400)
        func run(_ snapshot: SessionsSnapshot, recorded: Date?) -> Int {
            Upkeep.run(
                context: t.context, snapshot: snapshot, openLeases: [], leaseMinutes: 10,
                keepDays: 35, now: moved, recorded: recorded)
        }
        // Past the lease and past `keepDays` by the clock, recent by what the tool recorded.
        #expect(run(.empty, recorded: now) == 0)
        #expect(run(.unreadable, recorded: now) == 0)
        #expect(exists(file))
        // A clock that moved back is used as it is.
        #expect(Upkeep.judgedAt(now: now, recorded: moved) == now)
        // With nothing recorded, the clock alone judges, as before.
        #expect(run(.unreadable, recorded: nil) == 1)
        #expect(!exists(file))
    }

    @Test func theNewestRecordedTimeComesFromTheLeasesAndReadingsNeverFromAFileTime() throws {
        let (t, config) = try home([main()])
        #expect(Upkeep.newestRecorded(context: t.context, labels: ["main"]) == nil)
        let picked = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 600)
        try LeaseStore(context: t.context).save([
            Lease(id: "l-00000001", label: "main", model: "default", at: picked)
        ])
        #expect(Upkeep.newestRecorded(context: t.context, labels: ["main"]) == picked)

        // A time set on the lease file, as `touch` sets one, does not count.
        let leases = t.context.dataRoot.appendingPathComponent("state/leases.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(86_400)], ofItemAtPath: leases.path)
        #expect(Upkeep.newestRecorded(context: t.context, labels: ["main"]) == picked)

        // A newer stored reading does.
        let account = try #require(config.account("main"))
        _ = Refresher(context: t.context, config: config).refresh(account: account, force: true)
        let read = try #require(try ReadingStore(context: t.context).load(label: "main")).readAt
        #expect(read > picked)
        #expect(Upkeep.newestRecorded(context: t.context, labels: ["main"]) == read)
    }

    @Test func theProbeFolderCleanupKeepsTheFolderOfARunningProbeAfterTheClockMovedForward()
        throws
    {
        let (t, config) = try home([
            main(), Account(label: "pool-a", kind: Kind.token, role: Role.pool),
        ])
        let account = try #require(config.account("main"))
        let pool = try #require(config.account("pool-a"))
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let probes = t.context.dataRoot.appendingPathComponent("probe")
        func folders() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: probes.path)) ?? []).sorted()
        }
        // A first probe records a reading, a time of the tool's own.
        let first = Refresher(context: t.context, config: config).refresh(
            account: account, force: true)
        guard case .probed = first.status else {
            Issue.record("expected a probe, got \(first.status)")
            return
        }

        // The probe of pool-a holds in the fake while it runs in its folder.
        try t.fake("hold-pool-a", "")
        defer { try? t.fake("go-pool-a", "") }
        let ended = Ended()
        let context = t.context
        Thread {
            ended.set(
                Refresher(context: context, config: config).refresh(account: pool, force: true))
        }.start()
        let mark = t.home.appendingPathComponent(".ab-fake/held-pool-a")
        #expect(wait { exists(mark) })
        let running = try #require(folders().first)
        #expect(folders().count == 1)

        // What the tool recorded and the running probe's folder sit an hour behind the clock, as
        // after the clock moved an hour forward.
        let back = Date().addingTimeInterval(-3_600)
        let store = ReadingStore(context: t.context)
        var reading = try #require(try store.load(label: "main"))
        reading.readAt = back
        try store.save(reading, label: "main")
        try FileManager.default.setAttributes(
            [.modificationDate: back.addingTimeInterval(10)],
            ofItemAtPath: probes.appendingPathComponent(running).path)

        // Another probe starts, and its cleanup leaves the running probe's folder.
        let second = Refresher(context: t.context, config: config).refresh(
            account: account, force: true)
        guard case .probed = second.status else {
            Issue.record("expected a probe, got \(second.status)")
            return
        }
        #expect(folders().contains(running))

        // That probe recorded a time past the move, so the folder is old by it too: the lock the
        // running probe holds keeps it from the next probe's cleanup and from the login check's.
        let third = Refresher(context: t.context, config: config).refresh(
            account: account, force: true)
        guard case .probed = third.status else {
            Issue.record("expected a probe, got \(third.status)")
            return
        }
        #expect(folders().contains(running))
        try NoFollowWriter(root: t.context.dataRoot).require(
            Refresher(context: t.context, config: config).checkPlan(account: account))
        #expect(folders().contains(running))

        try t.fake("go-pool-a", "")
        let held = ended.get(within: 120)
        guard case .probed = held?.status else {
            Issue.record("expected the held probe to read, got \(String(describing: held))")
            return
        }
        #expect(!folders().contains(running))
    }

    @Test func aFolderWhoseProbeEndedAgesOutAtTheNewestRecordedTimeInBothCleanups() throws {
        let (t, config) = try home([main()])
        let account = try #require(config.account("main"))
        let first = Refresher(context: t.context, config: config).refresh(
            account: account, force: true)
        guard case .probed = first.status else {
            Issue.record("expected a probe, got \(first.status)")
            return
        }
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let probes = t.context.dataRoot.appendingPathComponent("probe")
        // A probe that ended without removing its folder: its lock went with it.
        func left(_ modified: Date) throws -> URL {
            let made = try writer.makeLockedScratchFolder(
                parent: Layout.probeFolders, prefix: Layout.probeFolderPrefix, staleAfter: 3_600)
            made.lock.release()
            let folder = probes.appendingPathComponent(made.name)
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: folder.path)
            return folder
        }
        // What the tool recorded sits an hour behind the clock.
        let back = Date().addingTimeInterval(-3_600)
        let store = ReadingStore(context: t.context)
        var reading = try #require(try store.load(label: "main"))
        reading.readAt = back
        try store.save(reading, label: "main")
        func check() throws {
            try writer.require(
                Refresher(context: t.context, config: config).checkPlan(account: account))
        }

        // Young by that time, though an hour old by the clock: the login check keeps it.
        let young = try left(back.addingTimeInterval(10))
        try check()
        #expect(exists(young))
        // Old by that time too, it goes in the login check and in a probe's cleanup.
        try FileManager.default.setAttributes(
            [.modificationDate: back.addingTimeInterval(-3_600)], ofItemAtPath: young.path)
        try check()
        #expect(!exists(young))
        let old = try left(back.addingTimeInterval(-3_600))
        let probed = Refresher(context: t.context, config: config).refresh(
            account: account, force: true)
        guard case .probed = probed.status else {
            Issue.record("expected a probe, got \(probed.status)")
            return
        }
        #expect(!exists(old))
    }

    @Test func upkeepHoldsTheFileOfALeaseOpenAtTheJudgedTime() throws {
        let t = try TestHome()
        let now = Date()
        let recorded = now.addingTimeInterval(-3_600)
        try LeaseStore(context: t.context).save([
            Lease(
                id: "l-00000002", label: "pool-a", model: "default",
                at: recorded.addingTimeInterval(-300))
        ])
        let file = try LaunchFiles.fileURL(
            context: t.context, label: "pool-a", leaseId: "l-00000002")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: file.path)
        // The lease ended by the clock, but not at the time the pass judges by, so it holds the
        // file, whose own time is past the lease either way.
        let removed = Upkeep.run(
            context: t.context, snapshot: .empty, openLeases: [], leaseMinutes: 10,
            keepDays: 35, now: now, recorded: recorded)
        #expect(removed == 0)
        #expect(exists(file))
    }
}

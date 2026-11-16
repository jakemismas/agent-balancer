import Foundation
import Testing

@testable import Core

/// A pick's own probe that outlasts the pick's deadline, with every order forced by holding the
/// probe, the pick lock and a sign-in check: a Fable probe still running when the pick answers is
/// not counted as tried, and a probe that finds the sign-in rejected before the pick decides, or a
/// rejection another command records then, keeps the account out and reaches its probe record.
@Suite struct PickLateProbeTests {
    let pool = Account(label: "pool-a", kind: Kind.token, role: Role.pool)

    /// A home whose one token account has a fresh plain reading and a Fable probe due, which the
    /// fake `claude` answers from `fableFixture`. A pick waits two seconds for its probes, long
    /// enough for a held probe to begin, and no probe timeout ends a held one.
    func setUp(fableFixture: String) throws -> (TestHome, PickService) {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        try t.fakeProbe("ok.jsonl")
        try t.fakeProbe(fableFixture, model: ProbeForm.fableModel)
        var config = Config(accounts: [pool])
        config.fable.probe = true
        // With the whole week as Fable room, only the sign-in can keep the account out.
        config.fable.capPercentOfWeekly = 100
        config.picker.deadlineSeconds = 2
        config.probe.timeoutSeconds = 600
        config.fable.probeTimeoutSeconds = 600
        let context = t.context
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        _ = try t.makeTokenFile(label: pool.label, secret: Canaries.oauth())
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let parsed = ProbeReader.parse(try t.probeFixture("ok.jsonl", now: now), readAt: now)
        guard case .reading(let fresh) = parsed else {
            Issue.record("expected a reading, got \(parsed)")
            throw CancellationError()
        }
        try ReadingStore(context: context).record(
            fresh, label: pool.label, callsHook: false, fable: config.fable, now: now)
        return (t, PickService(context: context))
    }

    /// Sets the pick deadline back to its default, so a pick that is not part of a forced order
    /// waits for its probes as usual.
    func defaultDeadline(_ t: TestHome) throws {
        let store = ConfigStore(context: t.context)
        var config = try store.loadRequired()
        config.picker.deadlineSeconds = Config().picker.deadlineSeconds
        try store.save(config)
    }

    /// Polls `condition` for at most five minutes.
    func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<6000 {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    func held(_ t: TestHome) -> Bool {
        FileManager.default.fileExists(
            atPath: t.home.appendingPathComponent(".ab-fake/held-\(pool.label)").path)
    }

    func fableProbes(_ t: TestHome) -> Int {
        t.fakeLines("models.log").filter { $0 == ProbeForm.fableModel }.count
    }

    func fableTried(_ t: TestHome) -> Date? {
        (try? ReadingStore(context: t.context).load(label: pool.label))?.fableProbedAt
    }

    var pickLock: [String] { Layout.locksFolders + [Layout.pickLockName] }

    /// The change time of the pick lock's file. Taking a lock sets its file's mode, which stamps
    /// that time, so a new value shows that a pick has come to its lock.
    func pickLockChanged(_ t: TestHome) -> timespec? {
        let path = pickLock.reduce(t.context.dataRoot) { $0.appendingPathComponent($1) }.path
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_ctimespec
    }

    /// True once the pick lock's change time differs from `taken`.
    func cameToItsLock(_ t: TestHome, since taken: timespec) -> Bool {
        guard let now = pickLockChanged(t) else { return false }
        return now.tv_sec != taken.tv_sec || now.tv_nsec != taken.tv_nsec
    }

    /// The pick lock, held by the test, with its change time once taken.
    func holdPickLock(_ t: TestHome) throws -> (FileLock, timespec) {
        let lock = try #require(
            try NoFollowWriter(root: t.context.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 0))
        return (lock, try #require(pickLockChanged(t)))
    }

    /// Adds the login account `main` with a fresh reading past the line and its Fable probe done,
    /// so a pick runs no probe of it and cannot take it, but checks its sign-in again under the
    /// pick lock.
    func addLimitedMain(_ t: TestHome) throws {
        let main = Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
        let store = ConfigStore(context: t.context)
        var config = try store.loadRequired()
        config.accounts.insert(main, at: 0)
        try store.save(config)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var reading = Reading(
            readAt: now,
            windows: [
                WindowName.sevenDay: WindowReading(
                    usedPercent: 99, resetsAt: now.addingTimeInterval(3 * 86_400), readAt: now),
                WindowName.fiveHour: WindowReading(
                    usedPercent: 10, resetsAt: now.addingTimeInterval(3_600), readAt: now),
            ])
        reading.fableProbedAt = now
        try ReadingStore(context: t.context).save(reading, label: main.label)
    }

    func fakeMarker(_ t: TestHome, _ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: t.home.appendingPathComponent(".ab-fake/\(name)").path)
    }

    @Test func aFableProbeStillRunningWhenItsPickAnswersIsNotCountedAndRunsAgain() throws {
        let (t, service) = try setUp(fableFixture: "auth_error.jsonl")
        try t.fake("hold-\(pool.label)", "")
        defer { try? t.fake("go-\(pool.label)", "") }
        let answered = try service.pick(PickRequest(model: "fable", caller: .launcher))
        // The pick answered on the fresh plain reading while its Fable probe was held.
        #expect(waitUntil { held(t) })
        #expect(answered.label == pool.label)
        #expect(fableProbes(t) == 1)
        // The probe ends after the pick answered. Once the account's lock is free, it is done.
        try t.fake("go-\(pool.label)", "")
        let free = try #require(
            try NoFollowWriter(root: t.context.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: Layout.lockName(pool.label), wait: 300))
        free.release()
        #expect(fableTried(t) == nil)
        #expect(!StatusBuilder.probeFoundSignInRejected(context: t.context, account: pool))
        // So the next Fable pick runs it again, and that one finds the token rejected.
        try defaultDeadline(t)
        let next = try service.pick(PickRequest(model: "fable", caller: .launcher))
        #expect(fableProbes(t) == 2)
        #expect(next.label == nil)
        #expect(next.candidates.first?.reason == "login rejected")
        #expect(fableTried(t) != nil)
    }

    @Test(arguments: [false, true])
    func aPicksOwnFableProbeRejectedWhileItWaitsForThePickLockKeepsTheTokenOut(busy: Bool)
        throws
    {
        let (t, base) = try setUp(fableFixture: "auth_error.jsonl")
        var service = base
        // A pick that ends busy gives up after its own wait, ten seconds here, well after the test
        // lets its probe go; the other waits as long as the test.
        service.lockWaitSeconds = busy ? 10 : 300
        try t.fake("hold-\(pool.label)", "")
        defer { try? t.fake("go-\(pool.label)", "") }
        let lock = try #require(
            try NoFollowWriter(root: t.context.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 0))
        var holding = true
        defer { if holding { lock.release() } }
        let taken = try #require(pickLockChanged(t))
        let pick = PickInBackground(service, PickRequest(model: "fable", caller: .launcher))
        try #require(waitUntil { held(t) })
        // The pick has come to its lock, so its Fable probe, still held, outlasted the deadline.
        try #require(
            waitUntil {
                guard let now = pickLockChanged(t) else { return false }
                return now.tv_sec != taken.tv_sec || now.tv_nsec != taken.tv_nsec
            })
        #expect(!pick.hasEnded)
        // The probe ends with an auth error while the pick waits; its time is noted once it is heard.
        try t.fake("go-\(pool.label)", "")
        try #require(waitUntil { fableTried(t) != nil })
        if !busy {
            lock.release()
            holding = false
        }
        let outcome = try #require(pick.wait())
        if busy {
            #expect(throws: ToolError.self) { try outcome.get() }
            lock.release()
            holding = false
        } else {
            let answer = try outcome.get()
            #expect(answer.label == nil)
            let candidate = try #require(answer.candidates.first { $0.label == pool.label })
            #expect(candidate.eligible == false)
            #expect(candidate.reason == "login rejected")
        }
        // Either way the rejection is recorded, so the next pick skips the token before any probe.
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: pool))
        let probes = t.fakeLines("models.log").count
        try defaultDeadline(t)
        let next = try PickService(context: t.context).pick(PickRequest(caller: .launcher))
        #expect(next.label == nil)
        #expect(next.candidates.first?.reason == "login rejected")
        #expect(t.fakeLines("models.log").count == probes)
    }

    @Test func aPicksOwnFableProbeRejectedWhileItRechecksASignInKeepsTheTokenOut() throws {
        let (t, base) = try setUp(fableFixture: "auth_error.jsonl")
        try addLimitedMain(t)
        var service = base
        service.lockWaitSeconds = 300
        try t.fake("hold-\(pool.label)", "")
        defer { try? t.fake("go-\(pool.label)", "") }
        defer { try? t.fake("go-auth", "") }
        let (lock, taken) = try holdPickLock(t)
        var holding = true
        defer { if holding { lock.release() } }
        let pick = PickInBackground(service, PickRequest(model: "fable", caller: .launcher))
        try #require(waitUntil { held(t) })
        try #require(waitUntil { cameToItsLock(t, since: taken) })
        // Once the pick has its lock, its check of main's sign-in is held.
        try t.fake("hold-auth", "")
        lock.release()
        holding = false
        try #require(waitUntil { fakeMarker(t, "held-auth") })
        // The Fable probe ends with an auth error during that check, and the pick hears it.
        try t.fake("go-\(pool.label)", "")
        try #require(waitUntil { fableTried(t) != nil })
        #expect(!pick.hasEnded)
        try t.fake("go-auth", "")
        let answer = try #require(pick.wait()).get()
        #expect(answer.label == nil)
        let candidate = try #require(answer.candidates.first { $0.label == pool.label })
        #expect(candidate.eligible == false)
        #expect(candidate.reason == "login rejected")
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: pool))
    }

    @Test func aRejectionRecordedWhileThePickRechecksASignInKeepsTheTokenOut() throws {
        let (t, base) = try setUp(fableFixture: "fable.jsonl")
        try addLimitedMain(t)
        var service = base
        service.lockWaitSeconds = 300
        defer { try? t.fake("go-auth", "") }
        let (lock, taken) = try holdPickLock(t)
        var holding = true
        defer { if holding { lock.release() } }
        let pick = PickInBackground(service, PickRequest(caller: .launcher))
        try #require(waitUntil { cameToItsLock(t, since: taken) })
        try t.fake("hold-auth", "")
        lock.release()
        holding = false
        try #require(waitUntil { fakeMarker(t, "held-auth") })
        // Another command's rebuild records a probe's rejection of the token during that check.
        let rejected = ProbeObservation(
            error: Core.Issue(.loginRejected, .error, Messages.probeLoginRejected))
        StatusBuilder.rebuildQuietly(
            context: t.context, observations: StatusObservations(probe: [pool.label: rejected]))
        try #require(StatusBuilder.probeFoundSignInRejected(context: t.context, account: pool))
        #expect(!pick.hasEnded)
        try t.fake("go-auth", "")
        let answer = try #require(pick.wait()).get()
        #expect(answer.label == nil)
        let candidate = try #require(answer.candidates.first { $0.label == pool.label })
        #expect(candidate.eligible == false)
        #expect(candidate.reason == "login rejected")
    }

    @Test func aPicksOwnPlainProbeRejectedAfterItsDeadlineKeepsTheTokenOutAndIsRecorded() throws {
        let (t, base) = try setUp(fableFixture: "fable.jsonl")
        // An hour old, so a pick runs the plain probe; the token's probe is rejected.
        let store = ReadingStore(context: t.context)
        var old = try #require(try store.load(label: pool.label))
        old.readAt = old.readAt.addingTimeInterval(-3600)
        try store.save(old, label: pool.label)
        try t.fakeProbe("auth_error.jsonl")
        var service = base
        service.lockWaitSeconds = 300
        try t.fake("hold-\(pool.label)", "")
        defer { try? t.fake("go-\(pool.label)", "") }
        let (lock, taken) = try holdPickLock(t)
        var holding = true
        defer { if holding { lock.release() } }
        let pick = PickInBackground(service, PickRequest(caller: .launcher))
        try #require(waitUntil { held(t) })
        // The pick has come to its lock, so its plain probe, still held, outlasted the deadline.
        try #require(waitUntil { cameToItsLock(t, since: taken) })
        #expect(!pick.hasEnded)
        try t.fake("go-\(pool.label)", "")
        // A probe's result is heard before the account's probe lock is let go.
        let probeLock = try #require(
            try NoFollowWriter(root: t.context.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: Layout.lockName(pool.label), wait: 300))
        probeLock.release()
        lock.release()
        holding = false
        let answer = try #require(pick.wait()).get()
        #expect(answer.label == nil)
        let candidate = try #require(answer.candidates.first { $0.label == pool.label })
        #expect(candidate.eligible == false)
        #expect(candidate.reason == "login rejected")
        // The rejection is recorded, so the next pick skips the token before any probe, and
        // `run` refuses it.
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: pool))
        let probes = t.fakeLines("models.log").count
        try defaultDeadline(t)
        let next = try PickService(context: t.context).pick(PickRequest(caller: .launcher))
        #expect(next.label == nil)
        #expect(next.candidates.first?.reason == "login rejected")
        #expect(t.fakeLines("models.log").count == probes)
        _ = try HookRecord(context: t.context).readSettings()
        #expect(throws: ToolError(Messages.probeLoginRejected, code: .loginRejected)) {
            try PickService(context: t.context).prepareRun(label: pool.label, arguments: [])
        }
    }
}

/// A pick run on a thread of its own, so the test can act while it waits for the pick lock.
private final class PickInBackground: @unchecked Sendable {
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private var outcome: Result<PickResult, Error>?

    init(_ service: PickService, _ request: PickRequest) {
        let thread = Thread { [self] in
            let result = Result { try service.pick(request) }
            lock.lock()
            outcome = result
            lock.unlock()
            ended.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    var hasEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome != nil
    }

    /// The pick's outcome once it has ended, or nil when it still runs after five minutes.
    func wait() -> Result<PickResult, Error>? {
        guard ended.wait(timeout: .now() + 300) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

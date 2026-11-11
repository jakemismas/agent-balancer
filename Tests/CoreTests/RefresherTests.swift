import Foundation
import Testing

@testable import Core

@Suite struct RefresherTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    func login() -> Account {
        Account(label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com")
    }

    func token(_ label: String) -> Account {
        Account(label: label, kind: Kind.token, role: Role.pool)
    }

    func refresher(
        _ t: TestHome, accounts: [Account], clock: ClockBox, hook: HookCalls? = nil,
        tune: (inout Config) -> Void = { _ in }
    ) -> Refresher {
        var config = Config(accounts: accounts)
        tune(&config)
        var store = ReadingStore(context: t.context)
        if let hook { store.afterProbe = { label, _ in hook.add(label) } }
        var r = Refresher(context: t.context, config: config, store: store)
        r.clock = { clock.now }
        r.lockWaitSeconds = 0.3
        return r
    }

    func setUp(probe: String = "ok.jsonl") throws -> TestHome {
        let t = try TestHome()
        try t.installFake()
        try t.fakeProbe(probe, now: Self.start)
        return t
    }

    @Test func theProbeRunsExactlyTheDocumentedFlagsFromAFreshFolder() throws {
        let t = try setUp()
        let clock = ClockBox(Self.start)
        var config = Config(accounts: [login()])
        config.fable.probe = false
        var r = Refresher(context: t.context, config: config)
        r.clock = { Self.start }
        let result = r.refresh(account: login(), force: false)
        guard case .probed = result.status else {
            Issue.record("expected a probe, got \(result.status)")
            return
        }
        _ = clock
        let line = try #require(t.fakeLines("args.log").first { $0.hasPrefix("-p") })
        #expect(
            line
                == "-p Reply with the single word OK. --model haiku --tools  --disallowedTools "
                + "mcp__* --strict-mcp-config --max-turns 1 --no-session-persistence "
                + "--max-budget-usd 0.05 --output-format stream-json --verbose --safe-mode")
        #expect(!line.contains("--bare"))
        let cwd = try #require(t.fakeLines("cwd.log").first)
        #expect(cwd.contains("/.agent-balancer/probe/p-"))
        #expect(!FileManager.default.fileExists(atPath: cwd))
        #expect(t.fakeLines("cwd-mode.log").first == "700")
        #expect(
            t.fakeRecord("config-dir.txt").trimmingCharacters(in: .whitespacesAndNewlines)
                == "unset")
        let probeFolder = t.context.dataRoot.appendingPathComponent("probe").path
        #expect(try FileManager.default.contentsOfDirectory(atPath: probeFolder).isEmpty)
    }

    @Test func safeModeIsAddedOnlyWhenTheConfigSaysSo() throws {
        let t = try setUp()
        var config = Config(accounts: [login()])
        config.fable.probe = false
        config.probe.safeMode = false
        _ = Refresher(context: t.context, config: config).refresh(account: login(), force: false)
        let line = try #require(t.fakeLines("args.log").first { $0.hasPrefix("-p") })
        #expect(!line.contains("--safe-mode"))
    }

    @Test func anUnknownOptionIsCheckFailedWithScrubbedText() throws {
        let t = try setUp()
        try t.fake("unknown-option", "1")
        try t.fake("stderr.txt", "error: unknown option '--safe-mode'\n")
        var config = Config(accounts: [login()])
        config.fable.probe = false
        let result = Refresher(context: t.context, config: config)
            .refresh(account: login(), force: false)
        guard case .failed(let issue) = result.status else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .checkFailed)
        #expect(issue.text.contains("unknown option"))
        #expect(try ReadingStore(context: t.context).load(label: "main") == nil)
    }

    @Test func aTokenProbeAddsOneSettingsPathAndNothingElse() throws {
        let t = try setUp()
        let secret = Canaries.oauth()
        let file = try t.makeTokenFile(label: "pool-a", secret: secret)
        let hook = HookCalls()
        let r = refresher(
            t, accounts: [token("pool-a")], clock: ClockBox(Self.start), hook: hook
        ) { $0.fable.probe = false }
        let result = r.refresh(account: token("pool-a"), force: false)
        guard case .probed = result.status else {
            Issue.record("expected a probe, got \(result.status)")
            return
        }
        let line = try #require(t.fakeLines("args.log").first { $0.hasPrefix("-p") })
        #expect(line.components(separatedBy: "--settings").count == 2)
        #expect(line.hasSuffix("--settings " + file.path))
        #expect(!line.contains(secret))
        #expect(
            t.fakeRecord("config-dir.txt").trimmingCharacters(in: .whitespacesAndNewlines)
                == "unset")
        let names = t.fakeRecord("env-names.txt")
        #expect(!names.contains(ProtectedEnv.tokenVariable))
        #expect(!names.contains("ANTHROPIC"))
        #expect(!names.contains("CLAUDE_CONFIG_DIR"))
        #expect(hook.labels == ["pool-a"])
        #expect(!t.allText(skipping: file).contains(secret))
    }

    @Test func theAfterProbeHookRunsTheDuplicateCheckOnEveryTokenProbe() throws {
        let t = try setUp()
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        _ = try t.makeTokenFile(label: "pool-b", secret: Canaries.oauth())
        let accounts = [token("pool-a"), token("pool-b"), login()]
        let hook = HookCalls()
        let r = refresher(t, accounts: accounts, clock: ClockBox(Self.start), hook: hook) {
            $0.fable.probe = false
        }
        // pool-b has no reading yet, so the first probe finds no match.
        let first = r.refresh(account: token("pool-a"), force: true)
        #expect(first.duplicate == .clear)
        // The same stream answers pool-b, so both reset times equal pool-a's.
        let second = r.refresh(account: token("pool-b"), force: true)
        #expect(second.duplicate == .sameAs("pool-a"))
        #expect(second.duplicate.issue?.code == .possibleDuplicate)
        #expect(second.duplicate.issue?.severity == .warning)
        // A hook the caller set still runs, once per probe.
        #expect(hook.labels == ["pool-a", "pool-b"])

        // A reading that is fresh runs no probe, and a login account never runs the check.
        #expect(r.refresh(account: token("pool-b"), force: false).duplicate == .notRun)
        #expect(r.refresh(account: login(), force: true).duplicate == .notRun)

        // Other reset times on the next probe clear it. The stored reading goes first, so the
        // merge reads the probe as new.
        try t.fakeProbe("ok.jsonl", now: Self.start.addingTimeInterval(600))
        try ReadingStore(context: t.context).delete(label: "pool-b")
        #expect(r.refresh(account: token("pool-b"), force: true).duplicate == .clear)
    }

    @Test func theHookIsNotCalledForALoginAccount() throws {
        let t = try setUp()
        let hook = HookCalls()
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start), hook: hook) {
            $0.fable.probe = false
        }
        _ = r.refresh(account: login(), force: false)
        #expect(hook.labels.isEmpty)
    }

    @Test func aTokenAccountWithoutAFileIsTokenMissing() throws {
        let t = try setUp()
        let r = refresher(t, accounts: [token("pool-a")], clock: ClockBox(Self.start))
        let result = r.refresh(account: token("pool-a"), force: false)
        guard case .failed(let issue) = result.status else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .tokenMissing)
        #expect(t.fakeLines("args.log").isEmpty)
    }

    @Test func anAuthErrorIsLoginRejectedAndStoresNothing() throws {
        let t = try setUp(probe: "auth_error.jsonl")
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start))
        guard case .failed(let issue) = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .loginRejected)
        #expect(try ReadingStore(context: t.context).load(label: "main") == nil)
    }

    @Test func aFableProbeRunsOncePerDayWithItsOwnBudgetAndModel() throws {
        let t = try setUp()
        try t.fakeProbe("fable.jsonl", model: ProbeForm.fableModel, now: Self.start)
        let clock = ClockBox(Self.start)
        let r = refresher(t, accounts: [login()], clock: clock)

        let first = r.refresh(account: login(), force: false)
        #expect(first.fable == .probed)
        let models = t.fakeLines("models.log")
        #expect(models == ["haiku", ProbeForm.fableModel])
        let fableLine = try #require(
            t.fakeLines("args.log").last { $0.hasPrefix("-p") })
        #expect(fableLine.contains("--max-budget-usd 0.50"))
        let stored = try #require(try ReadingStore(context: t.context).load(label: "main"))
        #expect(stored.fable?.source == "probe")
        #expect(stored.fable?.usedPercent == 31.0)

        clock.advance(60)
        let forced = r.refresh(account: login(), force: true)
        #expect(forced.fable == .notRun)
        #expect(t.fakeLines("models.log") == ["haiku", ProbeForm.fableModel, "haiku"])

        clock.advance(24 * 3600)
        try t.fakeProbe("ok.jsonl", now: clock.now)
        try t.fakeProbe("fable.jsonl", model: ProbeForm.fableModel, now: clock.now)
        let next = r.refresh(account: login(), force: false)
        #expect(next.fable == .probed)
        #expect(t.fakeLines("models.log").suffix(2) == ["haiku", ProbeForm.fableModel])
    }

    @Test func noFableProbeRunsWhenTheSwitchIsFalseAndTheEstimateStands() throws {
        let t = try setUp()
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        let result = r.refresh(account: login(), force: false)
        #expect(result.fable == .notRun)
        #expect(t.fakeLines("models.log") == ["haiku"])
        let stored = try #require(try ReadingStore(context: t.context).load(label: "main"))
        #expect(stored.fable?.source == "estimate")
        #expect(stored.fable?.guaranteedRoomPercentOfCap == 8.8)
    }

    @Test func aFailedFableProbeKeepsTheEstimateAndStillCountsForTheDay() throws {
        let t = try setUp()
        try t.fake("probe-\(ProbeForm.fableModel).jsonl", "not stream json\n")
        let clock = ClockBox(Self.start)
        let r = refresher(t, accounts: [login()], clock: clock)
        let first = r.refresh(account: login(), force: false)
        guard case .failed = first.fable else {
            Issue.record("expected a Fable failure")
            return
        }
        let stored = try #require(try ReadingStore(context: t.context).load(label: "main"))
        #expect(stored.fable?.source == "estimate")
        clock.advance(3600)
        _ = r.refresh(account: login(), force: true)
        #expect(t.fakeLines("models.log") == ["haiku", ProbeForm.fableModel, "haiku"])
    }

    @Test func aFreshReadingSkipsTheProbeUnlessForced() throws {
        let t = try setUp()
        let clock = ClockBox(Self.start)
        let r = refresher(t, accounts: [login()], clock: clock) { $0.fable.probe = false }
        _ = r.refresh(account: login(), force: false)
        clock.advance(14 * 60)
        guard case .fresh = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a skip")
            return
        }
        #expect(t.fakeLines("models.log").count == 1)
        guard case .probed = r.refresh(account: login(), force: true).status else {
            Issue.record("expected a probe")
            return
        }
        #expect(t.fakeLines("models.log").count == 2)
        clock.advance(16 * 60)
        guard case .probed = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a probe after the age limit")
            return
        }
        #expect(t.fakeLines("models.log").count == 3)
    }

    @Test func theAgeLimitComesFromConfig() throws {
        let t = try setUp()
        let clock = ClockBox(Self.start)
        let r = refresher(t, accounts: [login()], clock: clock) {
            $0.fable.probe = false
            $0.picker.maxReadingAgeMinutes = 2
        }
        _ = r.refresh(account: login(), force: false)
        clock.advance(3 * 60)
        guard case .probed = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a probe")
            return
        }
    }

    @Test func aHeldLockMakesTheCallerUseTheStoredReading() throws {
        let t = try setUp()
        let clock = ClockBox(Self.start)
        let r = refresher(t, accounts: [login()], clock: clock) { $0.fable.probe = false }
        _ = r.refresh(account: login(), force: false)
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.lockName("main"), wait: 1))
        defer { held.release() }
        clock.advance(3600)
        let started = Date()
        let result = r.refresh(account: login(), force: false)
        guard case .usedStored(let reading) = result.status else {
            Issue.record("expected the stored reading, got \(result.status)")
            return
        }
        #expect(reading.sevenDay?.usedPercent == 45.6)
        #expect(Date().timeIntervalSince(started) >= 0.25)
        #expect(t.fakeLines("models.log").count == 1)
    }

    @Test func aHeldLockWithNothingStoredFails() throws {
        let t = try setUp()
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start))
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.lockName("main"), wait: 1))
        defer { held.release() }
        guard case .failed(let issue) = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .checkFailed)
    }

    @Test func twoAccountsAreProbedAtTheSameTime() throws {
        let t = try setUp()
        try t.fake("delay", "1")
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        _ = try t.makeTokenFile(label: "pool-b", secret: Canaries.oauth())
        let accounts = [token("pool-a"), token("pool-b")]
        let r = refresher(t, accounts: accounts, clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        let started = Date()
        let results = r.refresh(accounts: accounts, force: false)
        let elapsed = Date().timeIntervalSince(started)
        #expect(results.map(\.label) == ["pool-a", "pool-b"])
        #expect(results.allSatisfy { if case .probed = $0.status { true } else { false } })
        #expect(elapsed < 1.9)
        #expect(t.fakeLines("models.log").count == 2)
    }

    @Test func aStrayEntryInTheProbeFolderRefusesTheProbe() throws {
        let t = try setUp()
        let probe = t.context.dataRoot.appendingPathComponent("probe")
        try FileManager.default.createDirectory(
            at: probe, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "x".write(
            to: probe.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start))
        guard case .failed(let issue) = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a refusal")
            return
        }
        #expect(issue.code == .checkFailed)
        #expect(t.fakeLines("models.log").isEmpty)
    }

    @Test func anOldProbeFolderIsRemovedAndANewOneIsKept() throws {
        let t = try setUp()
        let probe = t.context.dataRoot.appendingPathComponent("probe")
        try FileManager.default.createDirectory(
            at: probe, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let old = probe.appendingPathComponent("p-" + String(repeating: "a", count: 16))
        let young = probe.appendingPathComponent("p-" + String(repeating: "b", count: 16))
        for url in [old, young] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "x".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        guard case .probed = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a probe")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: young.path))
    }

    @Test func aMissingEventIsCheckFailed() throws {
        let t = try setUp(probe: "no_event.jsonl")
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start))
        guard case .failed(let issue) = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .checkFailed)
    }

    @Test func aSymlinkInPlaceOfTheLockFileIsRefused() throws {
        let t = try setUp()
        let locks = t.context.dataRoot.appendingPathComponent("locks")
        try FileManager.default.createDirectory(
            at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = t.home.appendingPathComponent("elsewhere")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: locks.appendingPathComponent("probe-main.lock"), withDestinationURL: target)
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start))
        guard case .failed = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a refusal")
            return
        }
        #expect(t.fakeLines("models.log").isEmpty)
    }

    @Test func aFarFutureStoredResetDoesNotBlockTheNextGoodProbe() throws {
        let t = try setUp()
        let store = ReadingStore(context: t.context)
        let pinned = Reading(
            readAt: Self.start.addingTimeInterval(-3600),
            windows: [
                WindowName.fiveHour: WindowReading(
                    usedPercent: 99, resetsAt: Date(timeIntervalSince1970: 9_000_000_000),
                    readAt: Self.start.addingTimeInterval(-3600))
            ])
        try store.save(pinned, label: "main")
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        guard case .probed(let reading) = r.refresh(account: login(), force: true).status else {
            Issue.record("expected a probe")
            return
        }
        #expect(reading.fiveHour?.usedPercent == 12.3)
        #expect(try store.load(label: "main")?.fiveHour?.usedPercent == 12.3)
    }

    @Test func aStoredFileThatDoesNotDecodeIsReplacedByTheNextGoodProbe() throws {
        let t = try setUp()
        let store = ReadingStore(context: t.context)
        try store.save(
            Reading(
                readAt: Self.start.addingTimeInterval(-3600),
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 10, resetsAt: nil, readAt: Self.start)
                ]), label: "main")
        let url = t.context.dataRoot.appendingPathComponent("state/readings/main.json")
        try Data("{ not json".utf8).write(to: url)
        #expect(try store.load(label: "main") == nil)
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        guard case .probed = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a probe")
            return
        }
        #expect(try store.load(label: "main")?.sevenDay?.usedPercent == 45.6)
    }

    @Test func aFableProbeTimeAheadOfTheClockStillLetsTheProbeRun() throws {
        let t = try setUp()
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start))
        var stored = Reading(readAt: Self.start)
        stored.fableProbedAt = Self.start.addingTimeInterval(30 * 86_400)
        #expect(r.fableDue(stored, now: Self.start))
        stored.fableProbedAt = Self.start.addingTimeInterval(30)
        #expect(!r.fableDue(stored, now: Self.start))
    }
}

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
        // The fake writes each probe's start and end in the order they happen: the two probes
        // overlap when each one started before the other ended.
        let order = t.fakeLines("spans.log")
        let startA = try #require(order.firstIndex(of: "start pool-a"))
        let endA = try #require(order.firstIndex(of: "end pool-a"))
        let startB = try #require(order.firstIndex(of: "start pool-b"))
        let endB = try #require(order.firstIndex(of: "end pool-b"))
        #expect(startA < endB && startB < endA)
    }

    /// The probes' start and end records from the fake, in the order they happened.
    func spans(_ t: TestHome) -> [(event: String, name: String)] {
        t.fakeLines("spans.log").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// The most probes that were running at one time.
    func mostAtOnce(_ t: TestHome) -> Int {
        var running = 0
        var most = 0
        for span in spans(t) {
            running += span.event == "start" ? 1 : -1
            most = max(most, running)
        }
        return most
    }

    func manyTokenAccounts(_ t: TestHome) throws -> [Account] {
        let accounts = (0..<(Refresher.maxProbesAtOnce + 2)).map { token("pool-\($0)") }
        for account in accounts {
            _ = try t.makeTokenFile(label: account.label, secret: Canaries.oauth())
        }
        return accounts
    }

    @Test func moreAccountsThanTheCapAreAllProbedWithNoMoreThanTheCapAtOnce() throws {
        let t = try setUp()
        try t.fake("delay", "1")
        let accounts = try manyTokenAccounts(t)
        let r = refresher(t, accounts: accounts, clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        let results = r.refresh(accounts: accounts, force: false)
        #expect(results.map(\.label) == accounts.map(\.label))
        #expect(results.allSatisfy { if case .probed = $0.status { true } else { false } })
        let started = spans(t).filter { $0.event == "start" }.map(\.name)
        #expect(started.sorted() == accounts.map(\.label).sorted())
        // The cap section 6.4 states, and every slot in use while enough accounts wait.
        #expect(Refresher.maxProbesAtOnce == 8)
        #expect(mostAtOnce(t) == 8)
    }

    @Test func anAccountWhoseProbeHasNotBegunAtTheDeadlineIsNotStartedAndNothingIsObserved()
        throws
    {
        let t = try setUp()
        try t.fake("delay", "2")
        let accounts = try manyTokenAccounts(t)
        var r = refresher(t, accounts: accounts, clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        // The refresh starts at the third account, whose lock another probe holds past the
        // deadline; the two before it wait for a thread.
        r.firstAccount = { _ in 2 }
        r.lockWaitSeconds = 3
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.lockName("pool-2"), wait: 1))
        defer { held.release() }
        let results = r.refresh(accounts: accounts, force: false, deadline: 1)
        // The lock frees after the deadline while that account's thread still waits for it.
        held.release()
        let names = accounts.map(\.label)
        let probed = Array(names[3...])
        #expect(results.filter { $0.status == .notStarted }.map(\.label) == Array(names[0...2]))
        #expect(results.filter(\.failed).map(\.label) == probed)
        var observations = StatusObservations()
        observations.add(results)
        #expect(observations.probe.keys.sorted() == probed.sorted())
        // Let every probe that began end: none began after the deadline.
        let until = Date().addingTimeInterval(20)
        while Date() < until {
            let records = spans(t)
            let starts = records.filter { $0.event == "start" }.count
            if starts >= probed.count && records.count == 2 * starts { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.5)
        let started = Set(spans(t).filter { $0.event == "start" }.map(\.name))
        #expect(started == Set(probed))
    }

    @Test func anAccountStillWaitingForASlotAtTheDeadlineIsNotTouchedAfterIt() throws {
        let t = try setUp()
        try t.fake("delay", "2")
        let accounts = try manyTokenAccounts(t)
        var r = refresher(t, accounts: accounts, clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        r.firstAccount = { _ in 0 }
        let results = r.refresh(accounts: accounts, force: false, deadline: 1)
        let waiting = Array(accounts.map(\.label).suffix(2))
        #expect(results.filter { $0.status == .notStarted }.map(\.label) == waiting)
        // Let every probe that began end, then give the threads time to take another account.
        let until = Date().addingTimeInterval(20)
        while Date() < until {
            let records = spans(t)
            let starts = records.filter { $0.event == "start" }.count
            if starts >= Refresher.maxProbesAtOnce && records.count == 2 * starts { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 1)
        // No account is handed out after the deadline, so not even its lock is taken.
        let locks = t.context.dataRoot.appendingPathComponent("locks")
        for label in waiting {
            let lock = locks.appendingPathComponent(Layout.lockName(label))
            #expect(!FileManager.default.fileExists(atPath: lock.path), "\(label)")
        }
        #expect(Set(spans(t).map(\.name)).isDisjoint(with: waiting))
    }

    /// A fresh plain reading whose Fable probe is due, stored for `label`.
    func storeFreshWithFableDue(_ t: TestHome, _ label: String) throws {
        try ReadingStore(context: t.context).save(
            Reading(
                readAt: Self.start,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 10, resetsAt: Self.start.addingTimeInterval(3 * 86_400),
                        readAt: Self.start),
                    WindowName.fiveHour: WindowReading(
                        usedPercent: 5, resetsAt: Self.start.addingTimeInterval(3_600),
                        readAt: Self.start),
                ]), label: label)
    }

    @Test func noFableProbeBeginsAfterTheDeadlineForAnAccountStillWaitingForItsLock() throws {
        let t = try setUp()
        try t.fakeProbe("fable.jsonl", model: ProbeForm.fableModel, now: Self.start)
        let account = login()
        try storeFreshWithFableDue(t, account.label)
        var r = refresher(t, accounts: [account], clock: ClockBox(Self.start))
        r.lockWaitSeconds = 4
        let held = try #require(
            try NoFollowWriter(root: t.context.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: Layout.lockName(account.label), wait: 1))
        defer { held.release() }
        let results = r.refresh(accounts: [account], force: false, fable: .forPick, deadline: 1)
        #expect(results.map(\.status) == [.notStarted])
        // The lock frees after the deadline while the account's thread still waits for it.
        held.release()
        let store = ReadingStore(context: t.context)
        func fableTried() -> Bool {
            t.fakeLines("models.log").contains(ProbeForm.fableModel)
                || (try? store.load(label: account.label))?.fableProbedAt != nil
        }
        let until = Date().addingTimeInterval(2)
        while Date() < until && !fableTried() { Thread.sleep(forTimeInterval: 0.05) }
        #expect(!fableTried())
        #expect(t.fakeLines("models.log").isEmpty)
    }

    @Test(arguments: ["a fresh plain reading", "a plain probe", "a token account's plain probe"])
    func aFableProbeStillRunningAtTheDeadlineLeavesThePlainResultToStand(_ plain: String)
        throws
    {
        let t = try setUp()
        try t.fakeProbe("fable.jsonl", model: ProbeForm.fableModel, now: Self.start)
        try t.fake("delay-\(ProbeForm.fableModel)", "3")
        let plainFresh = plain == "a fresh plain reading"
        let tokenAccount = plain == "a token account's plain probe"
        let account = tokenAccount ? token("pool-a") : login()
        var accounts: [Account] = [account]
        if tokenAccount {
            _ = try t.makeTokenFile(label: account.label, secret: Canaries.oauth())
            // Another account already holds the reset times this account's plain probe reads.
            accounts.append(token("pool-b"))
            let same = ProbeReader.parse(
                try t.probeFixture("ok.jsonl", now: Self.start), readAt: Self.start)
            guard case .reading(let twin) = same else {
                Issue.record("expected a reading for pool-b")
                return
            }
            try ReadingStore(context: t.context).save(twin, label: "pool-b")
        }
        if plainFresh { try storeFreshWithFableDue(t, account.label) }
        let r = refresher(t, accounts: accounts, clock: ClockBox(Self.start))
        let results = r.refresh(accounts: [account], force: false, fable: .forPick, deadline: 2)
        // At the deadline only the Fable probe runs, after a fresh reading or a plain probe.
        switch (plainFresh, results.first?.status) {
        case (true, .fresh?), (false, .probed?): break
        default: Issue.record("expected the plain step, got \(String(describing: results.first))")
        }
        // What the plain probe's duplicate check found stands with it.
        let duplicate: DuplicateCheck = tokenAccount ? .sameAs("pool-b") : .notRun
        #expect(results.first?.duplicate == duplicate)
        var observations = StatusObservations()
        observations.add(results)
        let observed = observations.probe[account.label]
        #expect(plainFresh ? observed == nil : observed != nil && observed?.error == nil)
        let warned: DuplicateCheck? = tokenAccount ? .sameAs("pool-b") : nil
        #expect(observations.duplicates[account.label] == warned)
        // The Fable probe ends on its own and saves what it read.
        let store = ReadingStore(context: t.context)
        func fableSaved() -> Bool {
            (try? store.load(label: account.label))?.fable?.source == ReadingSource.probe
        }
        let until = Date().addingTimeInterval(10)
        while Date() < until && !fableSaved() { Thread.sleep(forTimeInterval: 0.05) }
        #expect(fableSaved())
    }

    @Test func aFableReplyIsMergedByTheClockAfterItsProbe() throws {
        let t = try setUp()
        let account = login()
        try storeFreshWithFableDue(t, account.label)
        // A Fable reply whose windows carry no reset time.
        try t.fake(
            "probe-\(ProbeForm.fableModel).jsonl",
            stream(
                "\"five_hour\":{\"utilization\":0.2},\"seven_day\":{\"utilization\":0.5},"
                    + "\"\(WindowName.fable)\":{\"utilization\":0.3}"))
        // The clock is set 400 days ahead while the Fable probe runs.
        let ahead = Self.start.addingTimeInterval(400 * 86_400)
        let models = t.home.appendingPathComponent(".ab-fake/models.log")
        var r = refresher(t, accounts: [account], clock: ClockBox(Self.start))
        r.clock = {
            let ran = (try? String(contentsOf: models, encoding: .utf8)) ?? ""
            return ran.contains(ProbeForm.fableModel) ? ahead : Self.start
        }
        #expect(r.refresh(account: account, force: false, fable: .forPick).fable == .probed)
        // Both stored reset times had passed when the reply was read, so the reply's windows
        // replace them, and the reading keeps no reset time that would let it move the prune
        // cutoff.
        let stored = try #require(try ReadingStore(context: t.context).load(label: account.label))
        #expect(stored.readAt == ahead)
        #expect(stored.fiveHour?.resetsAt == nil && stored.sevenDay?.resetsAt == nil)
        try ConfigStore(context: t.context).save(Config(accounts: [account]))
        try HookRecord(context: t.context).record(.empty)
        let h = ReadingHistory(context: t.context)
        let before = Reading(
            readAt: Self.start,
            windows: [
                WindowName.sevenDay: WindowReading(
                    usedPercent: 10, resetsAt: Self.start.addingTimeInterval(86_400),
                    readAt: Self.start)
            ])
        try h.append(
            StatusBuilder.historyLine(account: account, reading: before, state: "ok"),
            label: account.label)
        try StatusBuilder.rebuild(context: t.context, now: ahead)
        #expect(try h.read(label: account.label).first?.at == Self.start)
    }

    @Test func aPlainReplyIsMergedByTheClockAfterItsProbe() throws {
        let t = try setUp()
        let account = login()
        let old = Self.start.addingTimeInterval(-7_200)
        try ReadingStore(context: t.context).save(
            Reading(
                readAt: old,
                windows: [
                    WindowName.fiveHour: WindowReading(
                        usedPercent: 10, resetsAt: Self.start.addingTimeInterval(3 * 3_600),
                        readAt: old),
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 20, resetsAt: Self.start.addingTimeInterval(3 * 86_400),
                        readAt: old),
                ]), label: account.label)
        // A plain reply whose windows carry no reset time.
        try t.fake(
            "probe.jsonl",
            stream("\"five_hour\":{\"utilization\":0.2},\"seven_day\":{\"utilization\":0.5}"))
        // The clock is set 400 days ahead while the plain probe runs.
        let ahead = Self.start.addingTimeInterval(400 * 86_400)
        let models = t.home.appendingPathComponent(".ab-fake/models.log")
        var r = refresher(t, accounts: [account], clock: ClockBox(Self.start))
        r.clock = {
            let ran = (try? String(contentsOf: models, encoding: .utf8)) ?? ""
            return ran.contains("haiku") ? ahead : Self.start
        }
        let result = r.refresh(account: account, force: false, fable: .none)
        #expect(!result.failed)
        // Both stored reset times had passed when the reply was read, so the reply's windows
        // replace them, and the reading keeps no reset time that would let it move the prune
        // cutoff.
        let stored = try #require(try ReadingStore(context: t.context).load(label: account.label))
        #expect(stored.readAt == ahead)
        #expect(stored.fiveHour?.resetsAt == nil && stored.sevenDay?.resetsAt == nil)
        try ConfigStore(context: t.context).save(Config(accounts: [account]))
        try HookRecord(context: t.context).record(.empty)
        let h = ReadingHistory(context: t.context)
        let before = Reading(
            readAt: Self.start,
            windows: [
                WindowName.sevenDay: WindowReading(
                    usedPercent: 10, resetsAt: Self.start.addingTimeInterval(86_400),
                    readAt: Self.start)
            ])
        try h.append(
            StatusBuilder.historyLine(account: account, reading: before, state: "ok"),
            label: account.label)
        try StatusBuilder.rebuild(context: t.context, now: ahead)
        #expect(try h.read(label: account.label).first?.at == Self.start)
    }

    @Test(arguments: ["plain", "Fable"])
    func aClockSetBackBetweenTheReadingsTimeAndItsMergeKeepsTheBound(_ probe: String) throws {
        let t = try setUp()
        let account = login()
        let fable = probe == "Fable"
        // Stored reset times still ahead of the real clock: a fresh reading whose Fable probe is
        // due, or a stale one the plain probe replaces.
        if fable {
            try storeFreshWithFableDue(t, account.label)
        } else {
            let old = Self.start.addingTimeInterval(-3_600)
            try ReadingStore(context: t.context).save(
                Reading(
                    readAt: old,
                    windows: [
                        WindowName.fiveHour: WindowReading(
                            usedPercent: 5, resetsAt: Self.start.addingTimeInterval(3_600),
                            readAt: old),
                        WindowName.sevenDay: WindowReading(
                            usedPercent: 10, resetsAt: Self.start.addingTimeInterval(3 * 86_400),
                            readAt: old),
                    ]), label: account.label)
        }
        // A reply whose windows carry no reset time.
        let windows = "\"five_hour\":{\"utilization\":0.2},\"seven_day\":{\"utilization\":0.3}"
        if fable {
            try t.fake(
                "probe-\(ProbeForm.fableModel).jsonl",
                stream(windows + ",\"\(WindowName.fable)\":{\"utilization\":0.4}"))
        } else {
            try t.fake("probe.jsonl", stream(windows))
        }
        // The clock reads 400 days ahead once, when the probe ends, and is set back right after.
        let lead: TimeInterval = 400 * 86_400
        let ahead = Self.start.addingTimeInterval(lead)
        let models = t.home.appendingPathComponent(".ab-fake/models.log")
        let model = fable ? ProbeForm.fableModel : "haiku"
        let once = FirstClaim()
        var r = refresher(t, accounts: [account], clock: ClockBox(Self.start))
        r.clock = {
            let ran = (try? String(contentsOf: models, encoding: .utf8)) ?? ""
            return ran.contains(model) && once.claim() ? ahead : Self.start
        }
        let result = r.refresh(account: account, force: false, fable: fable ? .forPick : .none)
        #expect(!result.failed)
        // The merge judged the stored reset times at the reading's own time, when both had
        // passed, so the reply's windows replace them and the reading keeps no reset time.
        let stored = try #require(try ReadingStore(context: t.context).load(label: account.label))
        #expect(stored.readAt == ahead)
        #expect(stored.fiveHour?.resetsAt == nil && stored.sevenDay?.resetsAt == nil)

        // Lines of 50 days, 20 days, 2 days and 1 hour, another account's reading taken at the
        // real time, then a rebuild while the clock is ahead again.
        let other = token("other")
        try ReadingStore(context: t.context).save(
            Reading(
                readAt: Self.start,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 20, resetsAt: Self.start.addingTimeInterval(3 * 86_400),
                        readAt: Self.start)
                ]), label: other.label)
        try ConfigStore(context: t.context).save(Config(accounts: [account, other]))
        try HookRecord(context: t.context).record(.empty)
        let h = ReadingHistory(context: t.context)
        let log = EventLog(context: t.context)
        let ages: [TimeInterval] = [50 * 86_400, 20 * 86_400, 2 * 86_400, 3_600]
        for (index, ago) in ages.enumerated() {
            let at = Self.start.addingTimeInterval(-ago)
            let line = Reading(
                readAt: at,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: Double(10 + index), resetsAt: at.addingTimeInterval(86_400),
                        readAt: at)
                ])
            try h.append(
                StatusBuilder.historyLine(account: account, reading: line, state: "ok"),
                label: account.label)
            try log.append(
                [
                    EventDraft(
                        label: account.label, accountKey: account.accountKey,
                        type: EventType.limited, code: nil, window: "weekly", resetsAt: nil,
                        notBefore: nil, text: "Limited.")
                ], now: at)
        }
        try StatusBuilder.rebuild(context: t.context, now: ahead.addingTimeInterval(60))
        // Retention counts back from the other account's reading: only the line and the event
        // older than 35 days go.
        let left = try h.read(label: account.label).map { Self.start.timeIntervalSince($0.at) }
        #expect(left == Array(ages.dropFirst()) + [-lead])
        let seqs = try log.answer(EventsQuery(), now: Self.start).events.map(\.seq)
        #expect(Array(seqs.prefix(3)) == [2, 3, 4])
    }

    @Test(arguments: ["plain", "Fable"])
    func aStoredResetTimeThatPassedAMinuteBeforeTheReplyIsNotKept(_ probe: String) throws {
        let t = try setUp()
        let account = login()
        let fable = probe == "Fable"
        // Both stored reset times passed a minute before the reply's own time. The plain case's
        // reading is stale; the Fable case's is fresh, with its Fable probe due.
        let at = Self.start.addingTimeInterval(fable ? -120 : -7_200)
        let passed = Self.start.addingTimeInterval(-60)
        try ReadingStore(context: t.context).save(
            Reading(
                readAt: at,
                windows: [
                    WindowName.fiveHour: WindowReading(
                        usedPercent: 5, resetsAt: passed, readAt: at),
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 10, resetsAt: passed, readAt: at),
                ]), label: account.label)
        // A reply whose windows carry no reset time.
        let windows = "\"five_hour\":{\"utilization\":0.2},\"seven_day\":{\"utilization\":0.3}"
        if fable {
            try t.fake(
                "probe-\(ProbeForm.fableModel).jsonl",
                stream(windows + ",\"\(WindowName.fable)\":{\"utilization\":0.4}"))
        } else {
            try t.fake("probe.jsonl", stream(windows))
        }
        let r = refresher(t, accounts: [account], clock: ClockBox(Self.start))
        let result = r.refresh(account: account, force: false, fable: fable ? .forPick : .none)
        #expect(!result.failed)
        if fable { #expect(result.fable == .probed) }
        // The merge judged both stored reset times at the reply's own time, when they had passed,
        // so the reply's windows replace them.
        let stored = try #require(try ReadingStore(context: t.context).load(label: account.label))
        #expect(stored.readAt == Self.start)
        #expect(stored.fiveHour?.resetsAt == nil && stored.sevenDay?.resetsAt == nil)
    }

    @Test func eachResultIsHeardBeforeTheAccountsProbeLockIsLetGo() throws {
        let t = try setUp()
        let account = login()
        let r = refresher(t, accounts: [account], clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        let context = t.context
        @Sendable func lockIsHeld() -> Bool {
            guard
                let lock = try? NoFollowWriter(root: context.dataRoot).acquireLock(
                    folders: Layout.locksFolders, name: Layout.lockName(account.label), wait: 0)
            else { return true }
            lock.release()
            return false
        }
        var heardHeld: Bool?
        let one = r.refresh(account: account, force: true) { _ in heardHeld = lockIsHeld() }
        #expect(one.status != .notStarted)
        #expect(heardHeld == true)
        let watched = Box<Bool>()
        let watch = RefreshWatch(onResult: { _ in watched.value = lockIsHeld() })
        _ = r.refresh(accounts: [account], force: true, watch: watch)
        #expect(watched.value == true)
        // Free again once the refresh has returned.
        let free = try NoFollowWriter(root: context.dataRoot).acquireLock(
            folders: Layout.locksFolders, name: Layout.lockName(account.label), wait: 5)
        #expect(free != nil)
        free?.release()
        #expect(t.fakeLines("models.log") == ["haiku", "haiku"])
    }

    @Test func aFableProbeOfARefreshWithNoWatchCountsAsTriedOnceItEnds() throws {
        let t = try setUp()
        try t.fakeProbe("fable.jsonl", model: ProbeForm.fableModel, now: Self.start)
        let account = login()
        let r = refresher(t, accounts: [account], clock: ClockBox(Self.start))
        let results = r.refresh(accounts: [account], force: false)
        #expect(results.first?.fable == .probed)
        let stored = try #require(try ReadingStore(context: t.context).load(label: account.label))
        #expect(stored.fableProbedAt == Self.start)
    }

    @Test func eachRefreshStartsAtAnAccountChosenAtRandom() throws {
        let t = try TestHome()
        let r = refresher(t, accounts: [], clock: ClockBox(Self.start))
        var seen = Set<Int>()
        for _ in 0..<300 { seen.insert(r.firstAccount(10)) }
        #expect(seen == Set(0..<10))
    }

    @Test func aFableSaveThatFailsForAnotherReasonFailsTheWholeRefresh() throws {
        let t = try setUp()
        try t.fakeProbe("fable.jsonl", model: ProbeForm.fableModel, now: Self.start)
        // A label of its own: the write hook is keyed by file name across the whole run.
        let account = Account(
            label: "fable-save-fails", kind: Kind.login, role: Role.pool,
            email: "main@example.com")
        let r = refresher(t, accounts: [account], clock: ClockBox(Self.start))
        // The plain reading is saved; the Fable reading's save fails.
        let name = Layout.readingName(account.label)
        let writes = Counter()
        NoFollowWriter.beforeRename.set(name) {
            writes.add()
            if writes.value == 2 { throw ToolError("Could not write \(name).") }
        }
        defer { NoFollowWriter.beforeRename.set(name, nil) }
        let result = r.refresh(account: account, force: false)
        NoFollowWriter.beforeRename.set(name, nil)
        #expect(writes.value == 2)
        // The Fable probe ran first, so the write that failed is the save of its reading.
        #expect(t.fakeLines("models.log") == ["haiku", ProbeForm.fableModel])
        guard case .failed(let issue) = result.status else {
            Issue.record("expected the whole refresh to fail, got \(result.status)")
            return
        }
        #expect(issue.text.contains("Could not write"))
        #expect(result.fable == .notRun)
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

        // One value that does not decode leaves the rest of the file in force: the next good
        // probe replaces only that window, and the weekly use stored for the same window holds.
        let earlier = Self.start.addingTimeInterval(-3600)
        let weekReset = try #require(
            ProbeReader.minute(Self.start.addingTimeInterval(400_000)))
        try store.save(
            Reading(
                readAt: earlier,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 90, resetsAt: weekReset, readAt: earlier),
                    WindowName.fiveHour: WindowReading(
                        usedPercent: 99, resetsAt: Self.start.addingTimeInterval(7200),
                        readAt: earlier),
                ]), label: "main")
        let text = try String(contentsOf: url, encoding: .utf8)
        let fiveHourReset = "\"2027-01-15T10:00:00Z\""
        #expect(text.components(separatedBy: fiveHourReset).count == 2)
        try Data(
            text.replacingOccurrences(of: fiveHourReset, with: "\"-4712-01-01T00:00:00Z\"").utf8
        ).write(to: url)
        guard case .probed = r.refresh(account: login(), force: true).status else {
            Issue.record("expected a probe")
            return
        }
        let after = try #require(try store.load(label: "main"))
        #expect(after.sevenDay?.usedPercent == 90)
        #expect(after.fiveHour?.usedPercent == 12.3)
    }

    // A probe reading must carry the weekly use, and the 5-hour use when one is stored.

    var start: Int { Int(Self.start.timeIntervalSince1970) }

    func stream(_ windows: String) -> String {
        "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{\(windows)}}}\n"
    }

    var fiveHourText: String { "\"five_hour\":{\"utilization\":0.2,\"resetsAt\":\(start + 3_600)}" }
    var sevenDayText: String {
        "\"seven_day\":{\"utilization\":0.3,\"resetsAt\":\(start + 86_400)}"
    }

    func readingFile(_ t: TestHome) -> URL {
        t.context.dataRoot.appendingPathComponent("state/readings/main.json")
    }

    @Test func aReplyWithoutTheWeeklyUseFailsAndLeavesTheStoredReadingAsItWas() throws {
        let t = try setUp()
        let earlier = Self.start.addingTimeInterval(-7_200)
        try ReadingStore(context: t.context).save(
            Reading(
                readAt: earlier,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 40, resetsAt: Self.start.addingTimeInterval(3 * 86_400),
                        readAt: earlier)
                ]), label: "main")
        let before = try Data(contentsOf: readingFile(t))
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        let missingKey = ",\"seven_day\":{\"resetsAt\":\(start + 86_400)}"
        for weekly in ["", missingKey] {
            try t.fake("probe.jsonl", stream(fiveHourText + weekly))
            guard case .failed(let issue) = r.refresh(account: login(), force: false).status else {
                Issue.record("expected a failure for \(weekly.isEmpty ? "no window" : "no value")")
                continue
            }
            #expect(issue.code == .checkFailed)
            #expect(issue.text == ProbeReader.noWeekly)
            #expect(try Data(contentsOf: readingFile(t)) == before)
        }
    }

    @Test func aReplyWithoutFiveHourFailsWhileOneIsStoredAndPassesWhenNoneIs() throws {
        let t = try setUp()
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        try t.fake("probe.jsonl", stream(sevenDayText))
        guard case .probed(let first) = r.refresh(account: login(), force: false).status else {
            Issue.record("expected a weekly-only reply to be read when no five_hour is stored")
            return
        }
        #expect(first.fiveHour == nil)
        // Once a five_hour is stored, a reply without it is refused and changes nothing.
        try t.fakeProbe("ok.jsonl", now: Self.start)
        guard case .probed = r.refresh(account: login(), force: true).status else {
            Issue.record("expected a probe")
            return
        }
        let before = try Data(contentsOf: readingFile(t))
        try t.fake("probe.jsonl", stream(sevenDayText))
        guard case .failed(let issue) = r.refresh(account: login(), force: true).status else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.text == ProbeReader.noFiveHour)
        #expect(try Data(contentsOf: readingFile(t)) == before)
    }

    @Test func aFableReplyTheStoreRefusesFailsOnlyTheFableProbe() throws {
        let t = try setUp()
        let fable = "\"\(WindowName.fable)\":{\"utilization\":0.31,\"resetsAt\":\(start + 86_400)}"
        try t.fake("probe-\(ProbeForm.fableModel).jsonl", stream(sevenDayText + "," + fable))
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start))
        let result = r.refresh(account: login(), force: false)
        guard case .probed(let reading) = result.status else {
            Issue.record("expected the plain probe to stand, got \(result.status)")
            return
        }
        #expect(reading.fiveHour?.usedPercent == 12.3)
        #expect(result.fable == .failed(Issue(.checkFailed, .error, ProbeReader.noFiveHour)))
        #expect(try ReadingStore(context: t.context).load(label: "main")?.fable?.source != "probe")
    }

    @Test func noWindowIsEvictedAfterAFailedProbeOrWhenOnlyTheFableProbeTimeIsSaved() throws {
        let t = try setUp()
        let store = ReadingStore(context: t.context)
        try store.save(
            Reading(
                readAt: Self.start,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 10, resetsAt: Self.start.addingTimeInterval(86_400),
                        readAt: Self.start),
                    "monthly_extra": WindowReading(
                        usedPercent: 5, resetsAt: nil,
                        readAt: Self.start.addingTimeInterval(-40 * 86_400)),
                ]), label: "main")
        // The reading is fresh, so only the Fable probe runs; it fails, and only its time is saved.
        try t.fake("probe-\(ProbeForm.fableModel).jsonl", "not stream json\n")
        let r = refresher(t, accounts: [login()], clock: ClockBox(Self.start))
        let fableOnly = r.refresh(account: login(), force: false)
        guard case .fresh = fableOnly.status, case .failed = fableOnly.fable else {
            Issue.record("expected only a failed Fable probe, got \(fableOnly)")
            return
        }
        let saved = try #require(try store.load(label: "main"))
        #expect(saved.fableProbedAt == Self.start)
        #expect(saved.windows["monthly_extra"] != nil)
        // A plain probe that fails saves nothing at all.
        try t.fake("probe.jsonl", "not stream json\n")
        let before = try Data(contentsOf: readingFile(t))
        guard case .failed = r.refresh(account: login(), force: true).status else {
            Issue.record("expected a failure")
            return
        }
        #expect(try Data(contentsOf: readingFile(t)) == before)
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

/// True for the first caller only, whichever thread it runs on.
private final class FirstClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

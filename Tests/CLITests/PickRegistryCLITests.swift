import Foundation
import Testing

@testable import Core

/// `pick` decides on the registry as saved once it holds the pick lock, so a role saved while its
/// probes ran or while it waited counts, a changed account is still skipped, and an account added
/// meanwhile is neither probed nor judged.
@Suite struct PickRegistryCLITests {
    static let reserveRefusal =
        "Weekly use 60.0% is above the reserve line of 50.0% minus a 5 point margin."

    /// A home with one pool `login` account `main`, signed in on its plan. No probe timeout or
    /// pick deadline ends a held probe before the test lets it go.
    func setUp() throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        let context = SignInState.context(cli)
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                expectedPlanTier: "max_20x")
        ])
        config.fable.probe = false
        config.probe.timeoutSeconds = 600
        config.picker.deadlineSeconds = 600
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    /// A fresh reading: weekly use 60 percent with its reset 6 days out, 5-hour use 20 percent.
    func storeFresh(_ cli: CLIHome, now: Date) throws {
        let windows = [
            WindowName.sevenDay: WindowReading(
                usedPercent: 60, resetsAt: SignInSwitch.minute(now.addingTimeInterval(6 * 86_400)),
                readAt: now),
            WindowName.fiveHour: WindowReading(
                usedPercent: 20, resetsAt: SignInSwitch.minute(now.addingTimeInterval(4 * 3_600)),
                readAt: now),
        ]
        try SignInSwitch.store(cli).save(Reading(readAt: now, windows: windows), label: "main")
    }

    func holdPickLock(_ cli: CLIHome) throws -> FileLock {
        let writer = NoFollowWriter(root: cli.dataRoot)
        return try #require(
            try writer.acquireLock(folders: Layout.locksFolders, name: Layout.pickLockName, wait: 5)
        )
    }

    /// Starts `pick --json` while the test holds the pick lock, makes `change` once the pick has
    /// read the registry (its sign-in check comes after that read), then lets the lock go.
    func pickAround(_ cli: CLIHome, _ args: [String] = [], change: () throws -> Void) throws
        -> Support.Output
    {
        let lock = try holdPickLock(cli)
        let pick = SignInRace.started(cli, ["pick", "--json"] + args)
        #expect(SignInRace.waitUntil { cli.fakeRecord("args.log").contains("auth status") })
        try change()
        lock.release()
        #expect(SignInRace.waitUntil { pick.isDone })
        return try #require(pick.value)
    }

    @Test func aRoleSavedWhileThePickWaitsForTheLockCountsForTheDecision() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try storeFresh(cli, now: Date())
        // As `config set-main main` saves it, under the lock the test holds.
        let out = try pickAround(cli) {
            try SignInState.edit(cli) {
                $0.accounts[0].role = Role.main
                $0.accounts[0].reserve = .standard
            }
        }
        #expect(out.status == 2)
        #expect(try SignInSwitch.answer(out)["label"] is NSNull)
        #expect(try SignInSwitch.reason(out, "main") == Self.reserveRefusal)
    }

    /// Set by the first caller only, from any thread.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }

        var done: Bool {
            lock.lock()
            defer { lock.unlock() }
            return claimed
        }
    }

    /// True while another lock holds the pick lock; each acquire opens the file anew, so a pick
    /// in this process counts.
    static func pickLockHeld(_ context: ToolContext) -> Bool {
        let writer = NoFollowWriter(root: context.dataRoot)
        do {
            guard
                let lock = try writer.acquireLock(
                    folders: Layout.locksFolders, name: Layout.pickLockName, wait: 0)
            else { return true }
            lock.release()
            return false
        } catch {
            return false
        }
    }

    @Test func aRoleSavedOnlyOnceThePickHoldsTheLockCountsForTheDecision() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try storeFresh(cli, now: Date())
        let context = SignInState.context(cli)
        let once = Once()
        var service = PickService(context: context)
        // The first clock read the pick makes while it holds the lock saves the role, as
        // `config set-main main` saves it, so no read before the lock can see it.
        service.clock = {
            if Self.pickLockHeld(context), once.claim() {
                let store = ConfigStore(context: context)
                if var config = try? store.loadRequired() {
                    config.accounts[0].role = Role.main
                    config.accounts[0].reserve = .standard
                    try? store.save(config)
                }
            }
            return Date()
        }
        let result = try service.pick(PickRequest(dryRun: true))
        #expect(once.done)
        #expect(result.label == nil)
        #expect(result.candidates.first { $0.label == "main" }?.reason == Self.reserveRefusal)
    }

    @Test func aMainRoleMovedWhileThePickWaitsSkipsTheOldMainAsADuplicate() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try storeFresh(cli, now: Date())
        // `main` is the main account, and a pool token account has its email.
        try SignInState.edit(cli) {
            $0.accounts[0].role = Role.main
            $0.accounts[0].reserve = .standard
            $0.accounts.append(
                Account(
                    label: "spare", kind: Kind.token, role: Role.pool, email: "main@example.com"))
        }
        // As `config set-main spare` and then `config clear-main main` save them.
        let out = try pickAround(cli) {
            try SignInState.edit(cli) {
                $0.accounts[1].role = Role.main
                $0.accounts[1].reserve = .standard
                $0.accounts[0].role = Role.pool
                $0.accounts[0].reserve = nil
            }
        }
        #expect(out.status == 2)
        #expect(try SignInSwitch.answer(out)["label"] is NSNull)
        #expect(try SignInSwitch.reason(out, "main") == "duplicate login")
    }

    @Test func aRoleSavedWhileAProbeOfThePickIsHeldCountsForTheDecision() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        // Nothing is stored, so the pick probes the account and reads the same use.
        try cli.fake(
            "probe.jsonl",
            SignInSwitch.stream(week: 0.6, days: 6, five: 0.2, hours: 4, now: Date()))
        try cli.fake("hold-default", "")
        let pick = SignInRace.started(cli, ["pick", "--json"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-default") })
        let saved = try cli.run(["config", "set-main", "main"])
        #expect(saved.status == 0)
        try cli.fake("go-default", "")
        #expect(SignInRace.waitUntil { pick.isDone })

        let out = try #require(pick.value)
        #expect(out.status == 2)
        #expect(try SignInSwitch.reason(out, "main") == Self.reserveRefusal)
        #expect(try SignInSwitch.store(cli).load(label: "main")?.sevenDay?.usedPercent == 60)
    }

    @Test func anEndSavedWhileThePickWaitsForTheLockCountsForTheDecision() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try storeFresh(cli, now: Date())
        let out = try pickAround(cli) {
            try SignInState.edit(cli) { $0.accounts[0].endsAt = "2020-01-01" }
        }
        #expect(out.status == 2)
        #expect(try SignInSwitch.answer(out)["label"] is NSNull)
        #expect(try SignInSwitch.reason(out, "main") == "account ended")
    }

    /// The launch files, the lease file and the pick log under the data folder.
    func decisionFiles(_ cli: CLIHome) -> [String] {
        let fm = FileManager.default
        let root = LaunchFiles.rootURL(context: SignInState.context(cli))
        let launch = fm.subpaths(atPath: root.path) ?? []
        let state = ["state/leases.json", "state/picks.log"].filter {
            fm.fileExists(atPath: cli.dataRoot.appendingPathComponent($0).path)
        }
        return launch.filter { $0.hasSuffix(".json") } + state
    }

    @Test func aPickThatFindsNoRegistrySavedOnceItHoldsTheLockStopsAndWritesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try storeFresh(cli, now: Date())
        // As `uninstall` removes it, under the lock the test holds.
        let out = try pickAround(cli) {
            try FileManager.default.moveItem(
                at: cli.dataRoot.appendingPathComponent("config.json"),
                to: cli.home.appendingPathComponent("config-moved.json"))
        }
        #expect(out.status == 1)
        #expect(out.stdout.isEmpty)
        #expect(String(decoding: out.stderr, as: UTF8.self).contains(Messages.notSetUp))
        #expect(decisionFiles(cli) == [])
    }

    @Test func aPickThatCannotReadTheRegistryOnceItHoldsTheLockStopsWithItsText() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try storeFresh(cli, now: Date())
        let out = try pickAround(cli) {
            try Data("{".utf8).write(to: cli.dataRoot.appendingPathComponent("config.json"))
        }
        #expect(out.status == 1)
        #expect(out.stdout.isEmpty)
        let text = String(decoding: out.stderr, as: UTF8.self)
        #expect(text.contains("config.json is not valid JSON."))
        #expect(decisionFiles(cli) == [])
        // The same text a pick gives when the registry is that way at its start.
        let later = try cli.run(["pick", "--json"])
        #expect(later.status == 1)
        #expect(String(decoding: later.stderr, as: UTF8.self) == text)
    }

    @Test func anAccountWhoseEmailChangedWhileThePickWaitedIsStillSkipped() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try storeFresh(cli, now: Date())
        let out = try pickAround(cli) {
            try SignInState.edit(cli) { $0.accounts[0].email = "other@example.com" }
        }
        #expect(out.status == 2)
        #expect(
            try SignInSwitch.reason(out, "main") == "the account changed while the pick waited")
    }

    @Test func anAccountAddedWhileThePickWaitedIsNeitherProbedNorJudged() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try storeFresh(cli, now: Date())
        let out = try pickAround(cli, ["--dry-run"]) {
            try SignInState.edit(cli) {
                $0.accounts.append(Account(label: "added", kind: Kind.token, role: Role.pool))
            }
        }
        #expect(out.status == 0)
        #expect(try SignInSwitch.answer(out)["label"] as? String == "main")
        let candidates = try #require(
            try SignInSwitch.answer(out)["candidates"] as? [[String: Any]])
        #expect(candidates.compactMap { $0["label"] as? String } == ["main"])
        #expect(SignInSwitch.probes(cli) == 0)
    }
}

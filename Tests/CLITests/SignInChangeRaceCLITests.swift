import Foundation
import Testing

@testable import Core

/// What the forced-order tests of a sign-in change share.
enum SignInRace {
    /// What a command on another thread returned, once it has.
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Support.Output?
        private var finished = false

        func set(_ value: Support.Output?) {
            lock.lock()
            stored = value
            finished = true
            lock.unlock()
        }

        var value: Support.Output? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var isDone: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

    /// Starts `args` on a thread of its own, so the test can act while it runs.
    static func started(_ cli: CLIHome, _ args: [String]) -> Outcome {
        let outcome = Outcome()
        let thread = Thread { outcome.set(try? cli.run(args)) }
        thread.stackSize = 1 << 20
        thread.start()
        return outcome
    }

    /// Polls `condition` until it holds, at most five minutes; no step waits on the clock alone.
    static func waitUntil(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(300)
        while Date() < end {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    /// True while another process holds the pick lock.
    static func pickLockHeld(_ cli: CLIHome) -> Bool {
        let writer = NoFollowWriter(root: cli.dataRoot)
        guard
            let lock = try? writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 0)
        else { return true }
        lock.release()
        return false
    }

    /// Whether the fake `claude` has written `name` in its folder.
    static func faked(_ cli: CLIHome, _ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: cli.home.appendingPathComponent(".ab-fake/\(name)").path)
    }

    /// Each event as `label:type`, oldest first.
    static func eventTypes(_ cli: CLIHome) throws -> [String] {
        let out = try cli.run(["events", "--json"])
        let doc = try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
        let events = try #require(doc["events"] as? [[String: Any]])
        return events.map { "\($0["label"] as? String ?? "?"):\($0["type"] as? String ?? "?")" }
    }

    /// A weekly use the picker counts as limited, its reset a day out.
    static func storeLimited(_ cli: CLIHome, _ label: String) throws {
        let now = Date()
        let at = now.addingTimeInterval(-60)
        let reset = SignInSwitch.minute(now.addingTimeInterval(86_400))
        try SignInSwitch.store(cli).save(
            Reading(
                readAt: at,
                windows: [
                    WindowName.sevenDay: WindowReading(usedPercent: 97, resetsAt: reset, readAt: at)
                ]), label: label)
    }
}

/// A command that changes which sign-in a label stands for waits for a probe of that label that
/// is under way, then changes what that probe saved: the probe lock orders the two.
extension SignInChangeReadingCLITests {
    /// Holds the default folder's probe in a `refresh`, starts `args` while it is held, and lets
    /// the probe go once the command holds the pick lock or has saved `saved` in the registry.
    func aroundAHeldProbe(_ cli: CLIHome, _ args: [String], saved: String) throws -> (
        refresh: Support.Output?, command: Support.Output?
    ) {
        try cli.fake("hold-default", "")
        let refresh = SignInRace.started(cli, ["refresh", "--label", "main"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-default") })
        let command = SignInRace.started(cli, args)
        #expect(
            SignInRace.waitUntil {
                SignInRace.pickLockHeld(cli) || cli.read("config.json").contains(saved)
            })
        try cli.fake("go-default", "")
        #expect(SignInRace.waitUntil { refresh.isDone && command.isDone })
        return (refresh.value, command.value)
    }

    @Test func anEmailChangeDeletesTheReadingAProbeOfTheOldSignInSavesWhileItRuns() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let now = Date()
        try SignInSwitch.storeOld(cli, "main", age: 1_200, now: now)
        try SignInSwitch.reply(cli, week: 0.3, now: now)
        let ran = try aroundAHeldProbe(
            cli, ["config", "set", "main", "email", "other@example.com"],
            saved: "other@example.com")
        #expect(ran.command?.status == 0)
        #expect(ran.refresh != nil)
        #expect(try SignInSwitch.store(cli).load(label: "main") == nil)
    }

    @Test func aRenameMovesTheReadingAProbeSavesWhileItRunsAndLeavesNoneBehind() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let now = Date()
        try SignInSwitch.storeOld(cli, "main", age: 1_200, now: now)
        try SignInSwitch.reply(cli, week: 0.3, now: now)
        let ran = try aroundAHeldProbe(
            cli, ["config", "set", "main", "label", "primary"], saved: "\"primary\"")
        #expect(ran.command?.status == 0)
        #expect(ran.refresh?.status == 0)
        #expect(try SignInSwitch.store(cli).load(label: "main") == nil)
        // The probe's own reading, saved before the rename, moved with the account.
        let moved = try #require(try SignInSwitch.store(cli).load(label: "primary"))
        #expect(moved.sevenDay?.usedPercent == 30)
    }

    @Test func aChangeLeavesNoLimitClearedEventAsARemoveLeavesNone() throws {
        for args in [
            ["remove", "main"], ["config", "set", "main", "email", "other@example.com"],
            ["config", "set", "main", "label", "primary"],
        ] {
            let cli = try setUp(role: Role.pool)
            defer { cli.cleanup() }
            try SignInRace.storeLimited(cli, "main")
            #expect(try cli.run(["status", "--json"]).status == 0)
            #expect(try SignInRace.eventTypes(cli).last == "main:limited", "\(args)")
            if args.contains("email") { try cli.fakeFixture("wrong_account") }
            #expect(try cli.run(args).status == 0, "\(args)")
            #expect(try cli.run(["status", "--json"]).status == 0)
            let types = try SignInRace.eventTypes(cli)
            #expect(!types.contains { $0.hasSuffix(":limit_cleared") }, "\(args): \(types)")
            if args[0] == "remove" { #expect(types.last == "main:account_removed") }
        }
    }
}

extension TokenAccountsCLITests {
    @Test func aTokenReplaceWaitsForAProbeOfTheOldTokenAndKeepsNothingItSaved() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let now = Date()
        let old = Canary.realShapeToken()
        let fresh = Canary.realShapeToken()
        // Each token gets its own replies: the old one more use and sooner resets.
        func stream(_ week: Double, _ days: Double, _ five: Double, _ hours: Double) -> String {
            let weekly = Int(
                SignInSwitch.minute(now.addingTimeInterval(days * 86_400)).timeIntervalSince1970)
            let short = Int(
                SignInSwitch.minute(now.addingTimeInterval(hours * 3_600)).timeIntervalSince1970)
            return
                #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"#
                + #""seven_day":{"utilization":\#(week),"resetsAt":\#(weekly)},"#
                + #""five_hour":{"utilization":\#(five),"resetsAt":\#(short)}}}}"# + "\n"
        }
        try cli.fake("token-stream-old.token", old)
        try cli.fake("token-stream-old.jsonl", stream(0.7, 1, 0.5, 1))
        try cli.fake("token-stream-new.token", fresh)
        try cli.fake("token-stream-new.jsonl", stream(0.6, 6, 0.2, 4))
        try cli.fake("setup-token.out", old + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        try ageReading(cli, "lab", by: 1_200)

        try cli.fake("hold-lab", "")
        let refresh = SignInRace.started(cli, ["refresh", "--label", "lab"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-lab") })
        try cli.fake("setup-token.out", fresh + "\n")
        let login = SignInRace.started(cli, ["login", "lab"])
        let file = try tokenFile(cli, "lab")
        #expect(
            SignInRace.waitUntil {
                SignInRace.pickLockHeld(cli)
                    || ((try? String(contentsOf: file, encoding: .utf8))?.contains(fresh) ?? false)
            })
        try cli.fake("go-lab", "")
        #expect(SignInRace.waitUntil { refresh.isDone && login.isDone })
        #expect(login.value?.status == 0)

        let stored = try #require(try SignInSwitch.store(cli).load(label: "lab"))
        #expect(Set(stored.windows.keys) == [WindowName.fiveHour, WindowName.sevenDay])
        #expect(stored.sevenDay?.usedPercent == 60)
        #expect(
            stored.sevenDay?.resetsAt == SignInSwitch.minute(now.addingTimeInterval(6 * 86_400)))
        #expect(stored.fiveHour?.usedPercent == 20)
    }

    @Test func aTokenReplaceLeavesNoLimitClearedEvent() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        try SignInRace.storeLimited(cli, "lab")
        #expect(try cli.run(["status", "--json"]).status == 0)
        #expect(try SignInRace.eventTypes(cli).last == "lab:limited")
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let types = try SignInRace.eventTypes(cli)
        #expect(types.last == "lab:token_replaced")
        #expect(!types.contains("lab:limit_cleared"))
    }

    @Test func aFirstTokenSaveWaitsForAProbeOfTheOldTokenAndKeepsNothingItSaved() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let now = Date()
        let old = Canary.realShapeToken()
        let fresh = Canary.realShapeToken()
        try cli.fake("token-stream-old.token", old)
        try cli.fake(
            "token-stream-old.jsonl",
            SignInSwitch.stream(week: 0.7, days: 1, five: 0.5, hours: 1, now: now))
        try cli.fake("token-stream-new.token", fresh)
        try cli.fake(
            "token-stream-new.jsonl",
            SignInSwitch.stream(week: 0.6, days: 6, five: 0.2, hours: 4, now: now))
        try cli.fake("setup-token.out", old + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        try ageReading(cli, "lab", by: 1_200)

        try cli.fake("hold-lab", "")
        let refresh = SignInRace.started(cli, ["refresh", "--label", "lab"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-lab") })
        // The token file goes while that probe runs, so the next save is a first one.
        let file = try tokenFile(cli, "lab")
        try FileManager.default.removeItem(at: file)
        try cli.fake("setup-token.out", fresh + "\n")
        let login = SignInRace.started(cli, ["login", "lab"])
        #expect(
            SignInRace.waitUntil {
                SignInRace.pickLockHeld(cli)
                    || ((try? String(contentsOf: file, encoding: .utf8))?.contains(fresh) ?? false)
            })
        try cli.fake("go-lab", "")
        #expect(SignInRace.waitUntil { refresh.isDone && login.isDone })
        #expect(login.value?.status == 0)

        let stored = try #require(try SignInSwitch.store(cli).load(label: "lab"))
        #expect(stored.sevenDay?.usedPercent == 60)
        #expect(
            stored.sevenDay?.resetsAt == SignInSwitch.minute(now.addingTimeInterval(6 * 86_400)))
        #expect(stored.fiveHour?.usedPercent == 20)
    }

    @Test func aPickBegunBeforeARenameNeverJudgesTheAccountByTheNewAccountsReading() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let now = Date()
        let at = now.addingTimeInterval(-60)
        // `main` has its own fresh reading, with too little room to be picked.
        try SignInSwitch.store(cli).save(
            Reading(
                readAt: at,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 92,
                        resetsAt: SignInSwitch.minute(now.addingTimeInterval(3 * 86_400)),
                        readAt: at),
                    WindowName.fiveHour: WindowReading(
                        usedPercent: 10,
                        resetsAt: SignInSwitch.minute(now.addingTimeInterval(3_600)), readAt: at),
                ]), label: "main")
        try addLab(cli, "spare-a")
        try cli.fake(
            "probe-for-spare-a.jsonl",
            SignInSwitch.stream(week: 0.99, days: 6, five: 0.05, hours: 4, now: now))
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "spare-a"]).status == 0)
        // No probe timeout or pick deadline ends the held probe before the test lets it go.
        try SignInState.edit(cli) {
            $0.probe.timeoutSeconds = 600
            $0.fable.probeTimeoutSeconds = 600
            $0.picker.deadlineSeconds = 600
        }
        try ageReading(cli, "spare-a", by: 3_600)

        try cli.fake("hold-spare-a", "")
        let pick = SignInRace.started(cli, ["pick", "--json"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-spare-a") })
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try cli.run(["add", "main"]).status == 0)
        try cli.fake(
            "probe-for-main.jsonl",
            SignInSwitch.stream(week: 0.1, days: 6, five: 0.2, hours: 4, now: now))
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "main"]).status == 0)
        try cli.fake("go-spare-a", "")
        #expect(SignInRace.waitUntil { pick.isDone })

        let out = try #require(pick.value)
        #expect(try SignInSwitch.answer(out)["label"] as? String != "main")
        #expect(try SignInSwitch.reason(out, "main") == "the account changed while the pick waited")
        let leases = try LeaseStore(context: SignInState.context(cli))
            .current(now: Date(), leaseMinutes: 10)
        #expect(!leases.contains { $0.label == "main" })
    }
}

extension PersonCommandsCLITests {
    @Test func aRunBegunBeforeARenameIsRefusedOnceAnotherAccountHoldsTheLabel() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fakeProbe("ok.jsonl")
        // The sign-in check `run` makes before it takes the pick lock is held.
        try cli.fake("hold-auth", "")
        let run = SignInRace.started(cli, ["run", "main"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-auth") })
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try cli.run(["add", "main"]).status == 0)
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "main"]).status == 0)
        try cli.fake("go-auth", "")
        #expect(SignInRace.waitUntil { run.isDone })

        #expect(run.value?.status == 1)
        let leases = try LeaseStore(context: SignInState.context(cli))
            .current(now: Date(), leaseMinutes: 10)
        #expect(leases.isEmpty)
        #expect(launchFiles(cli).isEmpty)
    }
}

/// What the commands that change a label's sign-in do before and while another command's probe
/// of that label runs, each order forced with the fake's holds.
extension SignInChangeReadingCLITests {
    /// A token account under `label`, signed in, whose stored reading is stale so a refresh probes
    /// it, and whose probes answer weekly use `week`.
    func staleTokenAccount(_ cli: CLIHome, _ label: String, week: Double) throws {
        #expect(try cli.run(["add", label]).status == 0)
        try cli.fake(
            "probe-for-\(label).jsonl",
            SignInSwitch.stream(week: week, days: 3, five: 0.1, hours: 1, now: Date()))
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", label]).status == 0)
        try SignInSwitch.storeOld(cli, label, age: 1_200, now: Date())
    }

    @Test func anEmailChangeHasSavedTheEmailAndDeletedTheReadingBeforeItsOwnCheck() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try SignInSwitch.storeOld(cli, "main", age: 60, now: Date())
        try cli.fakeFixture("wrong_account")
        try cli.fake("hold-auth", "")
        let change = SignInRace.started(
            cli, ["config", "set", "main", "email", "other@example.com"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-auth") })
        let saved = cli.read("config.json").contains("other@example.com")
        let gone = try SignInSwitch.store(cli).load(label: "main") == nil
        try cli.fake("go-auth", "")
        #expect(SignInRace.waitUntil { change.isDone })
        #expect(saved)
        #expect(gone)
        #expect(change.value?.status == 0)
    }

    @Test func anAddWaitsForAProbeOfARemovedAccountAndDeletesWhatItSaved() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let now = Date()
        try SignInSwitch.storeOld(cli, "main", age: 1_200, now: now)
        try SignInSwitch.reply(cli, week: 0.3, now: now)
        try cli.fake("hold-default", "")
        let refresh = SignInRace.started(cli, ["refresh", "--label", "main"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-default") })
        #expect(try cli.run(["remove", "main"]).status == 0)
        let add = SignInRace.started(cli, ["add", "main"])
        #expect(
            SignInRace.waitUntil {
                SignInRace.pickLockHeld(cli) || cli.read("config.json").contains("\"token\"")
            })
        try cli.fake("go-default", "")
        #expect(SignInRace.waitUntil { refresh.isDone && add.isDone })
        #expect(add.value?.status == 0)
        #expect(try SignInSwitch.store(cli).load(label: "main") == nil)
    }

    @Test func aRenameWaitsForAProbeOfARemovedAccountUnderItsNewLabel() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try staleTokenAccount(cli, "primary", week: 0.92)
        try SignInSwitch.storeOld(cli, "main", age: 60, now: Date())
        try cli.fake("hold-primary", "")
        let refresh = SignInRace.started(cli, ["refresh", "--label", "primary"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-primary") })
        #expect(try cli.run(["remove", "primary"]).status == 0)
        let rename = SignInRace.started(cli, ["config", "set", "main", "label", "primary"])
        #expect(
            SignInRace.waitUntil {
                SignInRace.pickLockHeld(cli) || cli.read("config.json").contains("\"primary\"")
            })
        try cli.fake("go-primary", "")
        #expect(SignInRace.waitUntil { refresh.isDone && rename.isDone })
        #expect(rename.value?.status == 0)
        // The renamed account's own reading, with nothing of the removed account's probe in it.
        #expect(try SignInSwitch.store(cli).load(label: "primary")?.sevenDay?.usedPercent == 10)
    }

    @Test func aRefreshThatWaitedForTheLockWhileTheEmailChangedChecksNothing() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let now = Date()
        try SignInSwitch.storeOld(cli, "main", age: 1_200, now: now)
        try SignInSwitch.reply(cli, week: 0.3, now: now)
        try staleTokenAccount(cli, "lab", week: 0.2)
        try cli.fake("hold-default", "")
        let first = SignInRace.started(cli, ["refresh", "--label", "main"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-default") })
        // A refresh of both accounts: its probe of `lab` shows it has read the registry, while
        // its check of `main` waits for the lock the first refresh holds.
        try cli.fake("hold-lab", "")
        let second = SignInRace.started(cli, ["refresh"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-lab") })
        let text = cli.read("config.json")
        try NoFollowWriter(root: cli.dataRoot).put(
            Data(text.replacingOccurrences(of: "main@example.com", with: "new@example.com").utf8),
            folders: [], name: ConfigStore.fileName)
        try cli.fake("go-default", "")
        try cli.fake("go-lab", "")
        #expect(SignInRace.waitUntil { first.isDone && second.isDone })
        let out = String(decoding: second.value?.stdout ?? Data(), as: UTF8.self)
        #expect(out.contains("main: not checked: the account changed while the check waited"))
        #expect(out.contains("lab: read"))
    }
}

extension TokenAccountsCLITests {
    @Test func anInitWaitsForAProbeOfARemovedAccountAndDeletesWhatItSaved() throws {
        let cli = try CLIHome()
        defer { cli.cleanup() }
        try cli.fakeFixture("logged_in")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: [])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        try addLab(cli, "main")
        try cli.fake(
            "probe-for-main.jsonl",
            SignInSwitch.stream(week: 0.92, days: 3, five: 0.1, hours: 1, now: Date()))
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "main"]).status == 0)
        try ageReading(cli, "main", by: 1_200)
        try cli.fake("hold-main", "")
        let refresh = SignInRace.started(cli, ["refresh", "--label", "main"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-main") })
        #expect(try cli.run(["remove", "main"]).status == 0)
        let started = SignInRace.started(cli, ["init", "--label", "main"])
        #expect(
            SignInRace.waitUntil {
                SignInRace.pickLockHeld(cli) || cli.read("config.json").contains("\"login\"")
            })
        try cli.fake("go-main", "")
        #expect(SignInRace.waitUntil { refresh.isDone && started.isDone })
        #expect(started.value?.status == 0)
        #expect(try SignInSwitch.store(cli).load(label: "main") == nil)
    }
}

import Foundation
import Testing

@testable import Core

private func shown(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// Runs a competing command on its own thread, as the race tests do.
private func onOwnThread(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.stackSize = 1 << 20
    thread.start()
}

/// What a command on another thread returned, once it has.
private final class Outcome: @unchecked Sendable {
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

private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

private func holdPickLock(_ cli: CLIHome) throws -> FileLock {
    let writer = NoFollowWriter(root: ToolContext(home: cli.home, ambient: [:]).dataRoot)
    return try #require(
        try writer.acquireLock(folders: Layout.locksFolders, name: Layout.pickLockName, wait: 5))
}

private func backupCount(_ cli: CLIHome) -> Int {
    let dir = cli.dataRoot.appendingPathComponent("backups")
    return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
}

/// Every writer of `config.json` saves under the pick lock, and an account keeps one end marker.
extension TokenAccountsCLITests {
    func store(_ cli: CLIHome) -> ConfigStore {
        ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
    }

    /// Puts `acct`, a token account with the given markers, in place of any earlier one.
    func placeAccount(_ cli: CLIHome, endsAt: String?, endingSoon: Bool?) throws {
        var config = try store(cli).loadRequired()
        config.accounts.removeAll { $0.label == "acct" }
        config.accounts.append(
            Account(
                label: "acct", kind: Kind.token, role: Role.pool, endsAt: endsAt,
                endingSoon: endingSoon))
        try store(cli).save(config)
    }

    /// The four marker states; the last only a config saved before the markers were exclusive
    /// can hold.
    static let markerStates: [(name: String, date: String?, soon: Bool?)] = [
        ("none", nil, nil), ("soon", nil, true), ("date", "2099-12-31", nil),
        ("both", "2099-12-31", true),
    ]

    @Test func eachEndMarkerFormFromEachStateLeavesOneMarker() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let day = "2099-11-30"
        // The form, and the markers it leaves from a state's date: date, then soon flag.
        let forms: [(args: [String], leaves: (String?) -> (String?, Bool?))] = [
            (["ends", day], { _ in (day, nil) }),
            (["ends", "none"], { _ in (nil, nil) }),
            (["ending-soon", "true"], { _ in (nil, true) }),
            (["ending-soon", "false"], { date in (date, nil) }),
        ]
        for state in Self.markerStates {
            for form in forms {
                try placeAccount(cli, endsAt: state.date, endingSoon: state.soon)
                let place = "\(state.name), \(form.args)"
                let out = try cli.runOnTerminal(["config", "set", "acct"] + form.args)
                #expect(out.status == 0, "\(place): \(shown(out.stderr))")
                #expect(
                    shown(out.stdout).hasPrefix("Updated \(form.args[0]) for 'acct'."), "\(place)")
                let account = try #require(try store(cli).loadRequired().account("acct"))
                let want = form.leaves(state.date)
                #expect(account.endsAt == want.0, "\(place)")
                #expect(account.endingSoon == want.1, "\(place)")
            }
        }
    }

    @Test func addWithBothEndMarkersIsRefusedAndWritesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let before = cli.read("config.json")
        let backups = backupCount(cli)
        let out = try cli.run(["add", "lab", "--ends", "2099-12-31", "--ending-soon"])
        #expect(out.status == 1)
        #expect(shown(out.stderr).contains("Use --ends or --ending-soon, not both"))
        #expect(cli.read("config.json") == before)
        #expect(backupCount(cli) == backups)
    }

    @Test func everyConfigSetFormWaitsForThePickLockAndNoChangeIsLost() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        var config = try store(cli).loadRequired()
        config.accounts += [
            Account(label: "t1", kind: Kind.token, role: Role.pool),
            Account(label: "t2", kind: Kind.token, role: Role.pool, endingSoon: true),
            Account(
                label: "t3", kind: Kind.token, role: Role.pool, endsAt: "2099-12-31",
                endingSoon: true),
            Account(label: "t4", kind: Kind.token, role: Role.pool, endsAt: "2099-12-31"),
            Account(
                label: "t5", kind: Kind.token, role: Role.pool, endsAt: "2099-12-31",
                endingSoon: true),
        ]
        try store(cli).save(config)
        let forms: [[String]] = [
            ["config", "set", "main", "label", "primary"],
            ["config", "set", "t1", "email", "t1@example.com"],
            ["config", "set", "t2", "ends", "2099-11-30"],
            ["config", "set", "t3", "ends", "none"],
            ["config", "set", "t4", "ending-soon", "true"],
            ["config", "set", "t5", "ending-soon", "false"],
            ["config", "set", "refresh.backgroundMinutes", "30"],
        ]
        let before = cli.read("config.json")
        let lock = try holdPickLock(cli)
        let outcomes = forms.map { _ in Outcome() }
        for (form, outcome) in zip(forms, outcomes) {
            onOwnThread { outcome.set(try? cli.runOnTerminal(form)) }
        }
        // Each form waits for the lock, so nothing is saved while a pick holds it.
        Thread.sleep(forTimeInterval: 1.5)
        #expect(cli.read("config.json") == before)
        #expect(outcomes.allSatisfy { !$0.isDone })
        lock.release()
        for (form, outcome) in zip(forms, outcomes) {
            #expect(waitUntil(60) { outcome.isDone }, "\(form)")
            #expect(outcome.value?.status == 0, "\(form)")
        }
        let after = try store(cli).loadRequired()
        #expect(after.account("primary")?.kind == Kind.login)
        #expect(after.account("main") == nil)
        #expect(after.account("t1")?.email == "t1@example.com")
        #expect(after.account("t2")?.endsAt == "2099-11-30")
        #expect(after.account("t2")?.endingSoon == nil)
        #expect(after.account("t3")?.endsAt == nil)
        #expect(after.account("t3")?.endingSoon == nil)
        #expect(after.account("t4")?.endsAt == nil)
        #expect(after.account("t4")?.endingSoon == true)
        #expect(after.account("t5")?.endsAt == "2099-12-31")
        #expect(after.account("t5")?.endingSoon == nil)
        #expect(after.refresh.backgroundMinutes == 30)
    }

    @Test func aConfigSetAndAnAddRacingOnTheirOwnThreadsBothSurvive() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        for round in 1...2 {
            let label = "racer\(round)"
            let day = "2099-12-1\(round)"
            let before = cli.read("config.json")
            let lock = try holdPickLock(cli)
            let set = Outcome()
            let add = Outcome()
            onOwnThread { set.set(try? cli.runOnTerminal(["config", "set", "main", "ends", day])) }
            onOwnThread { add.set(try? cli.runOnTerminal(["add", label])) }
            Thread.sleep(forTimeInterval: 1)
            // Both wait for the same lock, so neither saves over the other.
            #expect(cli.read("config.json") == before, "round \(round)")
            lock.release()
            #expect(waitUntil(60) { set.isDone && add.isDone }, "round \(round)")
            #expect(set.value?.status == 0, "round \(round)")
            #expect(add.value?.status == 0, "round \(round)")
            let after = try store(cli).loadRequired()
            #expect(after.account(label)?.kind == Kind.token, "round \(round)")
            #expect(after.account("main")?.endsAt == day, "round \(round)")
        }
    }

    @Test func aRenameWaitsWhileAPickHoldsTheLock() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let lock = try holdPickLock(cli)
        let rename = Outcome()
        onOwnThread {
            rename.set(try? cli.runOnTerminal(["config", "set", "main", "label", "primary"]))
        }
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!rename.isDone)
        #expect(try store(cli).loadRequired().account("main") != nil)
        lock.release()
        #expect(waitUntil(60) { rename.isDone })
        #expect(rename.value?.status == 0)
        #expect(try store(cli).loadRequired().account("primary") != nil)
    }

    @Test func aRenameRacingARemoveNeverRemovesTheMainAccount() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = try store(cli).loadRequired()
        config.accounts[0].role = Role.main
        config.accounts[0].reserve = .standard
        config.accounts.append(Account(label: "spare", kind: Kind.folder, role: Role.pool))
        try store(cli).save(config)
        let mainKey = config.accounts[0].accountKey
        let renames = Outcome()
        let loaded = try store(cli).loadRequired()
        // `remove spare` checks the role under the pick lock, then two renames try to swap the
        // labels before its entry goes: spare to spare2, then the main account to spare.
        _ = try? TokenAccounts.removeAccount(context: context, label: "spare", config: loaded) {
            fresh in
            guard fresh?.account("spare")?.role == Role.pool else {
                throw ToolError("Needs a terminal.")
            }
            onOwnThread {
                _ = try? cli.runOnTerminal(["config", "set", "spare", "label", "spare2"])
                renames.set(try? cli.runOnTerminal(["config", "set", "main", "label", "spare"]))
            }
            _ = waitUntil(3) { renames.isDone }
        }
        #expect(waitUntil(60) { renames.isDone })
        let after = try store(cli).loadRequired()
        #expect(after.accounts.contains { $0.accountKey == mainKey && $0.role == Role.main })
    }

    @Test func initWaitsForThePickLock() throws {
        let cli = try CLIHome()
        defer { cli.cleanup() }
        try cli.fakeFixture("logged_in")
        let lock = try holdPickLock(cli)
        let registered = Outcome()
        onOwnThread { registered.set(try? cli.run(["init", "--label", "main"])) }
        // init checks the sign-in and the label first, then waits for the lock to save.
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!registered.isDone)
        #expect(cli.read("config.json").isEmpty)
        lock.release()
        #expect(waitUntil(60) { registered.isDone })
        #expect(registered.value?.status == 0)
        #expect(try store(cli).loadRequired().loginAccount?.label == "main")
    }

    // MARK: The window's end choice against the real tool

    @Test @MainActor func eachEndChoiceFromEachMarkerStateRunsOneRealCommandAndLeavesOneMarker()
        async throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        // The app runs the tool at a fixed path; this one logs each call, then runs the real one.
        let wrapper = cli.home.appendingPathComponent("app-bin/agent-balancer")
        let log = cli.home.appendingPathComponent("app-calls.log")
        try FileManager.default.createDirectory(
            at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            echo "$*" >> "\(log.path)"
            exec "\(cli.exe.path)" "$@"
            """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let day = Self.localDay(Date().addingTimeInterval(30 * 86_400))
        let choices: [(EndChoice, String?, Bool?)] = [
            (.never, nil, nil), (.soon, nil, true), (.on(day), day, nil),
        ]
        for state in Self.markerStates {
            for (choice, date, soon) in choices {
                let place = "\(state.name) to \(choice)"
                try placeAccount(cli, endsAt: state.date, endingSoon: state.soon)
                _ = try StatusBuilder.rebuild(context: context)
                try? FileManager.default.removeItem(at: log)
                let vm = ManageViewModel(
                    context: context, runner: CLIRunner(context: context, candidates: [wrapper]))
                await vm.changeEnds(label: "acct", to: choice)
                let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                    .split(separator: "\n")
                #expect(calls.count == 1, "\(place)")
                #expect(vm.bar?.ok == true, "\(place)")
                let account = try #require(try store(cli).loadRequired().account("acct"))
                #expect(account.endsAt == date, "\(place)")
                #expect(account.endingSoon == soon, "\(place)")
            }
        }
    }
}

/// The role commands wait for the pick lock too, and a refused remove of a folder account keeps
/// its link record.
extension TokenAccountsCLITests {
    @Test func setMainAndClearMainWaitForThePickLock() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        for (args, role) in [
            (["config", "set-main", "main"], Role.main),
            (["config", "clear-main", "main"], Role.pool),
        ] {
            let before = cli.read("config.json")
            let lock = try holdPickLock(cli)
            let change = Outcome()
            onOwnThread { change.set(try? cli.runOnTerminal(args)) }
            Thread.sleep(forTimeInterval: 1.5)
            #expect(!change.isDone, "\(args)")
            #expect(cli.read("config.json") == before, "\(args)")
            lock.release()
            #expect(waitUntil(60) { change.isDone }, "\(args)")
            #expect(change.value?.status == 0, "\(args)")
            #expect(try store(cli).loadRequired().account("main")?.role == role, "\(args)")
        }
    }

    @Test @MainActor func aFailedEndChangeLeavesTheStoredMarkersAsTheyWere() async throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        try placeAccount(cli, endsAt: "2099-12-31", endingSoon: true)
        _ = try StatusBuilder.rebuild(context: context)
        // A backups folder that is a link stops every config save before it writes.
        let outside = cli.home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cli.dataRoot.appendingPathComponent("backups"), withDestinationURL: outside)
        let before = cli.read("config.json")
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [cli.exe]))
        for choice in [EndChoice.never, .soon, .on("2099-11-30")] {
            await vm.changeEnds(label: "acct", to: choice)
            #expect(vm.bar?.ok == false, "\(choice)")
            #expect(cli.read("config.json") == before, "\(choice)")
        }
        let account = try #require(try store(cli).loadRequired().account("acct"))
        #expect(account.endsAt == "2099-12-31")
        #expect(account.endingSoon == true)
    }
}

extension FolderAccountsCLITests {
    @Test func aRoleChangeSavedWhileAFolderRemoveWaitsIsSeenAndItsLinksAreKept() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let links = cli.read("links.json")
        #expect(links.contains("spare"))
        let lock = try holdPickLock(cli)
        let outcome = Outcome()
        onOwnThread { outcome.set(try? cli.run(["remove", "spare"])) }
        // The remove passes its first check, a pool account then, and waits for the lock.
        Thread.sleep(forTimeInterval: 2)
        // What `config set-main spare` saves, under the same lock.
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "spare" })
        config.accounts[index].role = Role.main
        config.accounts[index].reserve = .standard
        try store.save(config, backup: true)
        lock.release()
        #expect(waitUntil(60) { outcome.isDone })
        #expect(outcome.value?.status == 1)
        let refusal = shown(outcome.value?.stderr ?? Data())
        #expect(refusal.contains(Messages.removeMainNeedsTerminal("spare")))
        #expect(cli.read("links.json") == links)
        #expect(try store.loadRequired().account("spare")?.role == Role.main)
    }
}

extension TokenAccountsCLITests {
    @Test func aRemoveStopsWhenTheLabelNamesAnotherAccountOnceItHasTheLock() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        var config = try store(cli).loadRequired()
        config.accounts += [
            Account(label: "spare", kind: Kind.folder, role: Role.pool),
            Account(label: "other", kind: Kind.folder, role: Role.pool),
        ]
        try store(cli).save(config)
        let lock = try holdPickLock(cli)
        let outcome = Outcome()
        onOwnThread { outcome.set(try? cli.run(["remove", "spare"])) }
        // The remove reads `spare` and waits for the lock.
        Thread.sleep(forTimeInterval: 2)
        // Renames saved before it gets the lock: spare to spare2, then other to spare.
        var swapped = try store(cli).loadRequired()
        let spare = try #require(swapped.accounts.firstIndex { $0.label == "spare" })
        let other = try #require(swapped.accounts.firstIndex { $0.label == "other" })
        swapped.accounts[spare].label = "spare2"
        swapped.accounts[other].label = "spare"
        try store(cli).save(swapped, backup: true)
        let before = cli.read("config.json")
        lock.release()
        #expect(waitUntil(60) { outcome.isDone })
        #expect(outcome.value?.status == 1)
        let refusal = shown(outcome.value?.stderr ?? Data())
        #expect(refusal.contains("changed while remove waited, so nothing was changed"))
        #expect(cli.read("config.json") == before)
    }
}

import Foundation
import Testing

@testable import Core

private func shown(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// Every file under the data folder with its bytes. A difference prints byte counts only.
private func dataFiles(_ cli: CLIHome) -> [String: Data] {
    var out: [String: Data] = [:]
    for url in cli.dataEntries() {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            out[url.path] = Data()
        } else {
            out[url.path] = (try? Data(contentsOf: url)) ?? Data("unreadable".utf8)
        }
    }
    return out
}

/// Runs a competing command on its own thread, as the race tests do.
private func onOwnThread(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.stackSize = 1 << 20
    thread.start()
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Support.Output?
    let done = DispatchSemaphore(value: 0)

    func set(_ value: Support.Output?) {
        lock.lock()
        stored = value
        lock.unlock()
        done.signal()
    }

    var value: Support.Output? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func holdPickLock(_ cli: CLIHome) throws -> FileLock {
    let writer = NoFollowWriter(root: ToolContext(home: cli.home, ambient: [:]).dataRoot)
    return try #require(
        try writer.acquireLock(folders: Layout.locksFolders, name: Layout.pickLockName, wait: 5))
}

private func labels(_ cli: CLIHome) throws -> [String] {
    let data = Data(cli.read("config.json").utf8)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let accounts = try #require(object["accounts"] as? [[String: Any]])
    return accounts.compactMap { $0["label"] as? String }
}

/// `remove` of a main account keeps its typed consent in a terminal: with no terminal it refuses
/// and changes nothing, from any caller, the menu app included.
extension TokenAccountsCLITests {
    /// A signed-in token account with a launch file from a pick.
    func signedInLab(_ cli: CLIHome, _ label: String = "lab") throws {
        try addLab(cli, label)
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        let login = try cli.run(["login", label])
        #expect(login.status == 0, "\(shown(login.stderr))")
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        #expect(pick.status == 0, "\(shown(pick.stderr))")
    }

    func launchFileCount(_ cli: CLIHome) -> Int {
        let root = LaunchFiles.rootURL(context: ToolContext(home: cli.home, ambient: [:]))
            .resolvingSymlinksInPath().path
        return cli.dataEntries().filter { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return url.resolvingSymlinksInPath().path.hasPrefix(root + "/") && !isDir.boolValue
        }.count
    }

    @Test func removingTheMainAccountWithNoTerminalRefusesAndChangesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try signedInLab(cli)
        #expect(try cli.run(["config", "set-main", "lab"]).status == 0)
        let token = try tokenFile(cli, "lab")
        #expect(FileManager.default.fileExists(atPath: token.path))
        #expect(launchFileCount(cli) > 0)
        let before = dataFiles(cli)

        // A pipe is not a person at a terminal, and the menu app runs the tool the same way.
        let piped = try cli.run(["remove", "lab"], stdin: "lab\n")
        #expect(piped.status == 1)
        #expect(shown(piped.stderr).contains(Messages.removeMainNeedsTerminal("lab")))
        #expect(shown(piped.stderr).contains("`agent-balancer remove lab` in Terminal"))
        #expect(dataFiles(cli) == before)
        #expect(try labels(cli).contains("lab"))
        #expect(FileManager.default.fileExists(atPath: token.path))

        // The same command on a terminal removes it as before.
        let typed = try cli.runOnTerminal(["remove", "lab"])
        #expect(typed.status == 0, "\(shown(typed.stderr))")
        #expect(shown(typed.stdout).contains("Removed 'lab'."))
        #expect(try !labels(cli).contains("lab"))
        #expect(!FileManager.default.fileExists(atPath: token.path))
    }

    @Test func removingTheMainAccountRefusesAtOnceWhileAPickHoldsTheLock() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try signedInLab(cli)
        #expect(try cli.run(["config", "set-main", "lab"]).status == 0)
        let lock = try holdPickLock(cli)
        defer { lock.release() }
        let started = Date()
        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 1)
        #expect(shown(out.stderr).contains(Messages.removeMainNeedsTerminal("lab")))
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test func aRoleChangeSavedWhileRemoveWaitsForTheLockIsSeenAndNothingIsDeleted() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try signedInLab(cli)
        let context = ToolContext(home: cli.home, ambient: [:])
        let token = try tokenFile(cli, "lab")
        let lock = try holdPickLock(cli)
        defer { lock.release() }
        let outcome = Outcome()
        onOwnThread { outcome.set(try? cli.run(["remove", "lab"])) }
        // The remove passes its first check, a pool account then, and waits for the lock.
        Thread.sleep(forTimeInterval: 2)
        // What `config set-main lab` saves, under the same lock.
        let store = ConfigStore(context: context)
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "lab" })
        config.accounts[index].role = Role.main
        config.accounts[index].reserve = .standard
        try store.save(config, backup: true)
        lock.release()
        #expect(outcome.done.wait(timeout: .now() + 60) == .success)
        let out = try #require(outcome.value)
        #expect(out.status == 1)
        #expect(shown(out.stderr).contains(Messages.removeMainNeedsTerminal("lab")))
        #expect(try labels(cli).contains("lab"))
        #expect(FileManager.default.fileExists(atPath: token.path))
    }

    @Test func aPoolAccountIsRemovedWithNoTerminalAsBefore() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try signedInLab(cli)
        let token = try tokenFile(cli, "lab")
        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 0, "\(shown(out.stderr))")
        #expect(shown(out.stdout).contains("Removed 'lab'."))
        #expect(try !labels(cli).contains("lab"))
        #expect(!FileManager.default.fileExists(atPath: token.path))
    }

    @Test func anAccountMadeMainAfterARefusalIsStillRefusedAndClearMainLetsItGo() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try signedInLab(cli)
        #expect(try cli.run(["config", "set-main", "lab"]).status == 0)
        #expect(try cli.run(["remove", "lab"]).status == 1)
        #expect(try cli.run(["config", "clear-main", "lab"]).status == 0)
        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 0, "\(shown(out.stderr))")
        #expect(try !labels(cli).contains("lab"))
    }
}

extension FolderAccountsCLITests {
    @Test func removingAMainFolderAccountWithNoTerminalRefusesAndChangesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        #expect(try cli.run(["config", "set-main", "spare"]).status == 0)
        let before = try world(cli)
        let piped = try cli.run(["remove", "spare"], stdin: "spare\n")
        #expect(piped.status == 1)
        #expect(shown(piped.stderr).contains(Messages.removeMainNeedsTerminal("spare")))
        #expect(try world(cli) == before)
        #expect(cli.read("links.json").contains("spare"))

        let typed = try cli.runOnTerminal(["remove", "spare"])
        #expect(typed.status == 0, "\(shown(typed.stderr))")
        #expect(try !labels(cli).contains("spare"))
    }
}

/// A `remove` waiting on the pick lock finishes when another `remove` of the same label went
/// first, and stops with nothing deleted when the label names another account by then.
extension TokenAccountsCLITests {
    @Test func aRemoveThatLosesTheRaceToAnotherRemoveOfTheLabelStillFinishes() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try signedInLab(cli)
        let token = try tokenFile(cli, "lab")
        let lock = try holdPickLock(cli)
        defer { lock.release() }
        let first = Outcome()
        let second = Outcome()
        onOwnThread { first.set(try? cli.run(["remove", "lab"])) }
        onOwnThread { second.set(try? cli.run(["remove", "lab"])) }
        // Both read `lab` and wait for the lock; one removes it while the other still waits.
        Thread.sleep(forTimeInterval: 2)
        lock.release()
        for outcome in [first, second] {
            #expect(outcome.done.wait(timeout: .now() + 60) == .success)
            let out = try #require(outcome.value)
            #expect(out.status == 0, "\(shown(out.stderr))")
            #expect(shown(out.stdout).contains("Removed 'lab'."))
        }
        #expect(try !labels(cli).contains("lab"))
        #expect(!FileManager.default.fileExists(atPath: token.path))
    }

    @Test func aRemoveThatFindsAnotherAccountUnderTheLabelStopsAndDeletesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try signedInLab(cli)
        let token = try tokenFile(cli, "lab")
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        let key = try #require(try store.loadRequired().account("lab")?.accountKey)
        let lock = try holdPickLock(cli)
        defer { lock.release() }
        let outcome = Outcome()
        onOwnThread { outcome.set(try? cli.run(["remove", "lab"])) }
        // The remove reads `lab` and waits for the lock.
        Thread.sleep(forTimeInterval: 2)
        // Meanwhile `lab` was removed and added again: another account under the same label.
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "lab" })
        config.accounts[index] = Account(label: "lab", kind: Kind.token, role: Role.pool)
        try store.save(config, backup: true)
        #expect(try store.loadRequired().account("lab")?.accountKey != key)
        let before = dataFiles(cli)
        let launchFiles = launchFileCount(cli)
        #expect(launchFiles > 0)
        lock.release()
        #expect(outcome.done.wait(timeout: .now() + 60) == .success)
        let out = try #require(outcome.value)
        #expect(out.status == 1)
        #expect(shown(out.stderr).contains("changed while remove waited, so nothing was changed"))
        #expect(dataFiles(cli) == before)
        #expect(FileManager.default.fileExists(atPath: token.path))
        #expect(launchFileCount(cli) == launchFiles)
    }
}

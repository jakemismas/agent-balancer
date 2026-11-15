import Core
import Foundation
import Testing

@testable import Core

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

/// The `main` row of the status `init` wrote.
private func mainRow(_ h: CLIHome) throws -> [String: Any] {
    let data = Data(h.read("state/status.json").utf8)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let accounts = try #require(object["accounts"] as? [[String: Any]])
    return try #require(accounts.first { $0["label"] as? String == "main" })
}

/// `init` records its sign-in check for the email it registered, so a check of that email
/// gives no plan or expiry to an account whose email changed before the status was rebuilt.
extension AccountsCLITests {
    @Test func initsCheckGivesTheAccountItRegisteredItsPlanAndExpiry() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let out = try h.run(["init", "--label", "main"])
        #expect(out.status == 0)
        let row = try mainRow(h)
        #expect(row["email"] as? String == "main@example.com")
        #expect(row["planTier"] as? String == "max_20x")
        #expect(row["loginExpiresAt"] as? String == "2099-01-01T00:00:00Z")
    }

    @Test func initsCheckGivesNoPlanToAnEmailChangedBeforeItsRebuild() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let context = ToolContext(home: h.home, ambient: [:])
        let store = ConfigStore(context: context)
        // The rebuild waits for this lock, so the email changes after the save and before it.
        let lock = try #require(
            try NoFollowWriter(root: context.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: StatusBuilder.lockName, wait: 5))
        let outcome = Outcome()
        defer {
            lock.release()
            _ = waitUntil(60) { outcome.isDone }
        }
        onOwnThread { outcome.set(try? h.run(["init", "--label", "main"])) }
        try #require(waitUntil(60) { ((try? store.load()) ?? nil)?.account("main") != nil })
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "main" })
        #expect(config.accounts[index].email == "main@example.com")
        config.accounts[index].email = "other@example.com"
        try store.save(config)
        lock.release()
        #expect(waitUntil(60) { outcome.isDone })
        #expect(outcome.value?.status == 0)

        let row = try mainRow(h)
        #expect(row["email"] as? String == "other@example.com")
        #expect(row["planTier"] is NSNull && row["loginExpiresAt"] is NSNull)
    }
}

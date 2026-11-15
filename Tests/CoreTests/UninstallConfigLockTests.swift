import Foundation
import Testing

@testable import Core

/// `uninstall` deletes `config.json` only once it holds the pick lock, which every command that
/// saves the config takes, so a save made under that lock is never deleted part way.
extension UninstallTests {
    @Test func theConfigStaysWhileThePickLockIsHeldAndGoesOnceUninstallTakesIt() throws {
        let (t, _) = try setUp()
        let config = t.context.dataRoot.appendingPathComponent(ConfigStore.fileName)
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 1))
        let context = t.context
        let finished = DispatchSemaphore(value: 0)
        let outcome = Box<Uninstall.Result>()
        onOwnThread {
            outcome.value = try? Uninstall.run(context: context, leaseMinutes: 30, snapshot: .empty)
            finished.signal()
        }
        // The run waits for the lock, and the config is there for as long as it is held.
        #expect(finished.wait(timeout: .now() + 0.5) == .timedOut)
        #expect(exists(config))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(exists(config))
        held.release()
        #expect(finished.wait(timeout: .now() + 40) == .success)
        let done = try #require(outcome.value)
        #expect(done.tokenFiles == 1)
        #expect(!exists(config))
    }
}

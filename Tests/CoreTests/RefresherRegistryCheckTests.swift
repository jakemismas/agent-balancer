import Foundation
import Testing

@testable import Core

/// A refresh made from a registry read before a command changed the sign-in a label stands for
/// probes only while the saved registry still holds the same account under that label.
extension RefresherTests {
    @Test func aProbeRunsOnlyWhileTheSavedRegistryHoldsTheSameAccountUnderItsLabel() throws {
        let account = login()
        var renamed = account
        renamed.label = "primary"
        var emailed = account
        emailed.email = "other@example.com"
        var cased = account
        cased.email = "Main@Example.COM"
        let replaced = Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com")
        for (saved, runs) in [
            (emailed, false), (renamed, false), (replaced, false), (cased, true),
        ] {
            let t = try setUp()
            try ConfigStore(context: t.context).save(Config(accounts: [saved]))
            let r = refresher(t, accounts: [account], clock: ClockBox(Self.start)) {
                $0.fable.probe = false
            }
            let result = r.refresh(account: account, force: true)
            let probes = t.fakeLines("args.log").filter { $0.hasPrefix("-p") }
            if runs {
                guard case .probed = result.status else {
                    Issue.record("\(saved.label) \(saved.email ?? ""): expected a probe")
                    continue
                }
                #expect(probes.count == 1)
            } else {
                guard case .notStarted = result.status else {
                    Issue.record("\(saved.label) \(saved.email ?? ""): expected no probe")
                    continue
                }
                #expect(probes.isEmpty, "\(saved.label)")
                #expect(try ReadingStore(context: t.context).load(label: "main") == nil)
            }
        }
    }
}

extension RefresherTests {
    @Test func aProbeRunsNotWhenTheSavedRegistryHasAnotherKindOrCannotBeRead() throws {
        let account = login()
        var kinded = account
        kinded.kind = Kind.token
        for unreadable in [false, true] {
            let t = try setUp()
            if unreadable {
                try NoFollowWriter(root: t.context.dataRoot).put(
                    Data("{".utf8), folders: [], name: ConfigStore.fileName)
            } else {
                try ConfigStore(context: t.context).save(Config(accounts: [kinded]))
            }
            let r = refresher(t, accounts: [account], clock: ClockBox(Self.start)) {
                $0.fable.probe = false
            }
            let result = r.refresh(account: account, force: true)
            guard case .notStarted = result.status else {
                Issue.record("unreadable \(unreadable): expected no probe")
                continue
            }
            #expect(t.fakeLines("args.log").filter { $0.hasPrefix("-p") }.isEmpty)
        }
    }

    /// How many open descriptors of this process name the lock file of `label` under `t`.
    static func lockHolders(_ t: TestHome, _ label: String) -> Int {
        let home = t.home.lastPathComponent
        let name = Layout.lockName(label)
        var count = 0
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in 0..<Int32(min(Int(getdtablesize()), 4_096)) {
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            if path.contains(home) && path.hasSuffix("/" + name) { count += 1 }
        }
        return count
    }

    @Test func aRefreshChecksTheRegistryOnlyOnceItHoldsTheProbeLock() throws {
        let account = login()
        let t = try setUp()
        try ConfigStore(context: t.context).save(Config(accounts: [account]))
        var r = refresher(t, accounts: [account], clock: ClockBox(Self.start)) {
            $0.fable.probe = false
        }
        r.lockWaitSeconds = 300
        let writer = NoFollowWriter(root: t.context.dataRoot)
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.lockName("main"), wait: 0))
        let outcome = RefreshOutcome()
        let refresher = r
        let thread = Thread { outcome.set(refresher.refresh(account: account, force: true)) }
        thread.stackSize = 1 << 20
        thread.start()
        // The refresh has opened the lock file, so it now waits for the lock the test holds.
        let end = Date().addingTimeInterval(300)
        while Self.lockHolders(t, "main") < 2 && Date() < end { usleep(20_000) }
        #expect(Self.lockHolders(t, "main") == 2)
        var emailed = account
        emailed.email = "other@example.com"
        try ConfigStore(context: t.context).save(Config(accounts: [emailed]))
        held.release()
        while outcome.value == nil && Date() < end { usleep(20_000) }
        guard case .notStarted? = outcome.value?.status else {
            Issue.record("expected no probe once the lock was free")
            return
        }
        #expect(t.fakeLines("args.log").filter { $0.hasPrefix("-p") }.isEmpty)
        #expect(try ReadingStore(context: t.context).load(label: "main") == nil)
    }
}

/// What a refresh on another thread returned, once it has.
final class RefreshOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AccountRefresh?

    func set(_ value: AccountRefresh) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: AccountRefresh? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

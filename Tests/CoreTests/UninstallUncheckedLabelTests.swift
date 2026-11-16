import Foundation
import Testing

@testable import Core

/// An entry where a label's folder belongs that `lstat` cannot check, such as a folder whose
/// access list denies its owner `readattr`, is counted among the entries `uninstall` does not
/// follow, as before, and also on its own, so its text does not call it a link.
extension UninstallTests {
    func denyAttributes(_ url: URL, _ on: Bool) throws {
        #expect(
            try chmodRun(
                on ? ["+a", NSUserName() + " deny readattr", url.path] : ["-N", url.path])
                == 0)
    }

    @Test func aLabelFolderThatCannotBeCheckedIsCountedOnItsOwnAndStillAsNotFollowed() throws {
        let (t, launch) = try setUp()
        let label = launch.deletingLastPathComponent()
        try denyAttributes(label, true)
        defer { try? denyAttributes(label, false) }
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(plan.launchEntriesNotFollowed == 1 && plan.launchEntriesUnchecked == 1)
        #expect(!plan.isEmpty)
        let done = try run(t)
        #expect(done.launchEntriesNotFollowed == 1 && done.launchEntriesUnchecked == 1)
        #expect(done.tokenFiles == 1 && done.entriesLeft == 0)
        try denyAttributes(label, false)
        #expect(exists(launch))
    }

    @Test func aLinkWhereALabelsFolderBelongsIsNotCountedAsUnchecked() throws {
        let (t, _) = try setUp()
        let elsewhere = t.home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: LaunchFiles.rootURL(context: t.context).appendingPathComponent("pool-b"),
            withDestinationURL: elsewhere)
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(plan.launchEntriesNotFollowed == 1 && plan.launchEntriesUnchecked == 0)
        let done = try run(t)
        #expect(done.launchEntriesNotFollowed == 1 && done.launchEntriesUnchecked == 0)
    }
}

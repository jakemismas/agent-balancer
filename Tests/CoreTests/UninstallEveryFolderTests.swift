import Foundation
import Testing

@testable import Core

/// Every folder of the tool's that fails the folder checks stops `uninstall` before anything
/// goes, with the folder and its fix, so no run reports success while it leaves the tool's files
/// in a folder it was refused; the named command, then a rerun, removes everything.
extension UninstallTests {
    func chmodTool(_ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = arguments
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// One file the tool writes in each of its folders, by that folder's name rule.
    func plantOwnFiles(_ t: TestHome) throws {
        _ = try plant(t, Layout.stateFolders, StatusBuilder.statusName)
        _ = try plant(t, Layout.readingsFolders, Layout.readingName("pool-a"))
        _ = try plant(t, ReadingHistory.folders, ReadingHistory.fileName("pool-a"))
        _ = try plant(t, Layout.logsFolders, Layout.logName)
        _ = try plant(t, Layout.backupsFolders, "config-2026-11-16.json")
        _ = try plant(t, Layout.probeFolders + [Layout.probeFolderPrefix + "0123456789abcdef"], "x")
    }

    /// What `uninstall` refuses with before it removes anything, or nil when it goes ahead.
    func uninstallRefusal(_ t: TestHome) -> String? {
        do {
            _ = try Uninstall.plan(context: t.context, leaseMinutes: 30)
            return nil
        } catch let error as ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test func eachFolderOfTheToolsWithAnInheritedAllowEntryStopsUninstallUntilItsCommandRuns()
        throws
    {
        let paths: [[String]] = [
            Layout.stateFolders, Layout.readingsFolders, ReadingHistory.folders,
            Layout.logsFolders, Layout.locksFolders, Layout.probeFolders,
            Layout.probeFolders + [Layout.probeFolderPrefix + "0123456789abcdef"],
            Layout.backupsFolders, [FolderPaths.accountsFolderName],
            Array(FolderPaths.folders(label: "spare").dropLast()),
            FolderPaths.folders(label: "spare"),
        ]
        for path in paths {
            let (t, _) = try setUp()
            defer { _ = chmodTool(["-R", "-N", t.home.path]) }
            try plantOwnFiles(t)
            let (link, _) = try listedLinks(t)
            let url = path.reduce(t.context.dataRoot) { $0.appendingPathComponent($1) }
            let before = tree(t.context.dataRoot)
            #expect(chmodTool(["+ai", "everyone allow read", url.path]) == 0, "\(path)")
            let place = (["~/.agent-balancer"] + path).joined(separator: "/")
            let said = try #require(uninstallRefusal(t), "\(path)")
            #expect(
                said
                    == "The folder `\(place)` has an access list that lets another user or group in, or that cannot be read, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod -N \(place)`, then run `agent-balancer uninstall` again.",
                "\(path)")
            #expect(throws: ToolError(said)) { _ = try run(t) }
            #expect(tree(t.context.dataRoot) == before, "\(path)")
            for command in chmodCommands(said, home: t.home) {
                #expect(chmodTool(command) == 0, "\(path): \(command)")
            }
            let done = try run(t)
            #expect(done.tokenFiles == 1 && done.launchFiles == 1, "\(path)")
            #expect(done.linksRemoved == 1 && !exists(link), "\(path)")
            for top in [
                Layout.stateFolders, Layout.logsFolders, Layout.backupsFolders,
                Layout.probeFolders, Layout.locksFolders,
            ] {
                let gone = t.context.dataRoot.appendingPathComponent(top[0])
                #expect(!exists(gone), "\(path): \(top[0])")
            }
            #expect(done.entriesLeft == 0, "\(path)")
        }
    }

    @Test func aFolderOfTheToolsWhoseListTheUserCannotReadStopsUninstallWithItsCommands() throws {
        for path in [Layout.stateFolders, Layout.backupsFolders, Layout.readingsFolders] {
            let (t, _) = try setUp()
            defer { _ = chmodTool(["-R", "-N", t.home.path]) }
            try plantOwnFiles(t)
            let url = path.reduce(t.context.dataRoot) { $0.appendingPathComponent($1) }
            let before = tree(t.context.dataRoot)
            #expect(chmodTool(["+a", NSUserName() + " deny readsecurity", url.path]) == 0)
            let place = (["~/.agent-balancer"] + path).joined(separator: "/")
            let said = try #require(uninstallRefusal(t), "\(path)")
            #expect(
                said
                    == Messages.uninstallFolderRefused("The folder", place, .cannotCheck),
                "\(path)")
            #expect(throws: ToolError(said)) { _ = try run(t) }
            #expect(chmodTool(["-N", url.path]) == 0)
            #expect(tree(t.context.dataRoot) == before, "\(path)")
            #expect(chmodTool(["+a", NSUserName() + " deny readsecurity", url.path]) == 0)
            for command in chmodCommands(said, home: t.home) {
                #expect(chmodTool(command) == 0, "\(path): \(command)")
            }
            let done = try run(t)
            #expect(done.tokenFiles == 1 && done.entriesLeft == 0, "\(path)")
            #expect(done.dataFolderRemoved, "\(path)")
        }
    }
}

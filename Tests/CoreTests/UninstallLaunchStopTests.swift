import Foundation
import Testing

@testable import Core

/// A launch file that `uninstall` cannot overwrite or delete, because an access list denies its
/// owner, a lock is set or its folder is not writable, stops the run before any token file goes
/// with a text that names the fix, and a rerun after that fix finishes the step. The text names
/// only the label folders that are real folders, so a link there and what it points to are left
/// alone.
extension UninstallTests {
    static let launchStop =
        "A launch file could not be cleared, so the token files were kept. On each label's folder in `~/.agent-balancer/"
        + LaunchFiles.folder
        + "/` that is not a link, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg` first on any of them that is locked. Then run `agent-balancer uninstall` again."

    /// Adds an access list entry on `url` that denies its owner `rights`.
    func denyOwner(_ rights: String, _ url: URL) throws {
        #expect(try chmodRun(["+a", NSUserName() + " deny " + rights, url.path]) == 0, "\(rights)")
    }

    func lock(_ url: URL) throws {
        #expect(try runNamedCapturing(["chflags", "uchg", url.path]).status == 0)
    }

    /// The names in `folder`, by name only, so nothing is followed.
    func names(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            .map { folder.appendingPathComponent($0) }
    }

    func isRealFolder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// What the stop text names: each label's folder in the launch folder that is not a link,
    /// and each file directly in those folders.
    func launchFolderEntries(_ t: TestHome) -> (folders: [URL], files: [URL]) {
        let folders = names(in: LaunchFiles.rootURL(context: t.context)).filter(isRealFolder)
        return (folders, folders.flatMap(names(in:)))
    }

    /// Clears what a test set on the launch folders, so the home can be removed.
    func clearLaunchFolders(_ t: TestHome) {
        let entries = names(in: LaunchFiles.rootURL(context: t.context))
        clearMarks(entries + entries.filter(isRealFolder).flatMap(names(in:)))
        for folder in entries.filter(isRealFolder) { chmod(folder.path, 0o700) }
    }

    /// The text `Uninstall.run` stops with, or nil once it finishes.
    func stopText(_ t: TestHome) -> String? {
        do {
            _ = try run(t)
            return nil
        } catch let error as ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    /// Does what the stop text says, on what it names. Returns how many files needed the
    /// command it names for Permission denied, or nil when it names no fix.
    @discardableResult
    func followLaunchStop(_ said: String, _ t: TestHome) throws -> Int? {
        guard let fix = namedFix(said) else { return nil }
        let (folders, files) = launchFolderEntries(t)
        return try follow(fix, folders: folders, files: files)
    }

    @Test func aLaunchFileThatCannotBeOverwrittenOrDeletedStopsWithItsFixAndARerunFinishes()
        throws
    {
        // An old launch file is deleted and a young one is overwritten with a tombstone; each
        // stop is an access list entry on the file or its folder, a lock, or a folder that is
        // not writable. A file whose list denies its owner `read` needs the plain `chmod -N`.
        let cases: [(young: Bool, onFolder: Bool, mark: String, denied: Int)] = [
            (false, false, "delete", 0), (false, true, "delete_child", 0),
            (false, false, "readattr", 0), (false, false, "read,readattr", 1),
            (false, true, "0500", 0), (false, false, "lock", 0), (false, true, "lock", 0),
            (false, false, "delete,lock", 0), (true, false, "delete", 0),
            (true, true, "delete_child", 0), (true, true, "add_file", 0),
            (true, false, "read,readattr", 1), (true, true, "0500", 0), (true, false, "lock", 0),
            (true, true, "lock", 0), (true, false, "delete,lock", 0),
        ]
        for item in cases {
            let name = "\(item.mark), young \(item.young), on the folder \(item.onFolder)"
            let (t, launch) = try setUp()
            defer { clearLaunchFolders(t) }
            if item.young {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: launch.path)
            }
            let target = item.onFolder ? launch.deletingLastPathComponent() : launch
            switch item.mark {
            case "0500": chmod(target.path, 0o500)
            case "lock": try lock(target)
            case "delete,lock":
                try denyOwner("delete", target)
                try lock(target)
            default: try denyOwner(item.mark, target)
            }
            guard let said = stopText(t) else {
                Issue.record("the run did not stop: \(name)")
                continue
            }
            #expect(said == Self.launchStop, "\(name)")
            #expect(exists(try tokenFile(t)), "\(name)")
            guard let denied = try followLaunchStop(said, t) else {
                Issue.record("the stop names no fix: \(name)")
                continue
            }
            #expect(denied == item.denied, "\(name)")
            let done = try run(t)
            #expect(done.tokenFiles == 1 && done.tokenFilesLeft == 0, "\(name)")
            #expect(done.launchFiles + done.launchFilesKept == 1, "\(name)")
            #expect(done.temporariesLeft == 0, "\(name)")
        }
    }

    @Test func aLaunchFileThatInheritsAnAccessListStopsWithItsFixAndARerunFinishes() throws {
        let (t, launch) = try setUp()
        defer { clearLaunchFolders(t) }
        // A launch file made after this inherits the entry, and so does a tombstone a run writes.
        try denyOwner("readattr,file_inherit,only_inherit", launch.deletingLastPathComponent())
        _ = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-0e0e0e0e", caller: .none)
        let said = try #require(stopText(t))
        #expect(said == Self.launchStop)
        #expect(exists(try tokenFile(t)))
        #expect(try followLaunchStop(said, t) == 0)
        let done = try run(t)
        #expect(done.tokenFiles == 1 && done.launchFilesKept == 1)
        #expect(stopText(t) == nil)
    }

    @Test func aTombstoneTemporaryAnInheritedDenialKeepsIsClearedWithTheStopOrLeftToItsOwnText()
        throws
    {
        // A person who runs the file command on hidden files too clears the temporary the failed
        // tombstone write left; one who types a glob, which skips them, meets the temporaries
        // text on the rerun, and the run after that finishes.
        for hidden in [true, false] {
            let (t, launch) = try setUp()
            defer { clearLaunchFolders(t) }
            let folder = launch.deletingLastPathComponent()
            // A young launch file, then an entry only files made later take: the tombstone's
            // temporary can be neither renamed nor deleted.
            try FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: launch.path)
            try denyOwner("delete,file_inherit,only_inherit", folder)
            let said = try #require(stopText(t), "hidden \(hidden)")
            #expect(said == Self.launchStop, "hidden \(hidden)")
            let left = names(in: folder).filter { $0.lastPathComponent.hasPrefix(".tmp-") }
            #expect(left.count == 1, "hidden \(hidden)")
            let fix = try #require(namedFix(said))
            let files = names(in: folder).filter {
                hidden || !$0.lastPathComponent.hasPrefix(".")
            }
            #expect(try follow(fix, folders: [folder], files: files) == 0)
            let done = try run(t)
            #expect(done.tokenFiles == 1 && done.launchFilesKept == 1, "hidden \(hidden)")
            #expect(done.temporariesLeft == (hidden ? 0 : 1), "hidden \(hidden)")
            if !hidden {
                let temporaries = try #require(namedFix(TokenAccounts.undeletedTemporariesText(1)))
                #expect(try follow(temporaries, folders: [folder], files: left) == 0)
                #expect(try run(t).temporariesLeft == 0)
            }
            #expect(names(in: folder).allSatisfy { !$0.lastPathComponent.hasPrefix(".tmp-") })
        }
    }

    @Test func theLaunchStopNamesOnlyRealLabelFoldersSoALinkedFolderKeepsItsModeAndLists()
        throws
    {
        let (t, launch) = try setUp()
        let shared = t.home.appendingPathComponent("shared")
        try FileManager.default.createDirectory(
            at: shared, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        let notes = shared.appendingPathComponent("notes.txt")
        try "mine".write(to: notes, atomically: false, encoding: .utf8)
        #expect(try chmodRun(["+a", "user:nobody deny list,search,readattr", shared.path]) == 0)
        #expect(try chmodRun(["+a", "user:nobody deny read", notes.path]) == 0)
        let link = LaunchFiles.rootURL(context: t.context).appendingPathComponent("pool-b")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        try denyOwner("delete", launch)
        defer {
            clearLaunchFolders(t)
            clearMarks([shared, notes])
        }
        let said = try #require(stopText(t))
        #expect(said == Self.launchStop)
        #expect(try followLaunchStop(said, t) == 0)
        // The folder commands also spare the link's folder when a person runs them on every
        // entry there, as a glob does, since `-h` acts on the link itself.
        let fix = try #require(namedFix(said))
        for entry in names(in: LaunchFiles.rootURL(context: t.context)) {
            for command in fix.folder {
                #expect(try runNamedCapturing(command + [entry.path]).status == 0)
            }
        }
        #expect(permissions(shared) == 0o755)
        #expect(hasAccessList(shared) && hasAccessList(notes))
        let done = try run(t)
        #expect(done.tokenFiles == 1 && done.launchEntriesNotFollowed == 1)
        #expect(isLink(link))
    }

    @Test func aLaunchFileTheWriterRefusesPartWayStopsWithTheStopTextAndARerunFinishes() throws {
        let (t, _) = try setUp()
        defer { clearLaunchFolders(t) }
        // Two young launch files; while the first one's tombstone is written, the second turns
        // into a link, so the writer refuses it with a text of its own.
        let first = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-5a5a5a5a", caller: .none)
        let second = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-5b5b5b5b", caller: .none)
        let elsewhere = t.home.appendingPathComponent("elsewhere.json")
        try "{}".write(to: elsewhere, atomically: false, encoding: .utf8)
        let swapped = Box<Bool>()
        NoFollowWriter.beforeRename.set(first.lastPathComponent) {
            guard swapped.value != true else { return }
            swapped.value = true
            try FileManager.default.removeItem(at: second)
            try FileManager.default.createSymbolicLink(at: second, withDestinationURL: elsewhere)
        }
        defer { NoFollowWriter.beforeRename.set(first.lastPathComponent, nil) }
        #expect(stopText(t) == Self.launchStop)
        #expect(swapped.value == true)
        NoFollowWriter.beforeRename.set(first.lastPathComponent, nil)
        #expect(exists(try tokenFile(t)))
        let done = try run(t)
        #expect(done.tokenFiles == 1 && done.tokenFilesLeft == 0)
        #expect(isLink(second))
    }
}

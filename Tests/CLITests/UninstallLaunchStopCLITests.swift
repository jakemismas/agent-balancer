import Core
import Foundation
import Testing

@testable import Core

private func output(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// What `uninstall` says when an access list, a lock or a folder mode keeps it from opening a
/// folder of the tool's, from clearing a launch file, from checking an entry where a label's
/// folder belongs, or from deleting a token file or a temporary: each text names commands that
/// clear the case, and once they have run as written on what the text names, a rerun finishes
/// or names what is left. The texts name only the label folders that are real folders, and `-h`
/// acts on a link itself, so a folder a link points to and its files keep their access lists.
extension PersonCommandsCLITests {
    static let launchStop =
        "A launch file could not be cleared, so the token files were kept. On each label's folder in `~/.agent-balancer/"
        + LaunchFiles.folder
        + "/` that is not a link, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg` first on any of them that is locked. Then run `agent-balancer uninstall` again."

    /// Adds an access list entry on `url` that denies its owner `rights`.
    func denyOwnerOf(_ url: URL, _ rights: String) throws {
        #expect(try runChmod(["+a", NSUserName() + " deny " + rights, url.path]) == 0, "\(rights)")
    }

    /// The entries directly in `folder`, by name only, or none when `folder` is not a real
    /// folder, so a link is never followed.
    func entries(in folder: URL) -> [URL] {
        var st = stat()
        guard lstat(folder.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Whether `url` has an access list, read without following a link.
    func holdsAccessList(_ url: URL) -> Bool {
        guard let list = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(list))
        return true
    }

    func launchRoot(_ cli: CLIHome) -> URL {
        LaunchFiles.rootURL(context: ToolContext(home: cli.home, ambient: [:]))
    }

    /// The label folders in the launch folder that are not a link, as the stop text names them.
    func realLabelFolders(_ cli: CLIHome) -> [URL] {
        entries(in: launchRoot(cli)).filter(isRealFolder)
    }

    func isRealFolder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Clears the flags and access lists a test set under the data folder, so the home can be
    /// removed.
    func clearAccessLists(_ cli: CLIHome) {
        let folders =
            [
                cli.dataRoot, cli.dataRoot.appendingPathComponent(TokenPaths.folderName),
                launchRoot(cli),
            ]
            + entries(in: launchRoot(cli))
        clearMarks(folders + folders.dropFirst().flatMap(entries(in:)))
    }

    /// Runs the stop text's fix as written on what it names: each real label folder and each
    /// file directly in it. Returns how many files needed the command for Permission denied.
    func followLaunchStop(_ shown: String, _ cli: CLIHome) throws -> Int? {
        guard let fix = namedFix(shown, "could not be cleared") else { return nil }
        let folders = realLabelFolders(cli)
        return try follow(fix, folders: folders, files: folders.flatMap(entries(in:)))
    }

    @Test func aLaunchFileAnAccessListKeepsFromBeingClearedStopsWithChmodHNAndARerunFinishes()
        throws
    {
        let names = [
            "readattr on the file", "delete on the file", "delete_child", "inherited",
            "read,readattr on the file", "locked",
        ]
        for (which, name) in names.enumerated() {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let launch = try #require(launchFiles(cli).first)
            let folder = launch.deletingLastPathComponent()
            switch which {
            case 0: try denyOwnerOf(launch, "readattr")
            case 1: try denyOwnerOf(launch, "delete")
            case 2: try denyOwnerOf(folder, "delete_child")
            case 3:
                // A launch file made after this inherits the entry, and so does a tombstone.
                try denyOwnerOf(folder, "readattr,file_inherit,only_inherit")
                _ = try cli.run(["run", "--print-command", "pool-a"])
            case 4: try denyOwnerOf(launch, "read,readattr")
            default: try lockEntry(launch)
            }
            let token = try TokenPaths.fileURL(
                context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
            let stopped = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(stopped.status == 1, "\(name)")
            #expect(output(stopped.stderr).contains("Error: " + Self.launchStop + "\n"), "\(name)")
            #expect(FileManager.default.fileExists(atPath: token.path), "\(name)")
            guard let denied = try followLaunchStop(output(stopped.stderr), cli) else {
                Issue.record("the stop names no fix: \(name)")
                continue
            }
            #expect(denied == (which == 4 ? 1 : 0), "\(name)")
            let again = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(again.status == 0, "\(name)")
            #expect(!output(again.stderr).contains("could not be cleared"), "\(name)")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(name)")
        }
    }

    @Test func theLaunchStopTypedAsWrittenLeavesALinkedFolderAndItsFileTheirModeAndLists() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        // A folder of the user's outside the data folder, linked where a label's folder belongs.
        let shared = cli.home.appendingPathComponent("shared")
        try FileManager.default.createDirectory(
            at: shared, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        let notes = shared.appendingPathComponent("notes.txt")
        try "mine".write(to: notes, atomically: false, encoding: .utf8)
        #expect(try runChmod(["+a", "user:nobody deny list,search,readattr", shared.path]) == 0)
        #expect(try runChmod(["+a", "user:nobody deny read", notes.path]) == 0)
        defer { clearMarks([shared, notes]) }
        let link = launchRoot(cli).appendingPathComponent("pool-b")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        try denyOwnerOf(launch, "delete")

        let stopped = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(stopped.status == 1)
        #expect(output(stopped.stderr).contains("Error: " + Self.launchStop + "\n"))
        #expect(try followLaunchStop(output(stopped.stderr), cli) == 0)
        // Its folder commands, `chmod -h 700` included, spare the link's folder even when a
        // person runs them on every entry there, as a glob does.
        let fix = try #require(namedFix(output(stopped.stderr), "could not be cleared"))
        for entry in entries(in: launchRoot(cli)) {
            for command in fix.folder {
                #expect(try runNamedCapturing(command + [entry.path]).status == 0)
            }
        }
        var st = stat()
        #expect(lstat(shared.path, &st) == 0 && st.st_mode & 0o777 == 0o755)
        #expect(holdsAccessList(shared) && holdsAccessList(notes))
        let again = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(again.status == 1)
        #expect(output(again.stdout).contains("\n" + LaunchFiles.notFollowedEntriesText(1) + "\n"))
        let token = try TokenPaths.fileURL(
            context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
        #expect(!FileManager.default.fileExists(atPath: token.path))
    }

    @Test func aFolderWhoseAccessListDeniesItsOwnerListIsRefusedWithCommandsThatEachRun() throws {
        for which in 0..<4 {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let typed = "~/.agent-balancer"
            let places: [(folder: URL, subject: String, place: String)] = [
                (cli.dataRoot, "The data folder", typed),
                (
                    cli.dataRoot.appendingPathComponent(TokenPaths.folderName), "The token folder",
                    typed + "/" + TokenPaths.folderName
                ),
                (launchRoot(cli), "The launch folder", typed + "/" + LaunchFiles.folder),
                (
                    launchRoot(cli).appendingPathComponent("pool-a"), "The launch folder",
                    typed + "/" + LaunchFiles.folder + "/pool-a"
                ),
            ]
            let item = places[which]
            try denyOwnerOf(item.folder, "list")
            let refused = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(refused.status == 1, "\(item.place)")
            let said = Messages.uninstallFolderRefused(item.subject, item.place, .cannotOpen)
            #expect(output(refused.stderr).contains("Error: " + said + "\n"), "\(item.place)")
            // Each command the text names, run as written: none opens the folder.
            let commands = namedCommands(output(refused.stderr), "cannot be opened", home: cli.home)
            #expect(commands.count == 2, "\(item.place)")
            for command in commands {
                #expect(try runNamedCapturing(command).status == 0, "\(item.place): \(command)")
            }
            let again = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(again.status == 0, "\(item.place)")
            let token = try TokenPaths.fileURL(
                context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(item.place)")
        }
    }

    @Test func anEntryThatCannotBeCheckedIsNamedWithAChmodThatSparesTheFolderALinkPointsTo()
        throws
    {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let shared = cli.home.appendingPathComponent("shared")
        try FileManager.default.createDirectory(
            at: shared, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        #expect(try runChmod(["+a", "user:nobody deny list,search,readattr", shared.path]) == 0)
        try NoFollowWriter(root: cli.dataRoot).prepare(folders: [LaunchFiles.folder])
        let link = launchRoot(cli).appendingPathComponent("pool-b")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        // An entry on the link itself, so `lstat` cannot check it.
        #expect(try runChmod(["-h", "+a", NSUserName() + " deny readattr", link.path]) == 0)
        defer {
            _ = try? runChmod(["-h", "-N", link.path])
            _ = try? runChmod(["-N", shared.path])
        }

        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 1)
        #expect(output(done.stdout).contains(Self.saidUnchecked(1)))
        #expect(try followUncheckedText(output(done.stdout), launchRoot(cli)) == 0)
        // The folder the link points to keeps its access list, and the rerun names the link.
        #expect(holdsAccessList(shared))
        let again = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(again.status == 1)
        #expect(output(again.stdout).contains("\n" + LaunchFiles.notFollowedEntriesText(1) + "\n"))
        #expect(!output(again.stdout).contains("could not be checked"))
    }

    @Test func aTokenFolderWhoseAccessListDeniesDeleteIsNamedWithChmodHNAndARerunDeletesItsFile()
        throws
    {
        for mark in ["delete_child", "lock", "lock on the file"] {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            let file = try TokenPaths.fileURL(
                context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
            let folder = file.deletingLastPathComponent()
            switch mark {
            case "delete_child": try denyOwnerOf(folder, "delete_child")
            case "lock": try lockEntry(folder)
            default: try lockEntry(file)
            }
            let done = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(done.status == 1, "\(mark)")
            #expect(output(done.stdout).contains("\n" + Self.tokenText(1) + "\n"), "\(mark)")
            let fix = try #require(namedFix(output(done.stdout), "token files could not"))
            #expect(try follow(fix, folders: [folder], files: entries(in: folder)) == 0)
            let again = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(again.status == 0, "\(mark)")
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(mark)")
        }
    }

    @Test func aTokenFolderWhoseAccessListDeniesDeleteKeepsATemporaryUntilTheNamedChmodRuns()
        throws
    {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        let file = try TokenPaths.fileURL(
            context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
        let folder = file.deletingLastPathComponent()
        // What a token write stopped before its rename leaves: the whole file under a temporary name.
        let temporary = folder.appendingPathComponent(".tmp-0123456789abcdef")
        try FileManager.default.moveItem(at: file, to: temporary)
        try denyOwnerOf(folder, "delete_child")
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 1)
        #expect(output(done.stdout).contains("\n" + Self.temporariesText(1) + "\n"))
        let fix = try #require(namedFix(output(done.stdout), "temporary files could not"))
        #expect(try follow(fix, folders: [folder], files: [temporary]) == 0)
        let again = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(again.status == 0)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func theTemporariesTextNamesOnlyRealLabelFoldersSoALinkedFolderKeepsItsLists() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let shared = cli.home.appendingPathComponent("shared")
        try FileManager.default.createDirectory(
            at: shared, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        let notes = shared.appendingPathComponent(".tmp-00000000000000aa")
        try "mine".write(to: notes, atomically: false, encoding: .utf8)
        #expect(try runChmod(["+a", "user:nobody deny read", notes.path]) == 0)
        defer { clearMarks([notes]) }
        try FileManager.default.createSymbolicLink(
            at: launchRoot(cli).appendingPathComponent("pool-b"), withDestinationURL: shared)
        // A temporary a launch write left in pool-a's folder, which an access list keeps.
        let label = launchRoot(cli).appendingPathComponent("pool-a")
        let temporary = label.appendingPathComponent(".tmp-0123456789abcdef")
        try "{}".write(to: temporary, atomically: false, encoding: .utf8)
        try denyOwnerOf(temporary, "delete")
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 1)
        #expect(output(done.stdout).contains("\n" + Self.temporariesText(1) + "\n"))
        let fix = try #require(namedFix(output(done.stdout), "temporary files could not"))
        // The folders that hold one and are not a link: pool-a's, and not the link's.
        let holders = realLabelFolders(cli).filter { folder in
            entries(in: folder).contains { $0.lastPathComponent.hasPrefix(".tmp-") }
        }
        #expect(holders.map(\.lastPathComponent) == ["pool-a"])
        let files = holders.flatMap(entries(in:)).filter {
            $0.lastPathComponent.hasPrefix(".tmp-")
        }
        #expect(try follow(fix, folders: holders, files: files) == 0)
        #expect(holdsAccessList(notes))
        let again = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(again.status == 1)
        #expect(!output(again.stdout).contains("temporary files could not"))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }
}

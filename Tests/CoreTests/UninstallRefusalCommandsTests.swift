import Foundation
import Testing

@testable import Core

/// What the folder refusals and the temporaries text name, run as written. A real folder that
/// cannot be opened or searched is named with `chmod -N` and `chmod 700`, which do not open it. A
/// folder `lstat` cannot check is named with `chmod -h -N`, which acts on a link itself but opens
/// the entry, so the text names `chmod -N` for when that says Permission denied, then
/// `chmod -h 700`.
extension UninstallTests {
    func cannotOpenText(_ subject: String, _ place: String) -> String {
        "\(subject) `\(place)` cannot be opened or searched, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod -N \(place)`, then `chmod 700 \(place)`, then run `agent-balancer uninstall` again."
    }

    func cannotCheckText(_ subject: String, _ place: String) -> String {
        "\(subject) `\(place)` cannot be checked, so `uninstall` cannot tell what it is or what the tool made in it. Nothing was removed. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, then `chmod -h 700 \(place)`, then run `agent-balancer uninstall` again."
    }

    /// Does what the cannot-be-checked text says: its first command, the second only when the
    /// first says Permission denied, then the third. Returns whether the second one ran.
    func followCannotCheck(_ said: String, _ t: TestHome) throws -> Bool {
        let commands = namedCommands(said, home: t.home)
        try #require(commands.count == 3)
        let first = try runNamedCapturing(commands[0])
        let denied = first.status != 0 && first.error.contains("Permission denied")
        if denied {
            #expect(try runNamedCapturing(commands[1]).status == 0, "\(commands[1])")
        } else {
            #expect(first.status == 0, "\(commands[0]): \(first.error)")
        }
        #expect(try runNamedCapturing(commands[2]).status == 0, "\(commands[2])")
        return denied
    }

    /// Whether `url` has an access list, read without following a link.
    func hasAccessList(_ url: URL) -> Bool {
        guard let list = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(list))
        return true
    }

    func permissions(_ url: URL) -> mode_t {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0
    }

    /// The data folder, the token folder and the launch folder of `t`, each with its subject and
    /// its path as the person types it.
    func checkedPlaces(_ t: TestHome) throws -> [(folder: URL, subject: String, place: String)] {
        let typed = "~/.agent-balancer"
        return [
            (t.context.dataRoot, "The data folder", typed),
            (
                try tokenFile(t).deletingLastPathComponent(), "The token folder",
                typed + "/" + TokenPaths.folderName
            ),
            (
                LaunchFiles.rootURL(context: t.context), "The launch folder",
                typed + "/" + LaunchFiles.folder
            ),
        ]
    }

    @Test func aFolderWhoseAccessListDeniesItsOwnerReadattrIsRefusedWithCommandsThatEachRun()
        throws
    {
        for which in 0..<3 {
            let (t, _) = try setUp()
            let item = try checkedPlaces(t)[which]
            try denyOwner("readattr", item.folder)
            defer { withExtendedLifetime(t) { _ = try? chmodRun(["-N", item.folder.path]) } }
            let said = try #require(refusalText(t), "\(item.place)")
            #expect(said == cannotCheckText(item.subject, item.place))
            // Each command the text names, in its order, and the rerun finishes.
            #expect(try !followCannotCheck(said, t), "\(item.place)")
            #expect(refusalText(t) == nil, "\(item.place)")
            #expect(try run(t).tokenFiles == 1, "\(item.place)")
        }
    }

    @Test
    func aFolderThatCannotBeCheckedOrListedIsClearedByTheCommandTheTextNamesForPermissionDenied()
        throws
    {
        for which in 0..<3 {
            let (t, _) = try setUp()
            let item = try checkedPlaces(t)[which]
            try denyOwner("list,readattr", item.folder)
            defer { withExtendedLifetime(t) { _ = try? chmodRun(["-N", item.folder.path]) } }
            let said = try #require(refusalText(t), "\(item.place)")
            #expect(said == cannotCheckText(item.subject, item.place))
            // `chmod -h -N` opens the folder, which its list does not let its owner do.
            #expect(try followCannotCheck(said, t), "\(item.place)")
            #expect(refusalText(t) == nil, "\(item.place)")
            #expect(try run(t).tokenFiles == 1, "\(item.place)")
        }
    }

    @Test func aFolderWithNoOwnerReadIsRefusedWithCommandsThatEachRunAndARerunFinishes() throws {
        for which in 0..<4 {
            let (t, launch) = try setUp()
            let label = (
                folder: launch.deletingLastPathComponent(), subject: "The launch folder",
                place: "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"
            )
            let item = which < 3 ? try checkedPlaces(t)[which] : label
            chmod(item.folder.path, 0o300)
            defer { withExtendedLifetime(t) { _ = chmod(item.folder.path, 0o700) } }
            let said = try #require(refusalText(t), "\(item.place)")
            #expect(said == cannotOpenText(item.subject, item.place))
            // A person who stops at the first error still runs every command here.
            for command in chmodCommands(said, home: t.home) {
                #expect(try chmodRun(command) == 0, "\(item.place): \(command)")
            }
            #expect(refusalText(t) == nil, "\(item.place)")
            #expect(try run(t).tokenFiles == 1, "\(item.place)")
        }
    }

    @Test func aTokenFolderThatIsALinkWithItsOwnAccessListIsRefusedWithCommandsThatSpareItsTarget()
        throws
    {
        let (t, _) = try setUp()
        let tokens = try tokenFile(t).deletingLastPathComponent()
        let kept = t.home.appendingPathComponent("kept-tokens")
        try FileManager.default.moveItem(at: tokens, to: kept)
        try FileManager.default.createSymbolicLink(at: tokens, withDestinationURL: kept)
        chmod(kept.path, 0o755)
        #expect(try chmodRun(["+a", "user:nobody deny list,search", kept.path]) == 0)
        // An entry on the link itself, so `lstat` cannot check it.
        #expect(try chmodRun(["-h", "+a", NSUserName() + " deny readattr", tokens.path]) == 0)
        defer {
            withExtendedLifetime(t) {
                _ = try? chmodRun(["-h", "-N", tokens.path])
                _ = try? chmodRun(["-N", kept.path])
                chmod(kept.path, 0o700)
            }
        }
        let place = "~/.agent-balancer/" + TokenPaths.folderName
        let said = try #require(refusalText(t))
        #expect(said == cannotCheckText("The token folder", place))
        #expect(try !followCannotCheck(said, t))
        // The folder the link points to keeps its mode and its access list.
        #expect(permissions(kept) == 0o755)
        #expect(hasAccessList(kept))
        #expect(refusalText(t) == Messages.uninstallRefusal("The token folder", place, .link))
    }

    @Test func aFolderWiderThan0700WhoseAccessListDeniesSearchFinishesByItsTwoTextsInTurn()
        throws
    {
        let (t, _) = try setUp()
        let tokens = try tokenFile(t).deletingLastPathComponent()
        let place = "~/.agent-balancer/" + TokenPaths.folderName
        chmod(tokens.path, 0o755)
        try denySearch(tokens, true)
        defer {
            withExtendedLifetime(t) {
                try? denySearch(tokens, false)
                chmod(tokens.path, 0o700)
            }
        }
        // The mode is read first; `chmod 700` fixes it and leaves the access list.
        let wider = try #require(refusalText(t))
        #expect(
            wider
                == "The token folder `\(place)` is wider than 0700, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod 700 \(place)`, then run `agent-balancer uninstall` again."
        )
        for command in chmodCommands(wider, home: t.home) {
            #expect(try chmodRun(command) == 0, "\(command)")
        }
        let closed = try #require(refusalText(t))
        #expect(closed == cannotOpenText("The token folder", place))
        for command in chmodCommands(closed, home: t.home) {
            #expect(try chmodRun(command) == 0, "\(command)")
        }
        #expect(refusalText(t) == nil)
    }

    static let temporariesText =
        "1 temporary files could not be checked or deleted and may hold a token. On each folder that holds one, `~/.agent-balancer/"
        + TokenPaths.folderName + "` or a label's folder in `~/.agent-balancer/"
        + LaunchFiles.folder
        + "/` that is not a link, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on each temporary file in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg` first on any of them that is locked. Then run `agent-balancer uninstall` again."

    @Test func aTemporaryALabelFoldersAccessListKeepsIsNamedWithItsFolderAndARerunDeletesIt()
        throws
    {
        let (t, _) = try setUp()
        let folder = LaunchFiles.rootURL(context: t.context).appendingPathComponent("pool-b")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".tmp-0123456789abcdef")
        try "{}".write(to: temporary, atomically: false, encoding: .utf8)
        try denyOwner("delete_child", folder)
        defer { clearLaunchFolders(t) }
        let done = try run(t)
        #expect(done.tokenFiles == 1 && done.temporariesLeft == 1)
        // The token folder went with the token file, so the text names only the folder that
        // holds the temporary.
        #expect(!exists(try tokenFile(t).deletingLastPathComponent()))
        let said = TokenAccounts.undeletedTemporariesText(1)
        #expect(said == Self.temporariesText)
        let fix = try #require(namedFix(said))
        #expect(try follow(fix, folders: [folder], files: [temporary]) == 0)
        #expect(try run(t).temporariesLeft == 0)
        #expect(!exists(temporary))
    }
}

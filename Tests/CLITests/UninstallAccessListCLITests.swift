import Core
import Foundation
import Testing

@testable import Core

private func output(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// An entry whose access list denies its owner `readattr`, so `lstat` cannot check it: the token
/// file and temporary texts name `chmod -h -N`, a label's folder gets its own text instead of the
/// link, file or other user one, and a rerun after the named commands finishes.
extension PersonCommandsCLITests {
    func runChmod(_ arguments: [String]) throws -> Int32 {
        try runNamedCapturing(["chmod"] + arguments).status
    }

    /// Runs a named command, its first word `chmod` or `chflags` as a person's shell finds it,
    /// and returns its exit status and what it wrote to standard error.
    func runNamedCapturing(_ words: [String]) throws -> (status: Int32, error: String) {
        let task = Process()
        task.executableURL = URL(
            fileURLWithPath: words.first == "chflags" ? "/usr/bin/chflags" : "/bin/chmod")
        task.arguments = Array(words.dropFirst())
        let pipe = Pipe()
        task.standardError = pipe
        try task.run()
        let said = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    /// The `chmod` and `chflags` commands the line of `shown` holding `marker` names in
    /// backticks, each as its words, with `~` as `home`.
    func namedCommands(_ shown: String, _ marker: String, home: URL) -> [[String]] {
        guard let line = shown.split(separator: "\n").first(where: { $0.contains(marker) })
        else { return [] }
        return line.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
            .filter { $0.hasPrefix("chmod ") || $0.hasPrefix("chflags ") }
            .map { command in
                command.split(separator: " ").map { word in
                    word.hasPrefix("~") ? home.path + String(word.dropFirst()) : String(word)
                }
            }
    }

    /// What a text that names a fix for folders and the files in them says to run, in its
    /// order: two commands for each folder, one for each file, the one for a file where that
    /// says Permission denied, and the one for an entry that is locked.
    struct NamedFix {
        var folder: [[String]]
        var file: [String]
        var denied: [String]
        var locked: [String]
    }

    func namedFix(_ shown: String, _ marker: String) -> NamedFix? {
        let commands = namedCommands(shown, marker, home: URL(fileURLWithPath: "/"))
        let chmods = commands.filter { $0.first == "chmod" }
        guard chmods.count == 4, let locked = commands.first(where: { $0.first == "chflags" })
        else { return nil }
        return NamedFix(
            folder: [chmods[0], chmods[1]], file: chmods[2], denied: chmods[3], locked: locked)
    }

    func isLocked(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    func lockEntry(_ url: URL) throws {
        #expect(try runNamedCapturing(["chflags", "uchg", url.path]).status == 0)
    }

    /// Runs `command` on `entry`, then `denied` on it when `command` says Permission denied.
    /// Returns whether `denied` ran.
    func runOrDenied(_ command: [String], _ denied: [String], _ entry: URL) throws -> Bool {
        let done = try runNamedCapturing(command + [entry.path])
        if done.status != 0, done.error.contains("Permission denied") {
            #expect(try runNamedCapturing(denied + [entry.path]).status == 0)
            return true
        }
        #expect(done.status == 0, "\(entry.lastPathComponent): \(done.error)")
        return false
    }

    /// Does what such a text says, as a person reads it: each locked entry unlocked first, then
    /// the folder commands on each folder, then the file command on each file, and the
    /// Permission denied one on a file where the file command says so. Returns how many files
    /// needed that one.
    @discardableResult
    func follow(_ fix: NamedFix, folders: [URL], files: [URL]) throws -> Int {
        for entry in folders + files where isLocked(entry) {
            #expect(try runNamedCapturing(fix.locked + [entry.path]).status == 0)
        }
        for folder in folders {
            for command in fix.folder {
                let done = try runNamedCapturing(command + [folder.path])
                #expect(done.status == 0, "\(command) \(folder.lastPathComponent)")
            }
        }
        return try files.filter { try runOrDenied(fix.file, fix.denied, $0) }.count
    }

    /// Clears the flags and access lists a test set on `entries`, so the home can be removed.
    func clearMarks(_ entries: [URL]) {
        for entry in entries {
            _ = try? runNamedCapturing(["chflags", "-h", "nouchg", entry.path])
            let isLink =
                (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path))
                != nil
            if (try? runChmod(["-h", "-N", entry.path])) != 0, !isLink {
                _ = try? runChmod(["-N", entry.path])
            }
        }
    }

    /// Adds an access list entry that denies the owner `readattr` on `url`, so `lstat` fails there.
    func denyAttributes(_ url: URL) throws {
        #expect(try runChmod(["+a", NSUserName() + " deny readattr", url.path]) == 0)
    }

    /// Removes the access list of `url`, as the texts say to with `chmod -N`.
    func removeAccessList(_ url: URL) throws -> Int32 { try runChmod(["-N", url.path]) }

    static func tokenText(_ count: Int) -> String {
        "\(count) token files could not be checked or deleted and may still hold a token. On `~/.agent-balancer/"
            + TokenPaths.folderName
            + "`, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on each token file in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg` first on any of them that is locked. Then run `agent-balancer uninstall` again."
    }

    static func temporariesText(_ count: Int) -> String {
        "\(count) temporary files could not be checked or deleted and may hold a token. On each folder that holds one, `~/.agent-balancer/"
            + TokenPaths.folderName + "` or a label's folder in `~/.agent-balancer/"
            + LaunchFiles.folder
            + "/` that is not a link, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on each temporary file in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg` first on any of them that is locked. Then run `agent-balancer uninstall` again."
    }

    /// A token file whose access list denies its owner `rights`: the closing text, its fix run
    /// as written on the token folder and each token file in it, then the rerun. Returns how many
    /// files needed the command for Permission denied.
    func followTokenText(_ rights: String) throws -> Int {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        let file = try TokenPaths.fileURL(context: context, label: "pool-a")
        let folder = file.deletingLastPathComponent()
        #expect(try runChmod(["+a", NSUserName() + " deny " + rights, file.path]) == 0)
        defer { clearMarks([folder, file]) }
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 1, "\(rights)")
        #expect(output(done.stdout).contains("\n" + Self.tokenText(1) + "\n"), "\(rights)")
        #expect(
            output(done.stdout).contains("\n" + TokenAccounts.undeletedTokenFilesText(1) + "\n"))
        let fix = try #require(namedFix(output(done.stdout), "token files could not"))
        let denied = try follow(fix, folders: [folder], files: entries(in: folder))
        let again = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(again.status == 0, "\(rights)")
        #expect(!FileManager.default.fileExists(atPath: file.path), "\(rights)")
        return denied
    }

    @Test func aTokenFileThatCannotBeCheckedIsNamedWithChmodNAndARerunDeletesIt() throws {
        #expect(try followTokenText("readattr") == 0)
    }

    @Test func aTokenFileWhoseAccessListDeniesItsOwnerReadIsClearedByTheCommandForPermissionDenied()
        throws
    {
        // `chmod -h -N` opens the file, which its list does not let its owner do.
        #expect(try followTokenText("read,readattr") == 1)
    }

    /// A temporary in the token folder whose access list denies its owner `rights`: the closing
    /// text, its fix run as written on the folder that holds it and on it, then the rerun.
    func followTemporariesText(_ rights: String) throws -> Int {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        let file = try TokenPaths.fileURL(context: context, label: "pool-a")
        // What a token write stopped before its rename leaves: the whole file under a temporary name.
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".tmp-0123456789abcdef")
        try FileManager.default.moveItem(at: file, to: temporary)
        #expect(try runChmod(["+a", NSUserName() + " deny " + rights, temporary.path]) == 0)
        defer { clearMarks([temporary]) }
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 1, "\(rights)")
        #expect(output(done.stdout).contains("\n" + Self.temporariesText(1) + "\n"), "\(rights)")
        #expect(
            output(done.stdout).contains("\n" + TokenAccounts.undeletedTemporariesText(1) + "\n"))
        let fix = try #require(namedFix(output(done.stdout), "temporary files could not"))
        let denied = try follow(
            fix, folders: [temporary.deletingLastPathComponent()], files: [temporary])
        let again = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(again.status == 0, "\(rights)")
        #expect(!FileManager.default.fileExists(atPath: temporary.path), "\(rights)")
        return denied
    }

    @Test func aTemporaryThatCannotBeCheckedIsNamedWithChmodNAndARerunDeletesIt() throws {
        #expect(try followTemporariesText("readattr") == 0)
    }

    @Test func aTemporaryWhoseAccessListDeniesItsOwnerReadIsClearedByTheCommandForPermissionDenied()
        throws
    {
        #expect(try followTemporariesText("read,readattr") == 1)
    }

    static func listedUnchecked(_ count: Int) -> String {
        "\n\(count) entries in the launch folder where a label's folder belongs cannot be checked, and a launch file with a token may be in them. They are not opened, and the closing text says what to do.\n"
    }
    static let listedLink =
        "\n1 entries in the launch folder where a label's folder belongs are a link, a file or another user's folder, and a launch file with a token may be behind them. They are not followed, and the closing text says what to do.\n"
    static func saidUnchecked(_ count: Int) -> String {
        "\n\(count) entries in `~/.agent-balancer/" + LaunchFiles.folder
            + "/` where a label's folder belongs could not be checked, so a launch file with a "
            + "token may be in them, and `uninstall` did not open them. Run `chmod -h -N` on each "
            + "entry there, or `chmod -N` where that says Permission denied, then run "
            + "`agent-balancer uninstall` again.\n"
    }

    /// A home whose launch folder for `pool-a`, holding a launch file with the token, has an
    /// access list that denies its owner `rights`.
    func uncheckedLabelFolder(_ rights: String = "readattr") throws -> (CLIHome, URL) {
        let cli = try setUp(token: Canary.realShapeToken())
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let context = ToolContext(home: cli.home, ambient: [:])
        let label = LaunchFiles.rootURL(context: context).appendingPathComponent("pool-a")
        #expect(launchFiles(cli).count == 1)
        #expect(try runChmod(["+a", NSUserName() + " deny " + rights, label.path]) == 0)
        return (cli, label)
    }

    /// Runs the unchecked entries text's commands as written on each entry in the launch
    /// folder. Returns how many needed the command for Permission denied.
    func followUncheckedText(_ shown: String, _ launch: URL) throws -> Int {
        let commands = namedCommands(shown, "could not be checked", home: URL(fileURLWithPath: "/"))
        try #require(commands.count == 2)
        return try entries(in: launch).filter { try runOrDenied(commands[0], commands[1], $0) }
            .count
    }

    @Test func aLabelFolderThatCannotBeCheckedGetsItsOwnTextAndARerunFinishesAfterChmodN() throws {
        for (rights, denied) in [("readattr", 0), ("list,readattr", 1)] {
            let (cli, label) = try uncheckedLabelFolder(rights)
            defer { cli.cleanup() }
            defer { clearMarks([label]) }
            let listing = output(try cli.run(["uninstall"], stdin: "no\n").stdout)
            #expect(listing.contains(Self.listedUnchecked(1)), "\(rights)")
            #expect(!listing.contains("a link, a file or another user's folder"), "\(rights)")

            let done = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(done.status == 1, "\(rights)")
            #expect(output(done.stdout).contains(Self.saidUnchecked(1)), "\(rights)")
            #expect(!output(done.stdout).contains("a link, a file or another user's folder"))

            let launch = label.deletingLastPathComponent()
            #expect(try followUncheckedText(output(done.stdout), launch) == denied, "\(rights)")
            let again = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(again.status == 0, "\(rights)")
            #expect(!output(again.stdout).contains("could not be checked"), "\(rights)")
            let token = try TokenPaths.fileURL(
                context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(rights)")
        }
    }

    @Test func aLabelFolderThatCannotBeCheckedAndALinkEachKeepTheirOwnText() throws {
        let (cli, label) = try uncheckedLabelFolder()
        defer { cli.cleanup() }
        defer { _ = try? removeAccessList(label) }
        let context = ToolContext(home: cli.home, ambient: [:])
        // A second folder that cannot be checked, so each count differs from the other.
        let other = LaunchFiles.rootURL(context: context).appendingPathComponent("pool-c")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try denyAttributes(other)
        defer { _ = try? removeAccessList(other) }
        let elsewhere = cli.home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: LaunchFiles.rootURL(context: context).appendingPathComponent("pool-b"),
            withDestinationURL: elsewhere)

        let listing = output(try cli.run(["uninstall"], stdin: "no\n").stdout)
        #expect(listing.contains(Self.listedUnchecked(2)))
        #expect(listing.contains(Self.listedLink))

        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 1)
        #expect(output(done.stdout).contains(Self.saidUnchecked(2)))
        #expect(output(done.stdout).contains("\n" + LaunchFiles.notFollowedEntriesText(1) + "\n"))
    }
}

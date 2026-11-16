import Foundation
import Testing

@testable import Core

/// A real folder whose access list denies its owner `list` or `search` is refused with a text
/// that names `chmod -N`, since `chmod 700` leaves the list in place, then `chmod 700`; neither
/// opens the folder, so each runs, and the rerun finishes with the token file gone.
extension UninstallTests {
    /// The `chmod` commands a text names in backticks, as arguments, with `~` as `home`.
    func chmodCommands(_ text: String, home: URL) -> [[String]] {
        namedCommands(text, home: home).filter { $0.first == "chmod" }.map { Array($0.dropFirst()) }
    }

    /// The `chmod` and `chflags` commands a text names in backticks, each as its words, with `~`
    /// as `home`.
    func namedCommands(_ text: String, home: URL) -> [[String]] {
        text.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            .filter { $0.hasPrefix("chmod ") || $0.hasPrefix("chflags ") }
            .map { command in
                command.split(separator: " ").map { word in
                    word.hasPrefix("~") ? home.path + String(word.dropFirst()) : String(word)
                }
            }
    }

    func chmodRun(_ arguments: [String]) throws -> Int32 {
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

    func refusalText(_ t: TestHome) -> String? {
        do {
            _ = try Uninstall.plan(context: t.context, leaseMinutes: 30)
            return nil
        } catch let error as ToolError {
            return error.message
        } catch {
            return "\(error)"
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

    func namedFix(_ text: String) -> NamedFix? {
        let commands = namedCommands(text, home: URL(fileURLWithPath: "/"))
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
        var denied = 0
        for file in files {
            let done = try runNamedCapturing(fix.file + [file.path])
            if done.status != 0, done.error.contains("Permission denied") {
                denied += 1
                #expect(try runNamedCapturing(fix.denied + [file.path]).status == 0)
            } else {
                #expect(done.status == 0, "\(file.lastPathComponent): \(done.error)")
            }
        }
        return denied
    }

    /// Clears the flags and access lists a test set on `entries`, so the home can be removed.
    func clearMarks(_ entries: [URL]) {
        for entry in entries {
            _ = try? runNamedCapturing(["chflags", "-h", "nouchg", entry.path])
            if (try? chmodRun(["-h", "-N", entry.path])) != 0, !isLink(entry) {
                _ = try? chmodRun(["-N", entry.path])
            }
        }
    }

    @Test
    func theRefusalOfAFolderWhoseAccessListDeniesItsOwnerListOrSearchNamesChmodNAndARerunFinishes()
        throws
    {
        for rights in ["search", "list", "list,search"] {
            for which in 0..<4 {
                let (t, launch) = try setUp()
                let root = t.context.dataRoot
                let typed = "~/.agent-balancer/"
                let launchPlace = typed + LaunchFiles.folder
                let places: [(folder: URL, subject: String, place: String)] = [
                    (root, "The data folder", "~/.agent-balancer"),
                    (
                        try tokenFile(t).deletingLastPathComponent(), "The token folder",
                        typed + TokenPaths.folderName
                    ),
                    (LaunchFiles.rootURL(context: t.context), "The launch folder", launchPlace),
                    (
                        launch.deletingLastPathComponent(), "The launch folder",
                        launchPlace + "/pool-a"
                    ),
                ]
                let item = places[which]
                let name = "\(rights) on \(item.place)"
                try denyOwner(rights, item.folder)
                // The run that finishes removes the folder, so the clear allows a missing one.
                defer { withExtendedLifetime(t) { clearMarks([item.folder]) } }
                let said = try #require(refusalText(t), "\(name)")
                #expect(said == cannotOpenText(item.subject, item.place), "\(name)")
                // Each command the text names, run as written, and the rerun finishes.
                for command in chmodCommands(said, home: t.home) {
                    #expect(try chmodRun(command) == 0, "\(name): \(command)")
                }
                #expect(refusalText(t) == nil, "\(name)")
                let done = try run(t)
                #expect(done.tokenFiles == 1 && done.tokenFilesLeft == 0, "\(name)")
                #expect(!exists(try tokenFile(t)), "\(name)")
            }
        }
    }

    @Test func theRefusalOfAFolderWiderThan0700NamesChmod700Alone() {
        // `lstat` read the mode of a real folder there, and no access list makes it wider.
        let place = "~/.agent-balancer/" + TokenPaths.folderName
        #expect(
            Messages.uninstallFolderRefused("The token folder", place, .widerThanPrivate)
                == "The token folder `\(place)` is wider than 0700, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod 700 \(place)`, then run `agent-balancer uninstall` again."
        )
    }
}

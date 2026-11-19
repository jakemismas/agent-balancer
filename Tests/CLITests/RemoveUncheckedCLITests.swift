import Core
import Foundation
import Testing

@testable import Core

private func said(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// Runs `/bin/chmod` with `arguments` and returns its exit status.
private func runChmodTool(_ arguments: [String]) throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/chmod")
    task.arguments = arguments
    try task.run()
    task.waitUntilExit()
    return task.terminationStatus
}

/// `remove` with a launch file, or a label's launch folder, that it cannot check: it stops before
/// it deletes anything and exits 1 with the token file and the account kept, and its text names
/// the label's launch folder and the commands that let it check again. Once they run as written,
/// a rerun finishes and no launch file of the label holds the token.
extension PersonCommandsCLITests {
    static let removePlace = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"

    /// What a stop says when it comes before anything is deleted.
    static let nothingDeleted = " Nothing was deleted."

    static func removeUncheckedFiles(_ count: Int, _ kept: String = nothingDeleted) -> String {
        "\(count) launch files of 'pool-a' could not be checked and may hold a token.\(kept) Run `chmod -h -N "
            + removePlace
            + "`, and run `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg,nouappnd "
            + removePlace
            + "` first if it is locked. Then run `agent-balancer remove pool-a` again."
    }

    static let removeFolderUnopened =
        "The launch folder `" + removePlace
        + "` cannot be opened or searched, so `remove` cannot check whether a launch file in it holds a token. Nothing was deleted. Run `chmod -N "
        + removePlace + "`, then `chmod 700 " + removePlace + "`, and `chflags nouchg,nouappnd "
        + removePlace + "` first if it is locked, then run `agent-balancer remove pool-a` again."

    static let removeFolderUnchecked =
        "The launch folder `" + removePlace
        + "` cannot be checked, so `remove` cannot tell what it is or whether a launch file in it holds a token. Nothing was deleted. Run `chmod -h -N "
        + removePlace + "`, or `chmod -N " + removePlace
        + "` if that says Permission denied, then `chmod -h 700 " + removePlace
        + "`, then run `agent-balancer remove pool-a` again."

    /// What the writer says when it refuses the folder at `place` for `why`.
    static func writerRefusal(_ place: String, _ why: String) -> String {
        switch why {
        case "link":
            return
                "Refused `\(place)`: it is a link or not a folder, and the tool never follows a link. Move what is there out of the way, or move the folder a link points to back in its place."
        case "wide":
            return
                "Refused `\(place)`: it is wider than 0700. Run `chmod 700 \(place)` in Terminal."
        case "shared":
            return
                "Refused `\(place)`: its access list lets another user or group in, or cannot be read. Run `chmod -N \(place)` in Terminal."
        default:
            return
                "Refused `\(place)`: it cannot be opened or searched. Run `chmod -N \(place)`, then `chmod 700 \(place)` in Terminal."
        }
    }

    func removeTokenFile(_ cli: CLIHome) throws -> URL {
        try TokenPaths.fileURL(context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
    }

    func registryHoldsPoolA(_ cli: CLIHome) throws -> Bool {
        try ConfigStore(context: ToolContext(home: cli.home, ambient: [:])).load()?
            .account("pool-a") != nil
    }

    /// How many launch files under the data folder hold `secret`.
    func launchFilesHolding(_ cli: CLIHome, _ secret: String) -> Int {
        launchFiles(cli).filter {
            ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains(secret)
        }.count
    }

    /// How many files directly in `folder` hold `secret`.
    func filesHolding(_ folder: URL, _ secret: String) -> Int {
        entries(in: folder).filter {
            ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains(secret)
        }.count
    }

    /// How many leases `pool-a` holds, open or not.
    func poolALeases(_ cli: CLIHome) throws -> Int {
        try LeaseStore(context: ToolContext(home: cli.home, ambient: [:]))
            .current(now: Date(), leaseMinutes: 525_600).filter { $0.label == "pool-a" }.count
    }

    /// The spans of `shown` in backticks.
    func spans(_ shown: String) -> [String] {
        shown.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    /// Whether `url` has a flag set that keeps `chmod` and a delete off it, the user's lock or
    /// append-only flag, read without following a link.
    func isFlagged(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
            && st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0
    }

    /// Runs each `chflags` command of `commands` whose last word names an entry that is locked,
    /// as the texts say to run it first.
    func unlockNamed(_ commands: [[String]]) throws {
        for unlock in commands where unlock.first == "chflags" {
            guard let last = unlock.last, isFlagged(URL(fileURLWithPath: last)) else { continue }
            let done = try runNamedCapturing(unlock)
            #expect(done.status == 0, "\(unlock): \(done.error)")
        }
    }

    /// Does what the stop for launch files says, as a person reads it: the `chflags` on the folder
    /// first when it is locked, the folder command, then the file command on each file directly in
    /// it, and the one for Permission denied where the file command says so. Returns how many
    /// files needed that one.
    func followRemoveStop(_ shown: String, _ cli: CLIHome) throws -> Int? {
        let named = namedCommands(shown, "could not be checked", home: cli.home)
        let commands = named.filter { $0.first == "chmod" }
        guard commands.count == 3, commands[0].count == 4, let path = commands[0].last else {
            return nil
        }
        try unlockNamed(named)
        let done = try runNamedCapturing(commands[0])
        #expect(done.status == 0, "\(done.error)")
        return try entries(in: URL(fileURLWithPath: path)).filter {
            try runOrDenied(commands[1], commands[2], $0)
        }.count
    }

    /// Runs each command a folder stop names, as written: its `chflags` first when the folder it
    /// names is locked, then its `chmod` commands. A command for Permission denied runs only when
    /// the one before it says so. Returns whether it ran.
    func followFolderStop(_ shown: String, _ cli: CLIHome, marker: String = "launch folder")
        throws -> Bool?
    {
        let named = namedCommands(shown, marker, home: cli.home)
        let commands = named.filter { $0.first == "chmod" }
        try unlockNamed(named)
        switch commands.count {
        case 2:
            for command in commands {
                let done = try runNamedCapturing(command)
                #expect(done.status == 0, "\(command): \(done.error)")
            }
            return false
        case 3:
            let first = try runNamedCapturing(commands[0])
            let denied = first.status != 0 && first.error.contains("Permission denied")
            if denied {
                #expect(try runNamedCapturing(commands[1]).status == 0)
            } else {
                #expect(first.status == 0, "\(first.error)")
            }
            let last = try runNamedCapturing(commands[2])
            #expect(last.status == 0, "\(last.error)")
            return denied
        default:
            return nil
        }
    }

    @Test func aLaunchFileThatCannotBeCheckedStopsRemoveUntilItsAccessListIsCleared() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        try denyAttributes(launch)
        defer { clearMarks([launch]) }
        let token = try removeTokenFile(cli)

        let stopped = try cli.run(["remove", "pool-a"])
        #expect(stopped.status == 1)
        #expect(said(stopped.stderr).contains("Error: " + Self.removeUncheckedFiles(1) + "\n"))
        #expect(!said(stopped.stdout).contains("the tool did not make them"))
        #expect(FileManager.default.fileExists(atPath: token.path))
        #expect(try registryHoldsPoolA(cli))

        #expect(try removeAccessList(launch) == 0)
        let again = try cli.run(["remove", "pool-a"])
        #expect(again.status == 0)
        #expect(!FileManager.default.fileExists(atPath: token.path))
        #expect(try registryHoldsPoolA(cli) == false)
        let holding = launchFilesHolding(cli, secret)
        #expect(holding == 0)
    }

    @Test func theRemoveStopNamesAChmodThatLetsARerunCheckEachLaunchFileAndFinish() throws {
        let cases: [(rights: String, flag: String?, denied: Int)] = [
            ("readattr", nil, 0), ("read,readattr", nil, 1), ("inherited", nil, 0),
            ("readattr", "uchg", 0), ("readattr", "uappnd", 0),
        ]
        for item in cases {
            let name = item.rights + " " + (item.flag ?? "")
            let secret = Canary.realShapeToken()
            let cli = try setUp(token: secret)
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let launch = try #require(launchFiles(cli).first)
            let folder = launch.deletingLastPathComponent()
            if item.rights == "inherited" {
                // A launch file made after this inherits the entry, and so does each tombstone.
                try denyOwnerOf(folder, "readattr,file_inherit,only_inherit")
                _ = try cli.run(["run", "--print-command", "pool-a"])
            } else {
                try denyOwnerOf(launch, item.rights)
            }
            if let flag = item.flag {
                #expect(try runNamedCapturing(["chflags", flag, folder.path]).status == 0)
            }
            defer { _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", folder.path]) }
            let token = try removeTokenFile(cli)

            let stopped = try cli.run(["remove", "pool-a"])
            #expect(stopped.status == 1, "\(name)")
            #expect(
                said(stopped.stderr).contains("Error: " + Self.removeUncheckedFiles(1) + "\n"),
                "\(name)")
            #expect(FileManager.default.fileExists(atPath: token.path), "\(name)")
            guard let denied = try followRemoveStop(said(stopped.stderr), cli) else {
                Issue.record("the stop names no fix: \(name)")
                continue
            }
            #expect(denied == item.denied, "\(name)")
            let again = try cli.run(["remove", "pool-a"])
            #expect(again.status == 0, "\(name)")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(name)")
            #expect(try registryHoldsPoolA(cli) == false, "\(name)")
            let holding = launchFilesHolding(cli, secret)
            #expect(holding == 0, "\(name)")
        }
    }

    @Test func aLaunchFolderRemoveCannotListOrSearchStopsItUntilTheNamedChmodRuns() throws {
        let cases: [(mark: String, flag: String?, said: String, denied: Bool)] = [
            ("search", nil, Self.removeFolderUnopened, false),
            ("list", nil, Self.removeFolderUnopened, false),
            ("600", nil, Self.removeFolderUnopened, false),
            ("300", nil, Self.removeFolderUnopened, false),
            ("search", "uchg", Self.removeFolderUnopened, false),
            ("search", "uappnd", Self.removeFolderUnopened, false),
            ("readattr", nil, Self.removeFolderUnchecked, false),
            ("search,readattr", nil, Self.removeFolderUnchecked, false),
            ("list,readattr", nil, Self.removeFolderUnchecked, true),
        ]
        for item in cases {
            let name = item.mark + " " + (item.flag ?? "")
            let secret = Canary.realShapeToken()
            let cli = try setUp(token: secret)
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let folder = launchRoot(cli).appendingPathComponent("pool-a")
            defer { _ = try? runChmod(["700", folder.path]) }
            if item.mark.first?.isNumber == true {
                #expect(try runChmod([item.mark, folder.path]) == 0, "\(name)")
            } else {
                try denyOwnerOf(folder, item.mark)
            }
            if let flag = item.flag {
                #expect(try runNamedCapturing(["chflags", flag, folder.path]).status == 0)
            }
            defer { _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", folder.path]) }
            let token = try removeTokenFile(cli)

            let stopped = try cli.run(["remove", "pool-a"])
            #expect(stopped.status == 1, "\(name)")
            #expect(said(stopped.stderr).contains("Error: " + item.said + "\n"), "\(name)")
            #expect(FileManager.default.fileExists(atPath: token.path), "\(name)")
            #expect(try registryHoldsPoolA(cli), "\(name)")
            #expect(try poolALeases(cli) == 1, "\(name)")
            guard let denied = try followFolderStop(said(stopped.stderr), cli) else {
                Issue.record("the stop names no fix: \(name)")
                continue
            }
            #expect(denied == item.denied, "\(name)")
            // The stop came before anything was deleted: the pick's file still holds the token.
            let before = launchFilesHolding(cli, secret)
            #expect(before == 1, "\(name)")
            let again = try cli.run(["remove", "pool-a"])
            #expect(again.status == 0, "\(name)")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(name)")
            let holding = launchFilesHolding(cli, secret)
            #expect(holding == 0, "\(name)")
        }
    }

    @Test func aRemoveOfALabelWithNoAccountLeftStopsOnALaunchFileItCannotCheck() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        // What a remove that counted the file as not the tool's left: only the file.
        let context = ToolContext(home: cli.home, ambient: [:])
        let store = ConfigStore(context: context)
        var registry = try store.loadRequired()
        registry.accounts.removeAll { $0.label == "pool-a" }
        try store.save(registry)
        try FileManager.default.removeItem(at: try removeTokenFile(cli))
        try LeaseStore(context: context).save([])
        try ReadingStore(context: context).delete(label: "pool-a")
        try denyAttributes(launch)
        defer { clearMarks([launch]) }

        let stopped = try cli.run(["remove", "pool-a"])
        #expect(stopped.status == 1)
        #expect(said(stopped.stderr).contains("Error: " + Self.removeUncheckedFiles(1) + "\n"))
        #expect(try removeAccessList(launch) == 0)
        let again = try cli.run(["remove", "pool-a"])
        #expect(again.status == 0)
        #expect(said(again.stdout).contains("Removed what was left of 'pool-a'."))
        let holding = launchFilesHolding(cli, secret)
        #expect(holding == 0)
    }

    @Test func aTombstoneThatTakesAnAccessListStopsTheReadBackAndNamesWhatItKept() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        // Passed on only to a file written after this: the recent pick's tombstone.
        try denyOwnerOf(launch.deletingLastPathComponent(), "readattr,file_inherit,only_inherit")
        let token = try removeTokenFile(cli)

        let stopped = try cli.run(["remove", "pool-a"])
        #expect(stopped.status == 1)
        let kept = " The token file and the account were kept."
        #expect(
            said(stopped.stderr).contains("Error: " + Self.removeUncheckedFiles(1, kept) + "\n"))
        #expect(FileManager.default.fileExists(atPath: token.path))
        #expect(try registryHoldsPoolA(cli))
        #expect(try poolALeases(cli) == 1)
        guard try followRemoveStop(said(stopped.stderr), cli) != nil else {
            Issue.record("the stop names no fix")
            return
        }
        let again = try cli.run(["remove", "pool-a"])
        #expect(again.status == 0)
        #expect(said(again.stdout).contains("Kept 1 launch files"))
        #expect(!FileManager.default.fileExists(atPath: token.path))
        #expect(try registryHoldsPoolA(cli) == false)
        let holding = launchFilesHolding(cli, secret)
        #expect(holding == 0)
    }

    @Test func aLaunchFolderTheWriterRefusesStopsRemoveBeforeAnythingIsDeleted() throws {
        let launchPlace = "~/.agent-balancer/" + LaunchFiles.folder
        let cases: [(mark: String, said: String)] = [
            ("link", Self.writerRefusal(Self.removePlace, "link")),
            ("755", Self.writerRefusal(Self.removePlace, "wide")),
            ("everyone allow list", Self.writerRefusal(Self.removePlace, "shared")),
            ("search on the launch folder", Self.writerRefusal(launchPlace, "unopened")),
        ]
        for item in cases {
            let secret = Canary.realShapeToken()
            let cli = try setUp(token: secret)
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let folder = launchRoot(cli).appendingPathComponent("pool-a")
            let moved = cli.home.appendingPathComponent("moved-pool-a")
            defer { _ = try? runChmod(["700", folder.path]) }
            switch item.mark {
            case "link":
                try FileManager.default.moveItem(at: folder, to: moved)
                try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
            case "755":
                #expect(try runChmod(["755", folder.path]) == 0)
            case "everyone allow list":
                #expect(try runChmod(["+a", "everyone allow list", folder.path]) == 0)
            default:
                try denyOwnerOf(launchRoot(cli), "search")
            }
            let token = try removeTokenFile(cli)

            let stopped = try cli.run(["remove", "pool-a"])
            #expect(stopped.status == 1, "\(item.mark)")
            #expect(
                said(stopped.stderr).contains("Error: " + item.said + "\n"), "\(item.mark)")
            #expect(FileManager.default.fileExists(atPath: token.path), "\(item.mark)")
            #expect(try registryHoldsPoolA(cli), "\(item.mark)")
            #expect(try poolALeases(cli) == 1, "\(item.mark)")
            // The stop came before anything was deleted: the pick's file still holds the token.
            clearAccessLists(cli)
            let holding =
                item.mark == "link"
                ? filesHolding(moved, secret) : launchFilesHolding(cli, secret)
            #expect(holding == 1, "\(item.mark)")
        }
    }
}

/// `remove` with a token file, or a token folder, that it cannot check or delete: it stops before
/// it deletes the account and exits 1, and its text names the token file or its folder and the
/// commands that let it check or delete the file again. Once they run as written, a rerun
/// finishes with the token file gone. Every stop keeps the leases.
extension PersonCommandsCLITests {
    static let typedTokens = "~/.agent-balancer/" + TokenPaths.folderName
    static let typedTokenFile = typedTokens + "/pool-a.json"

    static let removeTokenFileUnchecked =
        "The token file `" + typedTokenFile
        + "` cannot be checked, so `remove` cannot tell what it is or whether it still holds the token of 'pool-a'. Nothing was deleted. Run `chmod -h -N "
        + typedTokenFile + "`, or `chmod -N " + typedTokenFile
        + "` if that says Permission denied, then run `agent-balancer remove pool-a` again."

    static let removeTokensUnopened =
        "The token folder `" + typedTokens
        + "` cannot be opened or searched, so `remove` cannot check whether a token file of 'pool-a' is in it. Nothing was deleted. Run `chmod -N "
        + typedTokens + "`, then `chmod 700 " + typedTokens + "`, and `chflags nouchg,nouappnd "
        + typedTokens + "` first if it is locked, then run `agent-balancer remove pool-a` again."

    static let removeTokensUnchecked =
        "The token folder `" + typedTokens
        + "` cannot be checked, so `remove` cannot tell what it is or whether a token file of 'pool-a' is in it. Nothing was deleted. Run `chmod -h -N "
        + typedTokens + "`, or `chmod -N " + typedTokens
        + "` if that says Permission denied, then `chmod -h 700 " + typedTokens
        + "`, then run `agent-balancer remove pool-a` again."

    /// What `remove` stops with when the token file is still there after its delete; `account`
    /// when the label has a registry entry.
    static func removeTokenFileKept(account: Bool) -> String {
        let kept = account ? ", and the account was kept" : ""
        return "The token file `" + typedTokenFile
            + "` could not be deleted, so it still holds the token of 'pool-a'" + kept + ". On `"
            + typedTokens
            + "`, run `chmod -h -N` and `chmod -h 700`, and run `chmod -h -N` on the token file, or `chmod -N` if that says Permission denied. Run `chflags -h nouchg,nouappnd` first on either of them that is locked. Then run `agent-balancer remove pool-a` again."
    }

    /// Runs the commands the stop for the token file names, as written: the first, and the second
    /// only when the first says Permission denied. Returns whether the second ran.
    func followTokenFileStop(_ shown: String, _ cli: CLIHome) throws -> Bool? {
        let commands = namedCommands(shown, "token file", home: cli.home)
        guard commands.count == 2 else { return nil }
        let first = try runNamedCapturing(commands[0])
        guard first.status != 0, first.error.contains("Permission denied") else {
            #expect(first.status == 0, "\(first.error)")
            return false
        }
        #expect(try runNamedCapturing(commands[1]).status == 0)
        return true
    }

    /// Does what the stop for a token file still there after its delete says, on the token file
    /// and the folder it names: the `chflags` first on either that is locked, the two folder
    /// commands on the folder, then the file command on the file, or the one for Permission
    /// denied where that says so. Returns whether that one ran.
    func followTokenFileKept(_ shown: String, _ cli: CLIHome) throws -> Bool? {
        guard let fix = namedFix(shown, "could not be deleted") else { return nil }
        let places = spans(shown).filter { $0.hasPrefix("~/") }.map {
            URL(fileURLWithPath: cli.home.path + String($0.dropFirst()))
        }
        guard places.count == 2 else { return nil }
        let (file, folder) = (places[0], places[1])
        for entry in [folder, file] where isFlagged(entry) {
            let done = try runNamedCapturing(fix.locked + [entry.path])
            #expect(done.status == 0, "\(entry.lastPathComponent): \(done.error)")
        }
        for command in fix.folder {
            let done = try runNamedCapturing(command + [folder.path])
            #expect(done.status == 0, "\(command): \(done.error)")
        }
        return try runOrDenied(fix.file, fix.denied, file)
    }

    /// Whether the token folder lists the token file by name, which needs no `lstat` of the file.
    func tokenFileListed(_ cli: CLIHome) throws -> Bool {
        let file = try removeTokenFile(cli)
        let folder = file.deletingLastPathComponent().path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.contains(file.lastPathComponent)
    }

    @Test func aTokenFileThatCannotBeCheckedStopsRemoveUntilItsAccessListIsCleared() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let token = try removeTokenFile(cli)
        try denyAttributes(token)
        defer { clearMarks([token]) }

        let stopped = try cli.run(["remove", "pool-a"])
        #expect(stopped.status == 1)
        #expect(said(stopped.stderr).contains("Error: " + Self.removeTokenFileUnchecked + "\n"))
        #expect(try registryHoldsPoolA(cli))
        #expect(try tokenFileListed(cli))
        // The stop came before any delete: the pick's launch file still holds the token.
        let before = launchFilesHolding(cli, secret)
        #expect(before == 1)

        #expect(try removeAccessList(token) == 0)
        #expect(FileManager.default.fileExists(atPath: token.path))
        let again = try cli.run(["remove", "pool-a"])
        #expect(again.status == 0)
        #expect(!FileManager.default.fileExists(atPath: token.path))
        #expect(try registryHoldsPoolA(cli) == false)
    }

    @Test func theTokenFileStopNamesAChmodThatLetsARerunDeleteTheFile() throws {
        for (rights, denied) in [("readattr", false), ("read,readattr", true)] {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            let token = try removeTokenFile(cli)
            try denyOwnerOf(token, rights)
            defer { clearMarks([token]) }

            let stopped = try cli.run(["remove", "pool-a"])
            #expect(stopped.status == 1, "\(rights)")
            #expect(
                said(stopped.stderr).contains("Error: " + Self.removeTokenFileUnchecked + "\n"),
                "\(rights)")
            #expect(try followTokenFileStop(said(stopped.stderr), cli) == denied, "\(rights)")
            let again = try cli.run(["remove", "pool-a"])
            #expect(again.status == 0, "\(rights)")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(rights)")
            #expect(try registryHoldsPoolA(cli) == false, "\(rights)")
        }
    }

    @Test func aTokenFolderRemoveCannotListOrSearchStopsItUntilTheNamedChmodRuns() throws {
        let cases: [(mark: String, flag: String?, said: String, denied: Bool)] = [
            ("search", nil, Self.removeTokensUnopened, false),
            ("list", nil, Self.removeTokensUnopened, false),
            ("600", nil, Self.removeTokensUnopened, false),
            ("300", nil, Self.removeTokensUnopened, false),
            ("search", "uchg", Self.removeTokensUnopened, false),
            ("search", "uappnd", Self.removeTokensUnopened, false),
            ("readattr", nil, Self.removeTokensUnchecked, false),
            ("search,readattr", nil, Self.removeTokensUnchecked, false),
            ("list,readattr", nil, Self.removeTokensUnchecked, true),
        ]
        for item in cases {
            let name = item.mark + " " + (item.flag ?? "")
            let secret = Canary.realShapeToken()
            let cli = try setUp(token: secret)
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let token = try removeTokenFile(cli)
            let folder = token.deletingLastPathComponent()
            defer { _ = try? runChmod(["700", folder.path]) }
            if item.mark.first?.isNumber == true {
                #expect(try runChmod([item.mark, folder.path]) == 0, "\(name)")
            } else {
                try denyOwnerOf(folder, item.mark)
            }
            if let flag = item.flag {
                #expect(try runNamedCapturing(["chflags", flag, folder.path]).status == 0)
            }
            defer { _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", folder.path]) }

            let stopped = try cli.run(["remove", "pool-a"])
            #expect(stopped.status == 1, "\(name)")
            #expect(said(stopped.stderr).contains("Error: " + item.said + "\n"), "\(name)")
            #expect(try registryHoldsPoolA(cli), "\(name)")
            #expect(try poolALeases(cli) == 1, "\(name)")
            guard
                let denied = try followFolderStop(
                    said(stopped.stderr), cli, marker: "token folder")
            else {
                Issue.record("the stop names no fix: \(name)")
                continue
            }
            #expect(denied == item.denied, "\(name)")
            // The stop came before any delete: the token file and the pick's file are both there.
            #expect(FileManager.default.fileExists(atPath: token.path), "\(name)")
            let before = launchFilesHolding(cli, secret)
            #expect(before == 1, "\(name)")
            let again = try cli.run(["remove", "pool-a"])
            #expect(again.status == 0, "\(name)")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(name)")
        }
    }

    @Test func aTokenFolderTheWriterRefusesStopsRemoveBeforeAnythingIsDeleted() throws {
        let cases: [(mark: String, said: String)] = [
            ("link", Self.writerRefusal(Self.typedTokens, "link")),
            ("file", Self.writerRefusal(Self.typedTokens, "link")),
            ("755", Self.writerRefusal(Self.typedTokens, "wide")),
            ("everyone allow list", Self.writerRefusal(Self.typedTokens, "shared")),
        ]
        for item in cases {
            let secret = Canary.realShapeToken()
            let cli = try setUp(token: secret)
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let token = try removeTokenFile(cli)
            let tokens = token.deletingLastPathComponent()
            let moved = cli.home.appendingPathComponent("moved-tokens")
            defer { _ = try? runChmod(["700", tokens.path]) }
            switch item.mark {
            case "link":
                try FileManager.default.moveItem(at: tokens, to: moved)
                try FileManager.default.createSymbolicLink(at: tokens, withDestinationURL: moved)
            case "file":
                try FileManager.default.moveItem(at: tokens, to: moved)
                try Data("x".utf8).write(to: tokens)
            case "755":
                #expect(try runChmod(["755", tokens.path]) == 0)
            default:
                #expect(try runChmod(["+a", "everyone allow list", tokens.path]) == 0)
            }

            let stopped = try cli.run(["remove", "pool-a"])
            #expect(stopped.status == 1, "\(item.mark)")
            #expect(
                said(stopped.stderr).contains("Error: " + item.said + "\n"), "\(item.mark)")
            #expect(try registryHoldsPoolA(cli), "\(item.mark)")
            #expect(try poolALeases(cli) == 1, "\(item.mark)")
            // The stop came before anything was deleted: the pick's file still holds the token.
            let before = launchFilesHolding(cli, secret)
            #expect(before == 1, "\(item.mark)")

            // Put right, the rerun keeps the recent pick's file as a tombstone.
            switch item.mark {
            case "link", "file":
                try FileManager.default.removeItem(at: tokens)
                try FileManager.default.moveItem(at: moved, to: tokens)
            case "755":
                #expect(try runChmod(["700", tokens.path]) == 0)
            default:
                #expect(try runChmod(["-N", tokens.path]) == 0)
            }
            #expect(FileManager.default.fileExists(atPath: token.path), "\(item.mark)")
            let again = try cli.run(["remove", "pool-a"])
            #expect(again.status == 0, "\(item.mark)")
            #expect(said(again.stdout).contains("Kept 1 launch files"), "\(item.mark)")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(item.mark)")
            let holding = launchFilesHolding(cli, secret)
            #expect(holding == 0, "\(item.mark)")
        }
    }

    @Test func aTokenFileRemoveCannotDeleteKeepsTheAccountUntilTheNamedCommandsRun() throws {
        let marks = [
            "lock on the file", "append-only on the file", "delete on the file", "delete_child",
            "lock on the folder", "append-only on the folder",
        ]
        for mark in marks {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            let file = try removeTokenFile(cli)
            let folder = file.deletingLastPathComponent()
            switch mark {
            case "lock on the file": try lockEntry(file)
            case "append-only on the file":
                #expect(try runNamedCapturing(["chflags", "uappnd", file.path]).status == 0)
            case "delete on the file": try denyOwnerOf(file, "delete")
            case "delete_child": try denyOwnerOf(folder, "delete_child")
            case "lock on the folder": try lockEntry(folder)
            default:
                #expect(try runNamedCapturing(["chflags", "uappnd", folder.path]).status == 0)
            }
            defer {
                for entry in [file, folder] {
                    _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", entry.path])
                }
            }

            let stopped = try cli.run(["remove", "pool-a"])
            #expect(stopped.status == 1, "\(mark)")
            #expect(
                said(stopped.stderr).contains(
                    "Error: " + Self.removeTokenFileKept(account: true) + "\n"),
                "\(mark)")
            #expect(try registryHoldsPoolA(cli), "\(mark)")
            #expect(FileManager.default.fileExists(atPath: file.path), "\(mark)")
            #expect(try followTokenFileKept(said(stopped.stderr), cli) == false, "\(mark)")
            let again = try cli.run(["remove", "pool-a"])
            #expect(again.status == 0, "\(mark)")
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(mark)")
            #expect(try registryHoldsPoolA(cli) == false, "\(mark)")
        }
    }

    @Test func aStopAtALockedTokenFileKeepsTheLeasesSoTheRerunKeepsARecentPicksFile() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        let file = try removeTokenFile(cli)
        try lockEntry(file)
        defer { _ = try? runNamedCapturing(["chflags", "nouchg", file.path]) }

        let stopped = try cli.run(["remove", "pool-a"])
        #expect(stopped.status == 1)
        #expect(
            said(stopped.stderr).contains(
                "Error: " + Self.removeTokenFileKept(account: true) + "\n"))
        #expect(try registryHoldsPoolA(cli))
        #expect(try poolALeases(cli) == 1)
        #expect(try runNamedCapturing(["chflags", "nouchg", file.path]).status == 0)
        let again = try cli.run(["remove", "pool-a"])
        #expect(again.status == 0)
        #expect(
            said(again.stdout).contains(
                "Kept 1 launch files that a session still names or a recent pick returned."))
        #expect(!said(again.stdout).contains("Deleted 1 launch files."))
        #expect(FileManager.default.fileExists(atPath: launch.path))
        #expect(try poolALeases(cli) == 0)
        let holding = launchFilesHolding(cli, secret)
        #expect(holding == 0)
    }

    @Test func aRemoveOfALabelWithNoAccountLeftNamesNoAccountWhenItCannotDeleteTheTokenFile()
        throws
    {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var registry = try store.loadRequired()
        registry.accounts.removeAll { $0.label == "pool-a" }
        try store.save(registry)
        let file = try removeTokenFile(cli)
        try lockEntry(file)
        defer { _ = try? runNamedCapturing(["chflags", "nouchg", file.path]) }

        let stopped = try cli.run(["remove", "pool-a"])
        #expect(stopped.status == 1)
        #expect(
            said(stopped.stderr).contains(
                "Error: " + Self.removeTokenFileKept(account: false) + "\n"))
        #expect(try followTokenFileKept(said(stopped.stderr), cli) == false)
        let again = try cli.run(["remove", "pool-a"])
        #expect(again.status == 0)
        #expect(said(again.stdout).contains("Removed what was left of 'pool-a'."))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

/// A folder account's `remove` that stops before anything is deleted writes nothing either: the
/// links it lists stay recorded, so the account still counts as linked.
extension FolderAccountsCLITests {
    @Test func aFolderAccountRemoveThatStopsBeforeAnyDeleteKeepsItsLinks() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        let launch = try #require(
            cli.dataEntries().first { $0.lastPathComponent.hasPrefix("l-") })
        #expect(try runChmodTool(["+a", NSUserName() + " deny readattr", launch.path]) == 0)
        defer { _ = try? runChmodTool(["-N", launch.path]) }
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/spare"

        let stopped = try cli.run(["remove", "spare"])
        #expect(stopped.status == 1)
        #expect(
            said(stopped.stderr).contains(
                "Error: 1 launch files of 'spare' could not be checked and may hold a token. Nothing was deleted. Run `chmod -h -N "
                    + place
                    + "`, and run `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied. Run `chflags -h nouchg,nouappnd "
                    + place
                    + "` first if it is locked. Then run `agent-balancer remove spare` again.\n"))
        let links = HookRecord(context: context(cli)).linkState(for: "spare")
        #expect(links.linked && !links.entries.isEmpty)
        #expect(try ConfigStore(context: context(cli)).loadRequired().account("spare") != nil)

        #expect(try runChmodTool(["-N", launch.path]) == 0)
        let again = try cli.run(["remove", "spare"])
        #expect(again.status == 0)
        #expect(try ConfigStore(context: context(cli)).loadRequired().account("spare") == nil)
    }
}

extension ContractAndArchitectureTextTests {
    @Test func theArchitectureAndTheGuideSayWhatRemoveDoesWithAFileItCannotCheckOrDelete() throws {
        let removing = try Self.section("### 4A.4 The token kind", level: "###")
        let tokenFile = "`" + TokenPaths.folderName + "/<label>.json`"
        for phrase in [
            "Before it writes or deletes anything, it stops when it cannot check the token file or a launch file of the label, since such a file may hold the token",
            "or when `lstat` cannot check " + tokenFile
                + " or a name of a launch file's shape in the label's launch folder, such as a file whose access list denies you `readattr`",
            "A folder that `lstat` cannot check, such as one whose access list denies you `readattr`, stops it too: its list cannot be read either, so it fails the folder checks.",
            "Such a stop says that nothing was deleted, exits 1, and names that folder or the token file and the commands that let it check again",
            "on a folder that cannot be opened or searched, `chmod -N` and then `chmod 700`, with `chflags nouchg,nouappnd` first if it is locked;",
            "on the token file, `chmod -h -N`, or `chmod -N` if that says Permission denied;",
            "with `chflags -h nouchg,nouappnd` on the folder first if it is locked.",
            "A rerun after those commands goes on with the remove: it finishes, stops on the next entry it cannot check or delete with that entry's text, or, when nothing of the label is left, says that no account is labelled so.",
            "When the folder checks refuse `" + TokenPaths.folderName
                + "/` for another reason, such as a link, a file, another user's folder or one wider than 0700, the remove also stops before it writes or deletes anything, with the writer's refusal",
            "and when the token file is still there, such as a locked one or one whose access list denies you `delete`, the remove stops",
            "with `chflags -h nouchg,nouappnd` first on either of them that is locked; when it can no longer check the token file or `"
                + TokenPaths.folderName
                + "/` by then, it stops with the text of the check before any delete;",
            "(e) the label's leases and then the stored reading are deleted;",
            "A stop at (c) or (d) keeps the leases, so a rerun still keeps a recent pick's file as a tombstone, and its text says it kept the token file or the config entry only when that one is there.",
            "a name of a launch file's shape that `lstat` cannot check is not among them, since the remove stops on it",
        ] {
            #expect(removing.contains(phrase), "\(phrase)")
        }
        #expect(!removing.contains("is checked through that handle"))
        #expect(!removing.contains("A rerun after those commands finishes the remove."))
        let threats = try Self.prose("docs/ARCHITECTURE.md")
        #expect(
            threats.contains(
                "`remove` deletes every file of the label, or stops, keeping the account, while a file it cannot check or delete may hold a token (4A.4)"
            ))
        let guide = try Self.prose("docs/GUIDE.md")
        for phrase in [
            "When an access list or a folder mode keeps it from checking the token file or a launch file of the label, or from listing or searching their folders, it stops before it deletes anything and names that folder or file and the commands that let it check them again.",
            "When a lock, an access list or a folder mode keeps it from deleting the token file, it stops, keeps the account, and names the commands that let it delete the file.",
        ] {
            #expect(guide.contains(phrase), "\(phrase)")
        }
    }
}

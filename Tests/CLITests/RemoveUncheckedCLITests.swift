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
                "Refused `\(place)`: it is wider than 0700. Run `chflags nouchg,nouappnd \(place)` first if it is locked, then `chmod 700 \(place)` in Terminal."
        case "shared":
            return
                "Refused `\(place)`: its access list lets another user or group in, or cannot be read. Run `chflags nouchg,nouappnd \(place)` first if it is locked, then `chmod -N \(place)` in Terminal."
        default:
            return
                "Refused `\(place)`: it cannot be opened or searched. Run `chflags nouchg,nouappnd \(place)` first if it is locked, then `chmod -N \(place)`, then `chmod 700 \(place)` in Terminal."
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
            "When the folder checks refuse `" + TokenPaths.folderName + "/`, `"
                + LaunchFiles.folder
                + "/` or the label's launch folder for another reason, such as a link, a file, another user's folder, one wider than 0700 or a `"
                + LaunchFiles.folder
                + "/` that cannot be searched, the remove also stops before it writes or deletes anything, with the writer's refusal, so a `folder` account keeps its links.",
            "So does a lease file that cannot be read.",
            "When the label has leases, a lease file or a `state/` folder in which the writer could not save it, such as a locked one, stops it before it deletes anything too, with the writer's refusal for it, and a `folder` account keeps its links there as well.",
            "That check makes and deletes an empty file in `state/`, and where it cannot delete that file, its text names it. So a refusal the check can see never comes after the token file is deleted;",
            "Each of the writer's folder refusals that names a `chmod` names `chflags nouchg,nouappnd` first on the folder that `chmod` changes, if it is locked",
            "except that a launch file whose open lease names another label, such as one a renamed `login` account's pick left under its old label (Renaming, below), is left as its pick wrote it;",
            "a file of another label's open pick passes only while it still passes the check before any change, and one that no longer does, such as after another program's edit since that check, stops the remove with that stop's text, which then says what it kept;",
            "A launch file has the shape a pick writes when its top-level keys are only among `env`, `crossSessionInbound` and `disableAllHooks`, `disableAllHooks` is `false` and `crossSessionInbound` is a string where either is there, its `env` values are strings, and each `env` name is `AGENT_BALANCER_ACCOUNT` set to the label of the folder the file is in, one that 4A.2 does not list as never allowed, or the token variable set to `invalid`, as a tombstone holds it.",
            "also stops the remove before it writes or deletes anything when it does not have that shape, cannot be read, or holds the label's token anywhere, as a key, a value or part of one, also written with JSON escapes: it may hold a token, also under another credential name or a top-level key such as `apiKeyHelper`, and `remove` never changes another account's file, so the stop keeps the token file and the account, names the file, and says to move it out of the label's launch folder once that pick no longer needs it, then to run `agent-balancer remove <label>` again. It names no command that acts on that file.",
            "While the label's token file is there but `remove` cannot read a token from it, such as one at mode 000 or one whose access list denies you `read`, it cannot check such a file for that token, so each one stops the remove the same way, with a text that says why; with none in the folder, the remove goes on. The token is read into memory for that check alone, and no text holds any part of it.",
            "except two that come only after the tool made an entry in that folder, which a lock prevents: those for a folder whose new entries take an access list that keeps the tool out and for one in which a probe folder cannot be locked, which name `chmod -N` alone.",
            "names `chflags -h nouchg,nouappnd` first on the folder and on each file directly in it that is locked, then `chmod -h -N` and `chmod -h 700` on the folder and `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied, after which a rerun clears the file;",
            "The texts name no command that clears a lock a program set on an entry whose access list denies you `readattr`",
            "`remove <old label>` of an account of any kind added later under that label leaves it as its pick wrote it, with no token variable added, while its lease is open (Removing, above)",
            "When such a file does not have the shape a pick writes, or may hold the label's token (Removing, above), that remove stops before it changes anything and keeps the token file and the account.",
            "and when the token file is still there, such as a locked one or one whose access list denies you `delete`, the remove stops",
            "with `chflags -h nouchg,nouappnd` first on either of them that is locked; when it can no longer check the token file or `"
                + TokenPaths.folderName
                + "/` by then, it stops with the text of the check before any delete;",
            "(e) the label's leases and then the stored reading are deleted, and a lease save that fails after its check passed, such as on a full disk or after a change to `state/` made since the check, stops the remove there with a text that says what it deleted and kept by then, such as the token file and the account, and to run `agent-balancer remove <label>` again once the lease file can be saved;",
            "A `folder` account that was linked has its links forgotten just before (a) (5.1), so each stop from (a) on also says that they were forgotten and that `agent-balancer link <label>` records them again.",
            "A stop at (c) or (d) keeps the leases, so a rerun still keeps a recent pick's file as a tombstone, and its text says it kept the token file or the config entry only when that one is there.",
            "a name of a launch file's shape that `lstat` cannot check is not among them, since the remove stops on it",
        ] {
            #expect(removing.contains(phrase), "\(phrase)")
        }
        #expect(!removing.contains("is checked through that handle"))
        #expect(!removing.contains("A rerun after those commands finishes the remove."))
        #expect(!removing.contains("keeps it as a tombstone while its lease is open, as it keeps"))
        #expect(!removing.contains("so the token file is never deleted before such a stop"))
        #expect(!removing.contains("while it holds no token"))
        #expect(!removing.contains("that holds a token cannot be cleared"))
        #expect(!removing.contains("when it does not have that shape or cannot be read:"))
        #expect(!removing.contains("passes only while it has the shape a pick writes,"))
        let folderRule = try Self.section("### 5.1 Folder layout", level: "###")
        for phrase in [
            "It forgets the entries before it deletes anything, so a stop part way leaves an account that counts as not linked, which fails closed, and when the account was linked, the stop's text says its links were forgotten and that `agent-balancer link <label>` records them again.",
            "A launch file under the label whose open lease names another label, such as one a renamed `login` account's pick left there, is not the account's: that remove leaves it as its pick wrote it, and when the file does not have the shape a pick writes, it stops before it changes anything, keeping the account and its links (4A.4).",
        ] {
            #expect(folderRule.contains(phrase), "\(phrase)")
        }
        let threats = try Self.prose("docs/ARCHITECTURE.md")
        for phrase in [
            "`remove` deletes every file of the label, or stops, keeping the account, while a file it cannot check or delete may hold a token (4A.4)",
            "through the display-safe pass, cut at 240 characters, except a failed `remove`'s, which the bar shows whole and wrapped.",
            "and so does the tool's output in the bar, cut at 240 characters except a failed `remove`'s, which the bar shows whole and wrapped.",
        ] {
            #expect(threats.contains(phrase), "\(phrase)")
        }
        let guide = try Self.prose("docs/GUIDE.md")
        for phrase in [
            "and one a renamed account's recent pick left under the label, which stays as that pick wrote it.",
            "When that file does not have the shape a pick writes, cannot be read, or holds the label's token, or when the remove cannot read the token from the token file to check it, it may hold a token, so the remove stops before it changes anything, keeps the token file and the account, and names the file. Once that pick no longer needs the file, move it out of its folder, then run `agent-balancer remove <label>` again.",
            "When an access list, a folder mode or a lock keeps it from checking the token file, a launch file of the label or their folders, or from saving the lease file, it stops before it deletes anything and names that folder or file and the commands that let it go on, the one that unlocks a locked entry first.",
            "The check of the lease file's folder may leave an empty file there, which the text names, and a refusal that check can see never comes after the token file is deleted.",
            "When the lease file still cannot be saved after the token file is deleted, such as on a full disk, it says that the token file was deleted and the account was kept.",
            "When a lock, an access list or a folder mode keeps it from deleting the token file or clearing a launch file, it stops, keeps the token file and the account, and names the commands that let it finish.",
            "The Manage accounts window shows its whole text.",
            "Those commands cannot clear a lock that a program set on a file or folder whose access list keeps you from reading its attributes.",
        ] {
            #expect(guide.contains(phrase), "\(phrase)")
        }
    }
}

/// The stops of `remove` that came after a write or named commands that did not let a rerun
/// finish: a launch folder the writer refuses stops a folder account's remove with its links
/// kept, a launch file it cannot overwrite or delete stops it with the commands that let a rerun
/// clear the file, a lock on a folder comes first in the writer's text, and a lease file the
/// writer cannot save stops it before anything is deleted. Each printed command runs as printed.
extension PersonCommandsCLITests {
    static func removeNotCleared(_ kept: String, label: String = "pool-a") -> String {
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/" + label
        return
            "A launch file of '\(label)' could not be cleared.\(kept) Run `chflags -h nouchg,nouappnd "
            + place
            + "` first if it is locked, and `chflags -h nouchg,nouappnd` on each file directly in it that is locked. Then run `chmod -h -N "
            + place + "` and `chmod -h 700 " + place
            + "`, and run `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied. Then run `agent-balancer remove \(label)` again."
    }

    /// Does what the read-back stop says, as a person reads it: the `chflags` on the folder and
    /// on each file directly in it that is locked, the two folder commands, then the file command
    /// on each file, and the one for Permission denied where the file command says so. Returns
    /// how many files needed that one, or nil when the text names other commands.
    func followNotCleared(_ shown: String, _ cli: CLIHome) throws -> Int? {
        let named = namedCommands(shown, "could not be cleared", home: cli.home)
        let unlocks = named.filter { $0.first == "chflags" }
        let chmods = named.filter { $0.first == "chmod" }
        guard unlocks.count == 2, chmods.count == 4, chmods[0].count == 4,
            let path = chmods[0].last
        else { return nil }
        let folder = URL(fileURLWithPath: path)
        if isFlagged(folder) {
            let done = try runNamedCapturing(unlocks[0])
            #expect(done.status == 0, "\(done.error)")
        }
        for file in entries(in: folder) where isFlagged(file) {
            let done = try runNamedCapturing(unlocks[1] + [file.path])
            #expect(done.status == 0, "\(done.error)")
        }
        for command in chmods.prefix(2) {
            let done = try runNamedCapturing(command)
            #expect(done.status == 0, "\(command): \(done.error)")
        }
        return try entries(in: folder).filter { try runOrDenied(chmods[2], chmods[3], $0) }.count
    }

    /// Runs each command of a writer's refusal as written: its `chflags` first when the entry it
    /// names is locked, then each `chmod` in order.
    func followRefusal(_ shown: String, _ cli: CLIHome) throws {
        let named = namedCommands(shown, "Refused", home: cli.home)
        try unlockNamed(named)
        for command in named where command.first == "chmod" {
            let done = try runNamedCapturing(command)
            #expect(done.status == 0, "\(command): \(done.error)")
        }
    }

    @Test func theReadBackStopNamesTheCommandsThatLetARerunClearTheLaunchFile() throws {
        let marks = [
            "500 on the folder", "lock on the folder", "append-only on the folder",
            "lock on the file", "append-only on the file", "delete_child", "delete on the file",
        ]
        for mark in marks {
            for recent in [true, false] {
                let name = mark + (recent ? ", recent pick" : ", no lease")
                let secret = Canary.realShapeToken()
                let cli = try setUp(token: secret)
                defer { cli.cleanup() }
                defer { clearAccessLists(cli) }
                _ = try cli.run(["run", "--print-command", "pool-a"])
                let launch = try #require(launchFiles(cli).first)
                let folder = launch.deletingLastPathComponent()
                // A recent pick's file is overwritten with a tombstone; with no lease it is deleted.
                if !recent { try LeaseStore(context: context(cli)).save([]) }
                switch mark {
                case "500 on the folder": #expect(try runChmod(["500", folder.path]) == 0)
                case "lock on the folder": try lockEntry(folder)
                case "append-only on the folder":
                    #expect(try runNamedCapturing(["chflags", "uappnd", folder.path]).status == 0)
                case "lock on the file": try lockEntry(launch)
                case "append-only on the file":
                    #expect(try runNamedCapturing(["chflags", "uappnd", launch.path]).status == 0)
                case "delete_child": try denyOwnerOf(folder, "delete_child")
                default: try denyOwnerOf(launch, "delete")
                }
                defer {
                    for entry in [folder] + entries(in: folder) {
                        _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", entry.path])
                    }
                    _ = try? runChmod(["700", folder.path])
                }
                let token = try removeTokenFile(cli)

                let stopped = try cli.run(["remove", "pool-a"])
                #expect(stopped.status == 1, "\(name)")
                let kept = " The token file and the account were kept."
                #expect(
                    said(stopped.stderr).contains("Error: " + Self.removeNotCleared(kept) + "\n"),
                    "\(name)")
                #expect(FileManager.default.fileExists(atPath: token.path), "\(name)")
                #expect(try registryHoldsPoolA(cli), "\(name)")
                #expect(try poolALeases(cli) == (recent ? 1 : 0), "\(name)")
                guard try followNotCleared(said(stopped.stderr), cli) != nil else {
                    Issue.record("the stop names no fix: \(name)")
                    continue
                }
                let again = try cli.run(["remove", "pool-a"])
                #expect(again.status == 0, "\(name)")
                #expect(!FileManager.default.fileExists(atPath: token.path), "\(name)")
                #expect(try registryHoldsPoolA(cli) == false, "\(name)")
                let holding = launchFilesHolding(cli, secret)
                #expect(holding == 0, "\(name)")
            }
        }
    }

    func context(_ cli: CLIHome) -> ToolContext { ToolContext(home: cli.home, ambient: [:]) }

    @Test func aFolderAccountRemoveThatStopsOnALaunchFolderItCannotCheckKeepsItsLinks() throws {
        let launchPlace = "~/.agent-balancer/" + LaunchFiles.folder
        let place = launchPlace + "/spare"
        let folders = FolderAccountsCLITests()
        let cases: [(mark: String, said: String)] = [
            ("search on the launch folder", Self.writerRefusal(launchPlace, "unopened")),
            ("locked launch folder at 600", Self.writerRefusal(launchPlace, "unopened")),
            ("link", Self.writerRefusal(place, "link")),
            ("file", Self.writerRefusal(place, "link")),
            ("755", Self.writerRefusal(place, "wide")),
        ]
        for item in cases {
            let cli = try folders.setUp()
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            try folders.linked(cli)
            #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
            let root = launchRoot(cli)
            let folder = root.appendingPathComponent("spare")
            let moved = cli.home.appendingPathComponent("moved-spare")
            defer {
                _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", root.path])
                _ = try? runChmod(["700", root.path])
            }
            switch item.mark {
            case "search on the launch folder": try denyOwnerOf(root, "search")
            case "locked launch folder at 600":
                #expect(try runChmod(["600", root.path]) == 0)
                try lockEntry(root)
            case "755": #expect(try runChmod(["755", folder.path]) == 0)
            default:
                try FileManager.default.moveItem(at: folder, to: moved)
                if item.mark == "link" {
                    try FileManager.default.createSymbolicLink(
                        at: folder, withDestinationURL: moved)
                } else {
                    try Data("x".utf8).write(to: folder)
                }
            }

            let stopped = try cli.run(["remove", "spare"])
            #expect(stopped.status == 1, "\(item.mark)")
            #expect(said(stopped.stderr).contains("Error: " + item.said + "\n"), "\(item.mark)")
            let links = HookRecord(context: context(cli)).linkState(for: "spare")
            #expect(links.linked && !links.entries.isEmpty, "\(item.mark)")
            #expect(
                try ConfigStore(context: context(cli)).loadRequired().account("spare") != nil,
                "\(item.mark)")
            if item.mark == "link" || item.mark == "file" {
                // The text says to move what is there out of the way and the folder back.
                try FileManager.default.removeItem(at: folder)
                try FileManager.default.moveItem(at: moved, to: folder)
            } else {
                try followRefusal(said(stopped.stderr), cli)
            }
            let again = try cli.run(["remove", "spare"])
            #expect(again.status == 0, "\(item.mark)")
            #expect(
                try ConfigStore(context: context(cli)).loadRequired().account("spare") == nil,
                "\(item.mark)")
        }
    }

    @Test func aLeaseFileRemoveCannotSaveStopsItBeforeTheTokenFileIsDeleted() throws {
        let marks = [
            "lock on the file", "delete on the file", "lock on the folder", "500 on the folder",
        ]
        for mark in marks {
            let secret = Canary.realShapeToken()
            let cli = try setUp(token: secret)
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let state = cli.dataRoot.appendingPathComponent("state")
            let leases = state.appendingPathComponent("leases.json")
            switch mark {
            case "lock on the file": try lockEntry(leases)
            case "delete on the file": try denyOwnerOf(leases, "delete")
            case "lock on the folder": try lockEntry(state)
            default: #expect(try runChmod(["500", state.path]) == 0)
            }
            defer {
                for entry in [state, leases] {
                    _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", entry.path])
                }
                _ = try? runChmod(["-N", leases.path])
                _ = try? runChmod(["700", state.path])
            }
            let token = try removeTokenFile(cli)

            let stopped = try cli.run(["remove", "pool-a"])
            #expect(stopped.status == 1, "\(mark)")
            #expect(
                said(stopped.stderr).contains("Error: Refused `~/.agent-balancer/state"),
                "\(mark)")
            // Nothing was deleted: the token file, the account, the lease and the pick's file stay.
            #expect(FileManager.default.fileExists(atPath: token.path), "\(mark)")
            #expect(try registryHoldsPoolA(cli), "\(mark)")
            #expect(try poolALeases(cli) == 1, "\(mark)")
            let before = launchFilesHolding(cli, secret)
            #expect(before == 1, "\(mark)")
            try followRefusal(said(stopped.stderr), cli)
            let again = try cli.run(["remove", "pool-a"])
            #expect(again.status == 0, "\(mark)")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(mark)")
            #expect(try poolALeases(cli) == 0, "\(mark)")
            let holding = launchFilesHolding(cli, secret)
            #expect(holding == 0, "\(mark)")
        }
        // A folder account's links are forgotten only after these checks, so the stop keeps them.
        let folders = FolderAccountsCLITests()
        for mark in ["lock on the file", "lock on the folder"] {
            let cli = try folders.setUp()
            defer { cli.cleanup() }
            try folders.linked(cli)
            #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0, "\(mark)")
            let links = HookRecord(context: context(cli)).linkState(for: "spare")
            #expect(links.linked && !links.entries.isEmpty, "\(mark)")
            let state = cli.dataRoot.appendingPathComponent("state")
            let entry =
                mark == "lock on the file" ? state.appendingPathComponent("leases.json") : state
            try lockEntry(entry)
            defer { _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", entry.path]) }

            let stopped = try cli.run(["remove", "spare"])
            #expect(stopped.status == 1, "\(mark)")
            #expect(
                said(stopped.stderr).contains("Error: Refused `~/.agent-balancer/state"),
                "\(mark)")
            #expect(HookRecord(context: context(cli)).linkState(for: "spare") == links, "\(mark)")
            #expect(
                try ConfigStore(context: context(cli)).loadRequired().account("spare") != nil,
                "\(mark)")
            try followRefusal(said(stopped.stderr), cli)
            let again = try cli.run(["remove", "spare"])
            #expect(again.status == 0, "\(mark)")
            #expect(
                try ConfigStore(context: context(cli)).loadRequired().account("spare") == nil,
                "\(mark)")
        }
    }

    @Test func aLeaseSaveThatFailsAfterItsCheckSaysWhatWasDeletedAndThatARerunFinishes() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let state = cli.dataRoot.appendingPathComponent("state")
        defer { _ = try? runChmod(["700", state.path]) }
        let token = try removeTokenFile(cli)
        let config = try ConfigStore(context: context(cli)).loadRequired()

        do {
            _ = try TokenAccounts.removeAccount(
                context: context(cli), label: "pool-a", config: config
            ) { _ in
                // A change to `state/` after the check, which only the save meets.
                let narrowed = try runChmod(["500", state.path])
                #expect(narrowed == 0)
            }
            Issue.record("the remove did not stop")
        } catch let error as ToolError {
            #expect(
                error.message
                    == "Could not write leases.json. The token file was deleted and the account was kept. Once the lease file can be saved, run `agent-balancer remove pool-a` again to finish the remove."
            )
        }
        #expect(!FileManager.default.fileExists(atPath: token.path))
        #expect(try registryHoldsPoolA(cli))
        #expect(try poolALeases(cli) == 1)
        let holding = launchFilesHolding(cli, secret)
        #expect(holding == 0)
        // The rerun's check names the fix, and the rerun after it finishes.
        let stopped = try cli.run(["remove", "pool-a"])
        #expect(stopped.status == 1)
        #expect(said(stopped.stderr).contains("Error: Refused `~/.agent-balancer/state`"))
        try followRefusal(said(stopped.stderr), cli)
        let again = try cli.run(["remove", "pool-a"])
        #expect(again.status == 0)
        #expect(try poolALeases(cli) == 0)
        #expect(try registryHoldsPoolA(cli) == false)

        // A folder account has no token file, so the text names only the account it kept.
        let folders = FolderAccountsCLITests()
        let spare = try folders.setUp()
        defer { spare.cleanup() }
        try folders.linked(spare)
        #expect(try spare.run(["pick", "--json", "--exclude", "main"]).status == 0)
        let spareState = spare.dataRoot.appendingPathComponent("state")
        defer { _ = try? runChmod(["700", spareState.path]) }
        let spareConfig = try ConfigStore(context: context(spare)).loadRequired()
        do {
            _ = try TokenAccounts.removeAccount(
                context: context(spare), label: "spare", config: spareConfig,
                keepsRecentPicks: false
            ) { _ in
                let narrowed = try runChmod(["500", spareState.path])
                #expect(narrowed == 0)
            }
            Issue.record("the folder account's remove did not stop")
        } catch let error as ToolError {
            #expect(
                error.message
                    == "Could not write leases.json. The account was kept. Once the lease file can be saved, run `agent-balancer remove spare` again to finish the remove."
            )
        }
        #expect(try ConfigStore(context: context(spare)).loadRequired().account("spare") != nil)
    }

    @Test func aFolderAccountsStopAfterItsLinksWereForgottenNamesTheLinkCommand() throws {
        let folders = FolderAccountsCLITests()
        let cli = try folders.setUp()
        defer { cli.cleanup() }
        try folders.linked(cli)
        let had = HookRecord(context: context(cli)).linkState(for: "spare")
        #expect(had.linked && !had.entries.isEmpty)
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        let launch = try #require(launchFiles(cli).first)
        try lockEntry(launch)
        defer { _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", launch.path]) }

        let stopped = try cli.run(["remove", "spare"])
        #expect(stopped.status == 1)
        let forgot =
            "The links of 'spare' were forgotten, so the account counts as not linked until `agent-balancer link spare` records them again."
        #expect(
            said(stopped.stderr).contains(
                "Error: " + Self.removeNotCleared(" The account was kept.", label: "spare") + " "
                    + forgot + "\n"))
        let left = HookRecord(context: context(cli)).linkState(for: "spare")
        #expect(!left.linked && left.entries.isEmpty)
        #expect(try ConfigStore(context: context(cli)).loadRequired().account("spare") != nil)
        // The command it names records the links again.
        let named = spans(said(stopped.stderr)).filter { $0.hasPrefix("agent-balancer link") }
        #expect(named == ["agent-balancer link spare"])
        let relinked = try cli.runOnTerminal(["link", "spare"], typing: "spare\n")
        #expect(relinked.status == 0, "\(said(relinked.stderr))")
        #expect(HookRecord(context: context(cli)).linkState(for: "spare") == had)
        guard try followNotCleared(said(stopped.stderr), cli) != nil else {
            Issue.record("the stop names no fix")
            return
        }
        let again = try cli.run(["remove", "spare"])
        #expect(again.status == 0)
        #expect(try ConfigStore(context: context(cli)).loadRequired().account("spare") == nil)
    }

    @Test func aFolderMissingUnderALockedFolderNamesTheUnlockFirstAndARerunPasses() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let root = launchRoot(cli)
        // The launch folder is there, made by another label's pick, and locked; `pool-a`'s is not.
        #expect(try cli.run(["run", "--print-command", "main"]).status == 0)
        try lockEntry(root)
        defer { _ = try? runNamedCapturing(["chflags", "nouchg,nouappnd", root.path]) }
        let place = "~/.agent-balancer/" + LaunchFiles.folder

        let stopped = try cli.run(["run", "--print-command", "pool-a"])
        #expect(stopped.status == 1)
        #expect(
            said(stopped.stderr).contains(
                "Error: Refused `" + place + "/pool-a`: it is missing and could not be made in `"
                    + place + "`. Run `chflags nouchg,nouappnd " + place
                    + "` first if it is locked, then `chmod -N " + place + "`, then `chmod 700 "
                    + place + "` in Terminal.\n"))
        try followRefusal(said(stopped.stderr), cli)
        let again = try cli.run(["run", "--print-command", "pool-a"])
        #expect(again.status == 0)
    }
}

/// A renamed `login` account's pick left its launch file under the old label: `remove` of an
/// account added later under that label leaves the file as its pick wrote it, for a folder and a
/// token account, and still stops while a launch file of the label holds a token.
extension PersonCommandsCLITests {
    /// Makes a pick of the `login` account `main` in `cli`, with the caller settings `settings`
    /// when given, then renames it `primary`. Returns the launch file that pick wrote under
    /// `main` and its bytes.
    func renamedLoginPick(_ cli: CLIHome, settings: String? = nil) throws -> (
        file: URL, bytes: Data
    ) {
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        try cli.fake("default.exit", "0")
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                expectedPlanTier: "max_20x")
        ])
        config.fable.probe = false
        if settings != nil {
            config.launch = LaunchSettings(
                settingsKeys: ["env", "crossSessionInbound"], envNames: ["CLAUDE_ROLE"])
        }
        try ConfigStore(context: context(cli)).save(config)
        try HookRecord(context: context(cli)).record(.empty)
        let caller = settings.map { ["--settings", $0] } ?? []
        #expect(try cli.run(["pick", "--json"] + caller).status == 0)
        let file = try #require(launchFiles(cli).first)
        let bytes = try Data(contentsOf: file)
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        return (file, bytes)
    }

    @Test func removeUnderARenamedAccountsOldLabelLeavesItsLaunchFileAsItsPickWroteIt() throws {
        for kind in [Kind.folder, Kind.token] {
            let cli = try CLIHome()
            defer { cli.cleanup() }
            let (file, written) = try renamedLoginPick(cli)
            let added = try cli.run(["add", "main", "--kind", kind])
            #expect(added.status == 0, "\(kind): \(said(added.stderr))")
            if kind == Kind.token {
                _ = try TokenAccounts.install(
                    context: context(cli), label: "main", token: Canary.realShapeToken())
            }

            let removed = try cli.run(["remove", "main"])
            #expect(removed.status == 0, "\(kind): \(said(removed.stderr))")
            #expect((try? Data(contentsOf: file)) == written, "\(kind)")
            #expect(said(removed.stdout).contains("Kept 1 launch files"), "\(kind)")
            let open = try LeaseStore(context: context(cli)).current(
                now: Date(), leaseMinutes: 10)
            #expect(open.map(\.label) == ["primary"], "\(kind)")
            #expect(try ConfigStore(context: context(cli)).loadRequired().account("main") == nil)
        }
    }

    @Test func removeUnderARenamedAccountsOldLabelStillStopsWhileALaunchFileHoldsAToken() throws {
        let cli = try CLIHome()
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        let (file, written) = try renamedLoginPick(cli)
        #expect(try cli.run(["add", "main", "--kind", Kind.token]).status == 0)
        let secret = Canary.realShapeToken()
        _ = try TokenAccounts.install(context: context(cli), label: "main", token: secret)
        #expect(try cli.run(["run", "--print-command", "main"]).status == 0)
        let own = try #require(
            launchFiles(cli).first { $0.lastPathComponent != file.lastPathComponent })
        try denyOwnerOf(own, "delete")
        let token = try TokenPaths.fileURL(context: context(cli), label: "main")
        let folder = file.deletingLastPathComponent()

        let stopped = try cli.run(["remove", "main"])
        #expect(stopped.status == 1)
        let kept = " The token file and the account were kept."
        #expect(
            said(stopped.stderr).contains(
                "Error: " + Self.removeNotCleared(kept, label: "main") + "\n"))
        #expect(FileManager.default.fileExists(atPath: token.path))
        #expect(try ConfigStore(context: context(cli)).loadRequired().account("main") != nil)
        #expect((try? Data(contentsOf: file)) == written)
        let held = filesHolding(folder, secret)
        #expect(held == 1)
        guard try followNotCleared(said(stopped.stderr), cli) != nil else {
            Issue.record("the stop names no fix")
            return
        }
        let again = try cli.run(["remove", "main"])
        #expect(again.status == 0)
        #expect(!FileManager.default.fileExists(atPath: token.path))
        #expect((try? Data(contentsOf: file)) == written)
        let holding = launchFilesHolding(cli, secret)
        #expect(holding == 0)
    }

    /// Writes `secret` into the launch file `file` at `placement`, at 0600, as a hand edit could:
    /// the token variable, another credential name, a top-level `apiKeyHelper`, an `env` value
    /// that is not a string, a value a pick never writes for `disableAllHooks`,
    /// `crossSessionInbound` or the account variable, or inside a string a pick may write, also
    /// with its first character as a JSON escape. A `disableAllHooks` of `true` or 0 holds none.
    func plantToken(_ file: URL, _ secret: String, at placement: String) throws {
        let data = try Data(contentsOf: file)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var env = object["env"] as? [String: Any]
        else {
            Issue.record("the launch file does not parse")
            return
        }
        switch placement {
        case "token variable": env[ProtectedEnv.tokenVariable] = secret
        case "another credential name": env["ANTHROPIC_AUTH_TOKEN"] = secret
        case "apiKeyHelper": object["apiKeyHelper"] = "echo " + secret
        case "env value not a string": env["CLAUDE_ROLE"] = ["value": secret]
        case "hooks key token": object[CallerSettings.hooksKey] = secret
        case "hooks key true": object[CallerSettings.hooksKey] = true
        case "hooks key 0": object[CallerSettings.hooksKey] = 0
        case "account variable token": env[LaunchFiles.accountVariable] = secret
        case "inbound not a string": object["crossSessionInbound"] = ["value": secret]
        case "inbound string": object["crossSessionInbound"] = "accept " + secret + " only"
        default: env["CLAUDE_ROLE"] = "reviewer-" + secret + "-b"
        }
        object["env"] = env
        var out = try JSONSerialization.data(withJSONObject: object)
        if placement == "allowed env value escaped" {
            let first = try #require(secret.unicodeScalars.first)
            let escaped = "\\u" + String(format: "%04x", first.value) + secret.dropFirst()
            let text = String(decoding: out, as: UTF8.self)
            out = Data(text.replacingOccurrences(of: secret, with: escaped).utf8)
            #expect(out.range(of: Data(secret.utf8)) == nil)
        }
        try out.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// What `remove main` stops with when `file`, the renamed account's launch file, may hold a
    /// token, for an account of `kind`: a `token` account's text also says the file may hold its
    /// token.
    static func removeOthersNotAsWritten(_ file: URL, _ kept: String, kind: String) -> String {
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/main"
        let holds = kind == Kind.token ? "holds the token of 'main', " : ""
        return
            "A launch file of another account's open pick may hold a token: `" + place + "/"
            + file.lastPathComponent + "` does not have the shape a pick writes, " + holds
            + "or cannot be read. `remove` left it as it is.\(kept) Once that pick no longer needs the file, move it out of `"
            + place + "`, then run `agent-balancer remove main` again."
    }

    /// What `remove main` stops with when the token file of `main` gives no token to compare
    /// with `file`, the renamed account's launch file.
    static func removeTokenUnread(_ file: URL, _ kept: String) -> String {
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/main"
        return
            "`remove` cannot read the token of 'main' from its token file, so it cannot check whether a launch file of another account's open pick holds it: `"
            + place + "/" + file.lastPathComponent
            + "`. `remove` left it as it is.\(kept) Once that pick no longer needs the file, move it out of `"
            + place + "`, then run `agent-balancer remove main` again."
    }

    /// Plants the removed account's token at `placement` in the renamed account's launch file,
    /// with `delete` denied on it when `denied`, and expects `remove main` of an account of
    /// `kind` to stop before any change: the file, the token file, the account, the links and
    /// the leases as they were. On a plain arm, once the file is moved out as the text says, a
    /// rerun finishes.
    func expectStopBeforeAnyChange(kind: String, placement: String, denied: Bool) throws {
        let name = kind + ", " + placement + (denied ? ", delete denied" : "")
        let cli = try CLIHome()
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        let (file, _) = try renamedLoginPick(cli)
        #expect(try cli.run(["add", "main", "--kind", kind]).status == 0, "\(name)")
        let secret = Canary.realShapeToken()
        if kind == Kind.token {
            _ = try TokenAccounts.install(context: context(cli), label: "main", token: secret)
        } else {
            try HookRecord(context: context(cli)).saveLinks(
                label: "main", entries: [], linked: true)
        }
        try plantToken(file, secret, at: placement)
        if denied { try denyOwnerOf(file, "delete") }
        let state = cli.dataRoot.appendingPathComponent("state")
        let watched = [
            file, try TokenPaths.fileURL(context: context(cli), label: "main"),
            cli.dataRoot.appendingPathComponent(ConfigStore.fileName),
            cli.dataRoot.appendingPathComponent(HookRecord.fileName),
            state.appendingPathComponent("leases.json"),
        ]
        let before = watched.map { try? Data(contentsOf: $0) }

        let removed = try cli.run(["remove", "main"])
        #expect(removed.status == 1, "\(name)")
        #expect(
            said(removed.stderr).contains(
                "Error: " + Self.removeOthersNotAsWritten(file, Self.nothingDeleted, kind: kind)
                    + "\n"), "\(name)")
        // Nothing changed: the file, the token file, the account, the links and the leases are
        // as they were.
        #expect(watched.map { try? Data(contentsOf: $0) } == before, "\(name)")
        #expect(
            try ConfigStore(context: context(cli)).loadRequired().account("main") != nil,
            "\(name)")
        guard !denied else { return }
        // What the text says lets a rerun finish.
        let moved = cli.home.appendingPathComponent(file.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: file, to: moved)
        } catch {
            Issue.record("the file could not be moved out: \(name)")
            return
        }
        let again = try cli.run(["remove", "main"])
        #expect(again.status == 0, "\(name)")
        #expect(!FileManager.default.fileExists(atPath: watched[1].path), "\(name)")
        #expect(
            try ConfigStore(context: context(cli)).loadRequired().account("main") == nil,
            "\(name)")
        #expect((try? Data(contentsOf: moved)) == before[0], "\(name)")
    }

    @Test func aRenamedAccountsLaunchFileWithoutAPicksShapeStopsTheRemoveFirst() throws {
        let placements = [
            "token variable", "another credential name", "apiKeyHelper", "env value not a string",
        ]
        for kind in [Kind.token, Kind.folder] {
            for placement in placements {
                for denied in [false, true] {
                    try expectStopBeforeAnyChange(kind: kind, placement: placement, denied: denied)
                }
            }
        }
    }

    @Test func aRenamedAccountsLaunchFileWithAValueNoPickWritesStopsTheRemoveFirst() throws {
        let placements = [
            "hooks key token", "hooks key true", "hooks key 0", "account variable token",
            "inbound not a string",
        ]
        for kind in [Kind.token, Kind.folder] {
            for placement in placements {
                for denied in [false, true] {
                    try expectStopBeforeAnyChange(kind: kind, placement: placement, denied: denied)
                }
            }
        }
    }

    @Test func aRenamedAccountsLaunchFileHoldingTheRemovedTokenStopsTheRemoveFirst() throws {
        // A pick's shape, so only the token in its bytes stops it; a folder account has none.
        for placement in ["inbound string", "allowed env value", "allowed env value escaped"] {
            for denied in [false, true] {
                try expectStopBeforeAnyChange(
                    kind: Kind.token, placement: placement, denied: denied)
            }
        }
    }

    /// A tombstone the tool wrote, moved onto the launch file a renamed account's pick left under
    /// `main`: a token account's pick under `main`, then its remove, which made it. Returns that
    /// file and its bytes.
    func renamedPickAsATombstone(_ cli: CLIHome) throws -> (file: URL, bytes: Data) {
        let (file, _) = try renamedLoginPick(cli)
        #expect(try cli.run(["add", "main", "--kind", Kind.token]).status == 0)
        _ = try TokenAccounts.install(
            context: context(cli), label: "main", token: Canary.realShapeToken())
        #expect(try cli.run(["run", "--print-command", "main"]).status == 0)
        let own = try #require(
            launchFiles(cli).first { $0.lastPathComponent != file.lastPathComponent })
        let removed = try cli.run(["remove", "main"])
        #expect(removed.status == 0)
        let written = try Data(contentsOf: own)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(LaunchFiles.isTombstone(object))
        #expect(rename(own.path, file.path) == 0)
        return (file, written)
    }

    @Test func aRenamedAccountsLaunchFileInAPicksShapeStaysAndTheRemoveFinishes() throws {
        let settings = "{\"crossSessionInbound\":\"accept\",\"env\":{\"CLAUDE_ROLE\":\"reviewer\"}}"
        for kind in [Kind.token, Kind.folder] {
            for shape in ["caller settings", "tombstone", "real pick", "real tombstone"] {
                let name = kind + ", " + shape
                let cli = try CLIHome()
                defer { cli.cleanup() }
                let picked =
                    shape == "real tombstone"
                    ? try renamedPickAsATombstone(cli)
                    : try renamedLoginPick(cli, settings: shape == "real pick" ? settings : nil)
                let file = picked.file
                var written = picked.bytes
                #expect(try cli.run(["add", "main", "--kind", kind]).status == 0, "\(name)")
                let secret = Canary.realShapeToken()
                if kind == Kind.token {
                    _ = try TokenAccounts.install(
                        context: context(cli), label: "main", token: secret)
                }
                if shape == "real pick" {
                    let object = try JSONSerialization.jsonObject(with: written) as? [String: Any]
                    let env = object?["env"] as? [String: String]
                    #expect(object?["crossSessionInbound"] as? String == "accept", "\(name)")
                    #expect(object?[CallerSettings.hooksKey] as? Bool == false, "\(name)")
                    #expect(env?[LaunchFiles.accountVariable] == "main", "\(name)")
                    #expect(env?["CLAUDE_ROLE"] == "reviewer", "\(name)")
                } else if !shape.hasPrefix("real") {
                    // What a pick with caller settings writes, or a tombstone.
                    var object: [String: Any] = [
                        "env": [
                            LaunchFiles.accountVariable: "main", "CLAUDE_ROLE": "reviewer",
                        ],
                        "crossSessionInbound": "accept", "disableAllHooks": false,
                    ]
                    if shape == "tombstone" {
                        object = [
                            "env": [
                                LaunchFiles.accountVariable: "main",
                                ProtectedEnv.tokenVariable: LaunchFiles.tombstoneValue,
                            ]
                        ]
                    }
                    written = try JSONSerialization.data(
                        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    try written.write(to: file)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: file.path)
                }

                let removed = try cli.run(["remove", "main"])
                #expect(removed.status == 0, "\(name): \(said(removed.stderr))")
                #expect((try? Data(contentsOf: file)) == written, "\(name)")
                #expect(said(removed.stdout).contains("Kept 1 launch files"), "\(name)")
                #expect(
                    try ConfigStore(context: context(cli)).loadRequired().account("main") == nil,
                    "\(name)")
                let holding = launchFilesHolding(cli, secret)
                #expect(holding == 0, "\(name)")
            }
        }
    }

    @Test func aRenamedAccountsLaunchFileChangedAfterTheCheckStopsTheReadBack() throws {
        let arms = [
            (Kind.token, "another credential name"), (Kind.folder, "another credential name"),
            (Kind.token, "allowed env value"),
        ]
        for (kind, placement) in arms {
            let name = kind + ", " + placement
            let cli = try CLIHome()
            defer { cli.cleanup() }
            let (file, _) = try renamedLoginPick(cli)
            #expect(try cli.run(["add", "main", "--kind", kind]).status == 0, "\(name)")
            let secret = Canary.realShapeToken()
            if kind == Kind.token {
                _ = try TokenAccounts.install(context: context(cli), label: "main", token: secret)
            }
            let token = try TokenPaths.fileURL(context: context(cli), label: "main")
            let config = try ConfigStore(context: context(cli)).loadRequired()
            var planted: Data?

            do {
                _ = try TokenAccounts.removeAccount(
                    context: context(cli), label: "main", config: config,
                    keepsRecentPicks: kind != Kind.folder
                ) { _ in
                    // A change after the first check, which only the read-back meets.
                    try plantToken(file, secret, at: placement)
                    planted = try Data(contentsOf: file)
                }
                Issue.record("the remove did not stop: \(name)")
            } catch let error as ToolError {
                let kept =
                    kind == Kind.token
                    ? " The token file and the account were kept." : " The account was kept."
                #expect(
                    error.message == Self.removeOthersNotAsWritten(file, kept, kind: kind),
                    "\(name)")
            }
            #expect(
                FileManager.default.fileExists(atPath: token.path) == (kind == Kind.token),
                "\(name)")
            #expect(
                try ConfigStore(context: context(cli)).loadRequired().account("main") != nil,
                "\(name)")
            #expect(planted != nil && (try? Data(contentsOf: file)) == planted, "\(name)")
        }
    }

    @Test func anUnreadableTokenFileStopsTheRemoveWhileARenamedAccountsLaunchFileIsThere() throws {
        for how in ["mode 000", "read denied"] {
            let cli = try CLIHome()
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            let (file, _) = try renamedLoginPick(cli)
            #expect(try cli.run(["add", "main", "--kind", Kind.token]).status == 0, "\(how)")
            _ = try TokenAccounts.install(
                context: context(cli), label: "main", token: Canary.realShapeToken())
            let token = try TokenPaths.fileURL(context: context(cli), label: "main")
            let state = cli.dataRoot.appendingPathComponent("state")
            let watched = [
                file, token, cli.dataRoot.appendingPathComponent(ConfigStore.fileName),
                state.appendingPathComponent("leases.json"),
            ]
            let before = watched.map { try? Data(contentsOf: $0) }
            func unreadable() throws {
                guard FileManager.default.fileExists(atPath: token.path) else {
                    Issue.record("the token file is gone: \(how)")
                    return
                }
                if how == "mode 000" {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0], ofItemAtPath: token.path)
                } else {
                    try denyOwnerOf(token, "read")
                }
                #expect(!FileManager.default.isReadableFile(atPath: token.path), "\(how)")
            }
            func readable() {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: token.path)
                clearAccessLists(cli)
            }
            defer { readable() }
            try unreadable()

            let stopped = try cli.run(["remove", "main"])
            #expect(stopped.status == 1, "\(how)")
            #expect(
                said(stopped.stderr).contains(
                    "Error: " + Self.removeTokenUnread(file, Self.nothingDeleted) + "\n"),
                "\(how)")
            readable()
            // Nothing changed: the file, the token file, the account and the leases.
            #expect(watched.map { try? Data(contentsOf: $0) } == before, "\(how)")
            #expect(
                try ConfigStore(context: context(cli)).loadRequired().account("main") != nil,
                "\(how)")

            // With no such file in the folder, the remove goes on as before.
            try unreadable()
            let moved = cli.home.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: moved)
            let again = try cli.run(["remove", "main"])
            #expect(again.status == 0, "\(how)")
            #expect(!FileManager.default.fileExists(atPath: token.path), "\(how)")
            #expect(
                try ConfigStore(context: context(cli)).loadRequired().account("main") == nil,
                "\(how)")
            #expect((try? Data(contentsOf: moved)) == before[0], "\(how)")
        }
    }

    @Test func aFolderAccountWithNoLinksStopsWithoutTheLinksSentence() throws {
        let cli = try CLIHome()
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        let (file, written) = try renamedLoginPick(cli)
        #expect(try cli.run(["add", "main", "--kind", Kind.folder]).status == 0)
        // A launch file of the label's own that the remove cannot delete.
        let own = file.deletingLastPathComponent().appendingPathComponent("l-0000beef.json")
        try written.write(to: own)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: own.path)
        try denyOwnerOf(own, "delete")

        let stopped = try cli.run(["remove", "main"])
        #expect(stopped.status == 1)
        #expect(
            said(stopped.stderr).contains(
                "Error: " + Self.removeNotCleared(" The account was kept.", label: "main") + "\n"))
        #expect(try ConfigStore(context: context(cli)).loadRequired().account("main") != nil)
    }
}

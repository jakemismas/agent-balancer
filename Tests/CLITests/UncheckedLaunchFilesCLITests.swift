import Core
import Foundation
import Testing

@testable import Core

private func said(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// A launch file or a token file whose access list denies you `readattr`, so `lstat` cannot check
/// it, may hold a token: `pick` and `run` name a launch file their cleanup could not check,
/// `login` names the launch files its rewrite passed by and exits 1, `doctor` and `status` call
/// such a file one that cannot be checked and count it, and `add` refuses a label whose token
/// file it cannot check. Once the commands a text names run as written, the next step goes on.
extension PersonCommandsCLITests {
    static let poolAPlace = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"

    /// What `command` adds to its error about the launch file `name` of `pool-a` that it wrote and
    /// could not check, ending with the command the person ran, `rerun`.
    static func launchFileLeft(_ name: String, _ command: String, _ rerun: String) -> String {
        let file = poolAPlace + "/" + name
        return
            "The launch file `\(file)` that `\(command)` wrote could not be checked, so it was not deleted and may still hold the token of 'pool-a'. Run `chmod -h -N \(poolAPlace)` and `chmod -h -N \(file)`, or `chmod -N \(file)` if that says Permission denied. Run `chflags -h nouchg,nouappnd \(poolAPlace)` first if it is locked. Then run your `\(rerun)` command again. The upkeep that `agent-balancer pick` and `agent-balancer refresh` run deletes the file later, as it deletes the file of any pick that holds no lease."
    }

    /// What `login` says about the launch file `name` of `pool-a` its rewrite could not check,
    /// rewrite or delete.
    static func loginPassedBy(_ name: String) -> String {
        "1 launch file of 'pool-a' could not be checked, rewritten or deleted: `\(poolAPlace)/\(name)`. It may keep the old token, and a session that uses the file keeps that token until it ends. Run `chflags -h nouchg,nouappnd` first on `\(poolAPlace)` and on that file if either is locked. Then run `chmod -h -N \(poolAPlace)` and `chmod -h 700 \(poolAPlace)`, and on that file `chmod -h -N`, or `chmod -N` if that says Permission denied, then `chmod -h 600`."
    }

    /// What `login` says about the writer's temporary file `name` it could not delete in the
    /// folder `place`.
    static func temporaryLeft(_ place: String, _ name: String) -> String {
        "1 temporary file the writer left in `\(place)` could not be deleted and may hold a token: `\(place)/\(name)`. Run `chflags -h nouchg,nouappnd` first on `\(place)` and on that file if either is locked. Then run `chmod -h -N \(place)` and `chmod -h 700 \(place)`, and on that file `chmod -h -N`, or `chmod -N` if that says Permission denied."
    }

    /// What `login` says about the two writer temporary files `names` it could not delete in the
    /// folder `place`.
    static func twoTemporariesLeft(_ place: String, _ names: [String]) -> String {
        "2 temporary files the writer left in `\(place)` could not be deleted and may hold a token: `\(place)/\(names[0])` and `\(place)/\(names[1])`. Run `chflags -h nouchg,nouappnd` first on `\(place)` and on each of these files that is locked. Then run `chmod -h -N \(place)` and `chmod -h 700 \(place)`, and on each of these files `chmod -h -N`, or `chmod -N` where that says Permission denied."
    }

    /// A copy of the launch file of `pool-a`, or of its token file, named `name` in the same
    /// folder, so it holds the token saved now, as a write that stopped before its rename leaves
    /// one.
    func leftTemporary(_ cli: CLIHome, inTokenFolder: Bool, name: String) throws -> URL {
        let source: URL
        if inTokenFolder {
            source = try TokenPaths.fileURL(
                context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
        } else {
            source = try #require(launchFiles(cli).first)
        }
        let temporary = source.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: temporary)
        return temporary
    }

    /// Writes the record of a live session, this test's own process, that names the launch file
    /// `file`.
    func nameLaunchFile(_ file: URL, session: String, in cli: CLIHome) throws {
        let sessions = cli.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "pid": Int(getpid()), "sessionId": session, "name": "w1",
            "args": "--settings " + file.path,
        ]
        try JSONSerialization.data(withJSONObject: record).write(
            to: sessions.appendingPathComponent("\(getpid()).json"))
    }

    /// Runs what a token save's text about files it could not check, rewrite or delete names, as
    /// written, on the line of `shown` that holds `marker`: the `chflags` first on the folder and
    /// on each file the line names that is locked, then the folder's commands, then on each file
    /// the file command, the one for Permission denied where the file command says so, and the
    /// mode command when the line names one. Returns how many files needed the one for Permission
    /// denied, or nil when the line names other commands.
    func followNamedFiles(_ shown: String, _ marker: String, _ cli: CLIHome) throws -> Int? {
        guard let line = shown.split(separator: "\n").first(where: { $0.contains(marker) })
        else { return nil }
        let named = spans(String(line)).map { span in
            span.split(separator: " ").map { word in
                word.hasPrefix("~") ? cli.home.path + String(word.dropFirst()) : String(word)
            }
        }
        let unlock = named.filter { $0.first == "chflags" && $0.count == 3 }
        let folder = named.filter { $0.first == "chmod" && $0.count == 4 }
        let file = named.filter { $0.first == "chmod" && $0.count < 4 }
        guard unlock.count == 1, folder.count == 2, file.count >= 2,
            let place = folder[0].last
        else { return nil }
        let files = named.filter { $0.count == 1 && $0[0].hasPrefix(place + "/") }.map {
            URL(fileURLWithPath: $0[0])
        }
        for entry in [URL(fileURLWithPath: place)] + files where isFlagged(entry) {
            let done = try runNamedCapturing(unlock[0] + [entry.path])
            #expect(done.status == 0, "\(done.error)")
        }
        for command in folder {
            let done = try runNamedCapturing(command)
            #expect(done.status == 0, "\(command): \(done.error)")
        }
        var denied = 0
        for entry in files {
            if try runOrDenied(file[0], file[1], entry) { denied += 1 }
            if file.count > 2 {
                let done = try runNamedCapturing(file[2] + [entry.path])
                #expect(done.status == 0, "\(done.error)")
            }
        }
        return denied
    }

    /// Runs what a text about a launch file left behind names, as written: the `chflags` first
    /// when the folder it names is locked, the folder command, then the file command, and the one
    /// for Permission denied where the file command says so. Returns whether that one ran.
    func followLeftFile(_ shown: String, _ cli: CLIHome) throws -> Bool? {
        let named = namedCommands(shown, "could not be checked", home: cli.home)
        let commands = named.filter { $0.first == "chmod" }
        guard commands.count == 3 else { return nil }
        try unlockNamed(named)
        let folder = try runNamedCapturing(commands[0])
        #expect(folder.status == 0, "\(folder.error)")
        let file = try runNamedCapturing(commands[1])
        guard file.status != 0 else { return false }
        #expect(file.error.contains("Permission denied"), "\(file.error)")
        #expect(try runNamedCapturing(commands[2]).status == 0)
        return true
    }

    /// The entry in `folder` that is not among `before`.
    func newEntry(in folder: URL, besides before: Set<URL>) -> URL? {
        entries(in: folder).first { !before.contains($0) }
    }

    func isCheckable(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    // MARK: pick and run

    @Test func aLaunchFilePickCouldNotCheckIsNamedAndAPickAfterItsCommandsPasses() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        try cli.fakeProbe("ok.jsonl")
        let pick = ["pick", "--caller", "launcher", "--exclude", "main"]
        // A first pick stores a reading and makes the label's launch folder.
        #expect(try cli.run(pick).status == 0)
        let folder = launchRoot(cli).appendingPathComponent("pool-a")
        let before = Set(entries(in: folder))
        // Each launch file written in the folder from now on takes the entry.
        try denyOwnerOf(folder, "readattr,file_inherit,only_inherit")
        let state = cli.dataRoot.appendingPathComponent("state")
        chmod(state.path, 0o500)
        defer { chmod(state.path, 0o700) }
        let stopped = try cli.run(pick)
        chmod(state.path, 0o700)
        #expect(stopped.status == 1)
        let left = try #require(newEntry(in: folder, besides: before))
        #expect(!isCheckable(left))
        let shown = said(stopped.stderr)
        #expect(
            shown
                == "Error: Could not write leases.json. "
                + Self.launchFileLeft(left.lastPathComponent, "pick", "agent-balancer pick")
                + "\n")

        #expect(try followLeftFile(shown, cli) == false)
        #expect(isCheckable(left))
        let again = try cli.run(pick)
        #expect(again.status == 0, "\(said(again.stderr))")
        // The file the stopped pick left is one upkeep deletes once it is old enough.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: left.path)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(!FileManager.default.fileExists(atPath: left.path))
    }

    @Test func aLaunchFileRunCouldNotCheckOnceClaudeFailedToStartIsNamedAndARunAfterItPasses()
        throws
    {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let folder = try #require(launchFiles(cli).first).deletingLastPathComponent()
        let before = Set(entries(in: folder))
        try denyOwnerOf(folder, "readattr,file_inherit,only_inherit")
        // A program the lookup accepts and that cannot be started.
        let fake = try Data(contentsOf: cli.fakePath)
        try Data("#!/nonexistent/interpreter\n".utf8).write(to: cli.fakePath)
        let stopped = try cli.run(["run", "pool-a"])
        #expect(stopped.status == 1)
        let left = try #require(newEntry(in: folder, besides: before))
        let shown = said(stopped.stderr)
        #expect(
            shown
                == "Error: Could not start claude. "
                + Self.launchFileLeft(left.lastPathComponent, "run", "agent-balancer run pool-a")
                + "\n")
        #expect(!cli.fakeRecord("args.log").contains("--settings"))

        #expect(try followLeftFile(shown, cli) == false)
        try fake.write(to: cli.fakePath)
        let again = try cli.run(["run", "pool-a"])
        #expect(again.status == 0, "\(said(again.stderr))")
        #expect(cli.fakeRecord("args.log").contains("--settings"))
    }

    @Test func aLaunchFileRunCouldNotCheckAfterItsLeaseSaveFailedIsNamed() throws {
        // The text names the command the person ran, `--print-command` included.
        for arguments in [["run", "pool-a"], ["run", "--print-command", "pool-a"]] {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let folder = try #require(launchFiles(cli).first).deletingLastPathComponent()
            let before = Set(entries(in: folder))
            try denyOwnerOf(folder, "readattr,file_inherit,only_inherit")
            let state = cli.dataRoot.appendingPathComponent("state")
            chmod(state.path, 0o500)
            defer { chmod(state.path, 0o700) }
            let stopped = try cli.run(arguments)
            chmod(state.path, 0o700)
            let rerun = "agent-balancer " + arguments.joined(separator: " ")
            #expect(stopped.status == 1, "\(rerun)")
            let left = try #require(newEntry(in: folder, besides: before))
            #expect(
                said(stopped.stderr)
                    == "Error: Could not write leases.json. "
                    + Self.launchFileLeft(left.lastPathComponent, "run", rerun) + "\n",
                "\(rerun)")
            #expect(!cli.fakeRecord("args.log").contains("--settings"), "\(rerun)")
        }
    }

    @Test func aLaunchFileOfALoginAccountIsNamedWithoutSayingItHoldsAToken() throws {
        // A login account's launch file holds no token, so its text leaves that out.
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/main"
        let pick = ["pick", "--caller", "launcher", "--exclude", "pool-a"]
        for arguments in [pick, ["run", "main"]] {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            try cli.fakeProbe("ok.jsonl")
            // A first pick of the login account makes its launch folder.
            #expect(try cli.run(pick).status == 0)
            let folder = launchRoot(cli).appendingPathComponent("main")
            let before = Set(entries(in: folder))
            try denyOwnerOf(folder, "readattr,file_inherit,only_inherit")
            let state = cli.dataRoot.appendingPathComponent("state")
            chmod(state.path, 0o500)
            defer { chmod(state.path, 0o700) }
            let stopped = try cli.run(arguments)
            chmod(state.path, 0o700)
            let command = arguments[0]
            let rerun = command == "run" ? "agent-balancer run main" : "agent-balancer pick"
            #expect(stopped.status == 1, "\(command)")
            let left = try #require(newEntry(in: folder, besides: before))
            let file = place + "/" + left.lastPathComponent
            #expect(
                said(stopped.stderr)
                    == "Error: Could not write leases.json. The launch file `\(file)` that `\(command)` wrote could not be checked, so it was not deleted. Run `chmod -h -N \(place)` and `chmod -h -N \(file)`, or `chmod -N \(file)` if that says Permission denied. Run `chflags -h nouchg,nouappnd \(place)` first if it is locked. Then run your `\(rerun)` command again. The upkeep that `agent-balancer pick` and `agent-balancer refresh` run deletes the file later, as it deletes the file of any pick that holds no lease.\n",
                "\(command)")
        }
    }

    @Test func aLaunchFileOfAFolderAccountIsNamedWithoutSayingItHoldsAToken() throws {
        // A folder account's launch file holds no token either, so its text leaves that out.
        let folders = FolderAccountsCLITests()
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/spare"
        let pick = ["pick", "--caller", "launcher", "--exclude", "main"]
        for arguments in [pick, ["run", "spare"], ["run", "--print-command", "spare"]] {
            let cli = try folders.setUp()
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            try folders.linked(cli)
            // A first pick of the folder account makes its launch folder.
            #expect(try cli.run(pick).status == 0)
            let folder = launchRoot(cli).appendingPathComponent("spare")
            let before = Set(entries(in: folder))
            try denyOwnerOf(folder, "readattr,file_inherit,only_inherit")
            let state = cli.dataRoot.appendingPathComponent("state")
            chmod(state.path, 0o500)
            defer { chmod(state.path, 0o700) }
            let stopped = try cli.run(arguments)
            chmod(state.path, 0o700)
            let command = arguments[0]
            let typed = command == "run" ? arguments.joined(separator: " ") : "pick"
            let rerun = "agent-balancer " + typed
            #expect(stopped.status == 1, "\(rerun)")
            let left = try #require(newEntry(in: folder, besides: before), "\(rerun)")
            let file = place + "/" + left.lastPathComponent
            #expect(
                said(stopped.stderr)
                    == "Error: Could not write leases.json. The launch file `\(file)` that `\(command)` wrote could not be checked, so it was not deleted. Run `chmod -h -N \(place)` and `chmod -h -N \(file)`, or `chmod -N \(file)` if that says Permission denied. Run `chflags -h nouchg,nouappnd \(place)` first if it is locked. Then run your `\(rerun)` command again. The upkeep that `agent-balancer pick` and `agent-balancer refresh` run deletes the file later, as it deletes the file of any pick that holds no lease.\n",
                "\(rerun)")
        }
    }

    // MARK: login

    @Test func aLaunchFileLoginCannotCheckAfterTheSignInIsNamedAndLoginExitsOne() throws {
        let old = Canary.realShapeToken()
        let cli = try setUp(token: old)
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        try cli.fakeProbe("ok.jsonl")
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        // The entry comes while the person approves in the browser, after the checks passed.
        try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
        try cli.fake(
            "during-setup-token.sh",
            "/bin/chmod +a '\(NSUserName()) deny readattr' '\(launch.path)'\n")
        let out = try cli.run(["login", "pool-a"])
        #expect(out.status == 1)
        let shown = said(out.stdout)
        #expect(shown.contains("Saved the token for 'pool-a'.\n"))
        #expect(shown.contains("Rewrote 0 launch files with the new token."))
        #expect(shown.contains("\nError: " + Self.loginPassedBy(launch.lastPathComponent) + "\n"))
        #expect(shown.contains("\nFirst check: read"))
        #expect(
            shown.hasSuffix(
                "The new token for 'pool-a' is saved, so no new sign-in is needed. Once the above is fixed, run `agent-balancer refresh --label pool-a` to check it.\n"
            ))

        // As written: the locks, the folder's commands, then the commands on each file it names.
        #expect(try followNamedFiles(shown, "could not be checked, rewritten or deleted", cli) == 0)
        // The file the rewrite passed by keeps the old token, as the text says.
        let holding = launchFilesHolding(cli, old)
        #expect(holding == 1)
        try FileManager.default.removeItem(
            at: cli.home.appendingPathComponent(".ab-fake/during-setup-token.sh"))
        let refresh = try cli.run(["refresh", "--label", "pool-a"])
        #expect(refresh.status == 0, "\(said(refresh.stdout))")
    }

    @Test func aLoginNamesEachLaunchFileItsRewritePassedByHoweverManyThereAre() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        try cli.fakeProbe("ok.jsonl")
        for _ in 0..<24 { _ = try cli.run(["run", "--print-command", "pool-a"]) }
        let folder = try #require(launchFiles(cli).first).deletingLastPathComponent()
        let names = entries(in: folder).map(\.lastPathComponent).sorted()
        #expect(names.count == 24)
        try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
        try cli.fake(
            "during-setup-token.sh",
            "for f in '\(folder.path)'/l-*.json; do /bin/chmod +a '\(NSUserName()) deny readattr' \"$f\"; done\n"
        )
        let out = try cli.run(["login", "pool-a"])
        #expect(out.status == 1)
        let paths = names.map { "`" + Self.poolAPlace + "/" + $0 + "`" }
        let line =
            "Error: 24 launch files of 'pool-a' could not be checked, rewritten or deleted: "
            + paths.dropLast().joined(separator: ", ") + " and " + (paths.last ?? "")
            + ". Each may keep the old token"
        let shown = said(out.stdout)
        #expect(shown.contains("\n" + line))
        #expect(shown.contains("then `chmod -h 600`.\nFirst check: read"))
        #expect(try followNamedFiles(shown, "could not be checked, rewritten or deleted", cli) == 0)
    }

    @Test func aLaunchFileLoginCouldNotReadOrDeleteIsNamedAndLoginExitsOne() throws {
        // What lands while the person signs in: a list that denies reading and deleting it, or
        // no mode and a lock. The rewrite cannot read the file, and its delete fails.
        let cases = [
            ("list", "/bin/chmod +a '\(NSUserName()) deny read,delete' '@'"),
            ("mode and lock", "/bin/chmod 000 '@'; /usr/bin/chflags uchg '@'"),
        ]
        for (name, hook) in cases {
            let old = Canary.realShapeToken()
            let cli = try setUp(token: old)
            defer { cli.cleanup() }
            defer {
                for file in launchFiles(cli) { chmod(file.path, 0o600) }
                clearAccessLists(cli)
            }
            try cli.fakeProbe("ok.jsonl")
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let launch = try #require(launchFiles(cli).first)
            try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
            try cli.fake(
                "during-setup-token.sh",
                hook.replacingOccurrences(of: "@", with: launch.path) + "\n")
            let out = try cli.run(["login", "pool-a"])
            #expect(out.status == 1, "\(name)")
            let shown = said(out.stdout)
            #expect(shown.contains("Rewrote 0 launch files with the new token."), "\(name)")
            #expect(
                shown.contains("\nError: " + Self.loginPassedBy(launch.lastPathComponent) + "\n"),
                "\(name)")
            #expect(
                try followNamedFiles(shown, "could not be checked, rewritten or deleted", cli)
                    != nil, "\(name)")
            // The file keeps the old token, as the text says, and the closing step goes on.
            let holding = launchFilesHolding(cli, old)
            #expect(holding == 1, "\(name)")
            try FileManager.default.removeItem(
                at: cli.home.appendingPathComponent(".ab-fake/during-setup-token.sh"))
            let refresh = try cli.run(["refresh", "--label", "pool-a"])
            #expect(refresh.status == 0, "\(name): \(said(refresh.stdout))")
        }
    }

    @Test func aLaunchFileALiveSessionNamesThatLoginCouldNotTurnIntoATombstoneIsNamed() throws {
        // A live session names the file, so the rewrite turns one it cannot read into a
        // tombstone; what lands while the person signs in keeps that write out too.
        let cases = [
            ("list", "/bin/chmod +a '\(NSUserName()) deny read,delete' '@'"),
            ("mode and lock", "/bin/chmod 000 '@'; /usr/bin/chflags uchg '@'"),
        ]
        for (name, hook) in cases {
            let old = Canary.realShapeToken()
            let cli = try setUp(token: old)
            defer { cli.cleanup() }
            defer {
                for file in launchFiles(cli) { chmod(file.path, 0o600) }
                clearAccessLists(cli)
            }
            try cli.fakeProbe("ok.jsonl")
            _ = try cli.run(["run", "--print-command", "pool-a"])
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let files = launchFiles(cli).sorted { $0.lastPathComponent < $1.lastPathComponent }
            try #require(files.count == 2, "\(name)")
            let (launch, other) = (files[0], files[1])
            try nameLaunchFile(launch, session: "s-tombstone", in: cli)
            let fresh = Canary.realShapeToken()
            try cli.fake("setup-token.out", "Your token is \(fresh)\n")
            try cli.fake(
                "during-setup-token.sh",
                hook.replacingOccurrences(of: "@", with: launch.path) + "\n")
            let out = try cli.run(["login", "pool-a"])
            #expect(out.status == 1, "\(name)")
            let shown = said(out.stdout)
            #expect(shown.contains("Rewrote 1 launch files with the new token."), "\(name)")
            #expect(
                shown.contains("\nError: " + Self.loginPassedBy(launch.lastPathComponent) + "\n"),
                "\(name)")
            #expect(
                try followNamedFiles(shown, "could not be checked, rewritten or deleted", cli)
                    != nil, "\(name)")
            // The named file keeps the old token, as the text says, and the other has the new one.
            func holds(_ file: URL, _ secret: String) -> Bool {
                ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains(secret)
            }
            let keptOld = holds(launch, old) && !holds(launch, fresh)
            let tookNew = holds(other, fresh) && !holds(other, old)
            #expect(keptOld, "\(name)")
            #expect(tookNew, "\(name)")
            try FileManager.default.removeItem(
                at: cli.home.appendingPathComponent(".ab-fake/during-setup-token.sh"))
            let refresh = try cli.run(["refresh", "--label", "pool-a"])
            #expect(refresh.status == 0, "\(name): \(said(refresh.stdout))")
        }
    }

    @Test func aWriterTemporaryLoginCouldNotDeleteIsNamedAndLoginExitsOne() throws {
        // A temporary file a write left, with the old token in it, gets a lock while the person
        // signs in, so the save's delete of the writer's leftovers fails.
        let folders = [[LaunchFiles.folder, "pool-a"], [TokenPaths.folderName]]
        for folder in folders {
            let old = Canary.realShapeToken()
            let cli = try setUp(token: old)
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            try cli.fakeProbe("ok.jsonl")
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let context = ToolContext(home: cli.home, ambient: [:])
            let source: URL
            if folder.count == 2 {
                source = try #require(launchFiles(cli).first)
            } else {
                source = try TokenPaths.fileURL(context: context, label: "pool-a")
            }
            let temporary = source.deletingLastPathComponent().appendingPathComponent(
                ".tmp-0123456789abcdef")
            try FileManager.default.copyItem(at: source, to: temporary)
            defer { _ = try? runNamedCapturing(["chflags", "nouchg", temporary.path]) }
            try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
            try cli.fake("during-setup-token.sh", "/usr/bin/chflags uchg '\(temporary.path)'\n")
            let out = try cli.run(["login", "pool-a"])
            let name = folder.joined(separator: "/")
            #expect(out.status == 1, "\(name)")
            let place = "~/.agent-balancer/" + name
            let shown = said(out.stdout)
            #expect(
                shown.contains(
                    "\nError: " + Self.temporaryLeft(place, temporary.lastPathComponent) + "\n"),
                "\(name): \(shown)")
            let holding = filesHolding(temporary.deletingLastPathComponent(), old)
            #expect(holding >= 1, "\(name)")
            #expect(try followNamedFiles(shown, "could not be deleted and may hold", cli) == 0)
            // The refresh the closing line names runs the upkeep that deletes it.
            try FileManager.default.removeItem(
                at: cli.home.appendingPathComponent(".ab-fake/during-setup-token.sh"))
            let refresh = try cli.run(["refresh", "--label", "pool-a"])
            #expect(refresh.status == 0, "\(name): \(said(refresh.stdout))")
            #expect(!FileManager.default.fileExists(atPath: temporary.path), "\(name)")
        }
    }

    @Test func aWriterTemporaryLstatCannotCheckIsNamedAndLoginExitsOne() throws {
        // The save's delete passes by a leftover temporary that `lstat` cannot check, so the
        // save's own check names it, whether the entry comes before the login or during the sign-in.
        let folders = [[LaunchFiles.folder, "pool-a"], [TokenPaths.folderName]]
        for folder in folders {
            for when in ["before the login", "during the sign-in"] {
                let old = Canary.realShapeToken()
                let cli = try setUp(token: old)
                defer { cli.cleanup() }
                defer { clearAccessLists(cli) }
                try cli.fakeProbe("ok.jsonl")
                _ = try cli.run(["run", "--print-command", "pool-a"])
                let temporary = try leftTemporary(
                    cli, inTokenFolder: folder.count == 1, name: ".tmp-0123456789abcdef")
                try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
                if when == "before the login" {
                    try denyAttributes(temporary)
                } else {
                    try cli.fake(
                        "during-setup-token.sh",
                        "/bin/chmod +a '\(NSUserName()) deny readattr' '\(temporary.path)'\n")
                }
                let out = try cli.run(["login", "pool-a"])
                let name = folder.joined(separator: "/") + " " + when
                #expect(out.status == 1, "\(name)")
                let place = "~/.agent-balancer/" + folder.joined(separator: "/")
                let shown = said(out.stdout)
                #expect(
                    shown.contains(
                        "\nError: " + Self.temporaryLeft(place, temporary.lastPathComponent)
                            + "\n"),
                    "\(name): \(shown)")
                #expect(!isCheckable(temporary), "\(name)")

                // As written: the folder's commands, then the commands on the file it names.
                #expect(
                    try followNamedFiles(shown, "could not be deleted and may hold", cli) == 0,
                    "\(name)")
                #expect(isCheckable(temporary), "\(name)")
                // The file keeps the old token, as the text says.
                let holding = filesHolding(temporary.deletingLastPathComponent(), old)
                #expect(holding >= 1, "\(name)")
                // The refresh the closing line names runs the upkeep that deletes it.
                let refresh = try cli.run(["refresh", "--label", "pool-a"])
                #expect(refresh.status == 0, "\(name): \(said(refresh.stdout))")
                #expect(!FileManager.default.fileExists(atPath: temporary.path), "\(name)")
            }
        }
    }

    @Test func aLoginNamesBothWriterTemporariesItCouldNotDeleteOrCheck() throws {
        // One leftover is locked during the sign-in and the other cannot be checked from before
        // the login, so the text names both, in the plural.
        let folders = [[LaunchFiles.folder, "pool-a"], [TokenPaths.folderName]]
        for folder in folders {
            let old = Canary.realShapeToken()
            let cli = try setUp(token: old)
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            try cli.fakeProbe("ok.jsonl")
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let locked = try leftTemporary(
                cli, inTokenFolder: folder.count == 1, name: ".tmp-0123456789abcdef")
            defer { _ = try? runNamedCapturing(["chflags", "nouchg", locked.path]) }
            let hidden = try leftTemporary(
                cli, inTokenFolder: folder.count == 1, name: ".tmp-0fedcba987654321")
            try denyAttributes(hidden)
            try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
            try cli.fake("during-setup-token.sh", "/usr/bin/chflags uchg '\(locked.path)'\n")
            let out = try cli.run(["login", "pool-a"])
            let name = folder.joined(separator: "/")
            #expect(out.status == 1, "\(name)")
            let place = "~/.agent-balancer/" + name
            let shown = said(out.stdout)
            let text = Self.twoTemporariesLeft(
                place, [locked.lastPathComponent, hidden.lastPathComponent])
            #expect(shown.contains("\nError: " + text + "\n"), "\(name): \(shown)")
            #expect(!isCheckable(hidden), "\(name)")
            #expect(isLocked(locked), "\(name)")

            #expect(
                try followNamedFiles(shown, "could not be deleted and may hold", cli) == 0,
                "\(name)")
            let holding = filesHolding(locked.deletingLastPathComponent(), old)
            #expect(holding >= 2, "\(name)")
            let refresh = try cli.run(["refresh", "--label", "pool-a"])
            #expect(refresh.status == 0, "\(name): \(said(refresh.stdout))")
            for file in [locked, hidden] {
                #expect(!FileManager.default.fileExists(atPath: file.path), "\(name)")
            }
        }
    }

    @Test func aLinkFolderOrOtherUsersFileAtALaunchFileOrTemporaryNameIsNeverNamedOrCounted()
        throws
    {
        // None of these is a launch file or a temporary file of the tool's, so none may hold its
        // token. Root's file stands for another user's, linked in where the volume allows it.
        let old = Canary.realShapeToken()
        let cli = try setUp(token: old)
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        try cli.fakeProbe("ok.jsonl")
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let folder = try #require(launchFiles(cli).first).deletingLastPathComponent()
        let tokens = cli.dataRoot.appendingPathComponent(TokenPaths.folderName)
        let links = [
            folder.appendingPathComponent("l-0000beef.json"),
            folder.appendingPathComponent(".tmp-00000000deadbeef"),
            tokens.appendingPathComponent(".tmp-00000000deadbeef"),
        ]
        let inner = folder.appendingPathComponent("l-0000cafe.json")
        let foreign = [
            folder.appendingPathComponent("l-0000f00d.json"),
            folder.appendingPathComponent(".tmp-00000000f00dcafe"),
        ]
        let rootsFile = URL(fileURLWithPath: "/private/etc/shells")
        var linkedIn: [URL] = []
        for file in foreign {
            if (try? FileManager.default.linkItem(at: rootsFile, to: file)) != nil {
                linkedIn.append(file)
            }
        }
        // The names of root's file go first, so the clean-up never acts on that file.
        defer { for file in linkedIn { try? FileManager.default.removeItem(at: file) } }
        try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
        let hook =
            links.map { "/bin/ln -s /nonexistent '\($0.path)'\n" }.joined()
            + "/bin/mkdir '\(inner.path)'\n"
        try cli.fake("during-setup-token.sh", hook)
        let out = try cli.run(["login", "pool-a"])
        let shown = said(out.stdout)
        #expect(out.status == 0, "\(shown)")
        #expect(shown.contains("Saved the token for 'pool-a'.\n"))
        #expect(shown.contains("Rewrote 1 launch files with the new token."))
        #expect(!shown.contains("Error:"), "\(shown)")
        for part in ["l-0000beef", "l-0000cafe", "l-0000f00d", ".tmp-"] {
            #expect(!shown.contains(part), "\(part)")
        }
        // The tool followed none of them and deleted none.
        for link in links {
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            #expect(target == "/nonexistent", "\(link.lastPathComponent)")
        }
        #expect(isRealFolder(inner))
        for file in linkedIn { #expect(FileManager.default.fileExists(atPath: file.path)) }

        // `doctor` counts the one launch file, and no link, folder or file of another user.
        let doctor = try cli.run(["doctor"])
        let line = said(doctor.stdout).split(separator: "\n").first {
            $0.hasPrefix("launch files:")
        }
        #expect(line?.hasPrefix("launch files: 1, oldest ") == true, "\(line ?? "")")
        #expect(line?.contains("cannot be checked") == false, "\(line ?? "")")
    }

    // MARK: doctor and status

    /// The warnings on `pool-a`'s row of `status --cached --json`.
    func poolAWarnings(_ cli: CLIHome) throws -> [[String: String]] {
        let status = try cli.run(["status", "--cached", "--json"])
        let document = try #require(
            JSONSerialization.jsonObject(with: status.stdout) as? [String: Any])
        let rows = try #require(document["accounts"] as? [[String: Any]])
        let row = try #require(rows.first { $0["label"] as? String == "pool-a" })
        return try #require(row["warnings"] as? [[String: String]])
    }

    @Test func aLaunchFileALiveSessionNamesThatCannotBeCheckedIsCountedAndNeverCalledGone()
        throws
    {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        // A live session, this test's own process, names the launch file.
        let sessions = cli.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "pid": Int(getpid()), "sessionId": "s-unchecked", "name": "w1",
            "args": "--settings " + launch.path,
        ]
        try JSONSerialization.data(withJSONObject: record).write(
            to: sessions.appendingPathComponent("\(getpid()).json"))
        try denyAttributes(launch)

        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        let lines = said(doctor.stdout)
        #expect(
            lines.contains(
                "\nWarning launch_file_unchecked: session s-unchec names a launch file that cannot be checked.\n"
            ))
        #expect(!lines.contains("launch_file_missing"))
        #expect(lines.contains("\nlaunch files: 1, 1 cannot be checked\n"))
        #expect(
            try poolAWarnings(cli) == [
                [
                    "code": "launch_file_unchecked",
                    "text":
                        "1 live session names a launch file that cannot be checked. Run `agent-balancer doctor` in Terminal.",
                ]
            ])

        #expect(try removeAccessList(launch) == 0)
        let after = try cli.run(["doctor"])
        #expect(after.status == 0, "\(said(after.stdout))")
        #expect(said(after.stdout).contains("\nlaunch files: 1, oldest under a minute old\n"))
        #expect(!said(after.stdout).contains("launch_file_"))
        #expect(try poolAWarnings(cli).isEmpty)

        // A session that names both that file and one that is gone gets both warnings.
        let gone = launch.deletingLastPathComponent().appendingPathComponent("l-0badc0de.json")
        let both: [String: Any] = [
            "pid": Int(getpid()), "sessionId": "s-both", "name": "w1",
            "args": "--settings " + launch.path + " --settings " + gone.path,
        ]
        try JSONSerialization.data(withJSONObject: both).write(
            to: sessions.appendingPathComponent("\(getpid()).json"))
        try denyAttributes(launch)
        let mixed = try cli.run(["doctor"])
        let shown = said(mixed.stdout)
        #expect(mixed.status == 1, "\(shown)")
        #expect(
            shown.contains(
                "\nWarning launch_file_unchecked: session s-both names a launch file that cannot be checked.\nWarning launch_file_missing: session s-both names a launch file that is gone.\n"
            ), "\(shown)")
        #expect(shown.contains("\nlaunch files: 1, 1 cannot be checked\n"), "\(shown)")
        #expect(
            try poolAWarnings(cli) == [
                [
                    "code": "launch_file_missing",
                    "text": "1 live session names a launch file that is gone.",
                ],
                [
                    "code": "launch_file_unchecked",
                    "text":
                        "1 live session names a launch file that cannot be checked. Run `agent-balancer doctor` in Terminal.",
                ],
            ])
        #expect(try removeAccessList(launch) == 0)
    }

    @Test func aLaunchFileALiveSessionNamesThatIsGoneIsCalledGoneAndNeverUnchecked() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        // A live session names a launch file of the label that is not there.
        let gone = launch.deletingLastPathComponent().appendingPathComponent("l-0badc0de.json")
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        try nameLaunchFile(gone, session: "s-gone", in: cli)

        let doctor = try cli.run(["doctor"])
        let lines = said(doctor.stdout)
        #expect(doctor.status == 0, "\(lines)")
        #expect(
            lines.contains(
                "\nWarning launch_file_missing: session s-gone names a launch file that is gone.\n"
            ), "\(lines)")
        #expect(!lines.contains("launch_file_unchecked"), "\(lines)")
        #expect(
            try poolAWarnings(cli) == [
                [
                    "code": "launch_file_missing",
                    "text": "1 live session names a launch file that is gone.",
                ]
            ])
    }

    @Test func aLaunchFolderDoctorRefusesOrCannotListIsNamedAndItsFilesAreNotLeftOut() throws {
        let place = Self.poolAPlace
        let cases: [(name: String, line: String)] = [
            (
                "mode",
                "launch files: 1, 1 cannot be checked, and the launch folder `\(place)` cannot be checked, so each launch file in it counts as one that cannot be checked"
            ),
            (
                "list",
                "launch files: 1, 1 cannot be checked, and the launch folder `\(place)` cannot be checked or listed, so a launch file in it counts only when a session record names it"
            ),
        ]
        for item in cases {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            _ = try cli.run(["run", "--print-command", "pool-a"])
            let launch = try #require(launchFiles(cli).first)
            let folder = launch.deletingLastPathComponent()
            let sessions = cli.home.appendingPathComponent(".claude/sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let record: [String: Any] = [
                "pid": Int(getpid()), "sessionId": "s-folder", "name": "w1",
                "args": "--settings " + launch.path,
            ]
            try JSONSerialization.data(withJSONObject: record).write(
                to: sessions.appendingPathComponent("\(getpid()).json"))
            if item.name == "mode" {
                chmod(folder.path, 0o755)
            } else {
                try denyOwnerOf(folder, "list")
            }
            defer { chmod(folder.path, 0o700) }

            let doctor = try cli.run(["doctor"])
            #expect(doctor.status == 1, "\(item.name)")
            let lines = said(doctor.stdout)
            #expect(lines.contains("\n" + item.line + "\n"), "\(item.name): \(lines)")
            #expect(
                lines.contains(
                    "\nWarning launch_file_unchecked: session s-folder names a launch file that cannot be checked.\n"
                ), "\(item.name)")
            #expect(!lines.contains("\nlaunch files: 0"), "\(item.name)")

            chmod(folder.path, 0o700)
            #expect(try removeAccessList(folder) == 0)
            let after = try cli.run(["doctor"])
            #expect(after.status == 0, "\(item.name): \(said(after.stdout))")
            #expect(
                said(after.stdout).contains("\nlaunch files: 1, oldest under a minute old\n"),
                "\(item.name)")
        }
    }

    // MARK: add

    @Test func addRefusesALabelWhoseTokenFileItCannotCheckAndGoesOnOnceTheNamedCommandsRun()
        throws
    {
        let folderPlace = "~/.agent-balancer/" + TokenPaths.folderName
        let filePlace = folderPlace + "/pool-b.json"
        let cases: [(mark: String, text: String)] = [
            (
                "file",
                "The token file `\(filePlace)` cannot be checked, so it may hold a token from an earlier account 'pool-b'. Run `chmod -h -N \(filePlace)`, or `chmod -N \(filePlace)` if that says Permission denied, then run `agent-balancer remove pool-b` in Terminal, then add it again."
            ),
            (
                "search",
                "The token folder `\(folderPlace)` cannot be opened or searched, so `add` cannot check whether a token file from an earlier account 'pool-b' is in it. Run `chmod -N \(folderPlace)`, then `chmod 700 \(folderPlace)`, and `chflags nouchg,nouappnd \(folderPlace)` first if it is locked, then run `agent-balancer add pool-b` again."
            ),
            (
                "readattr",
                "The token folder `\(folderPlace)` cannot be checked, so `add` cannot tell what it is or whether a token file from an earlier account 'pool-b' is in it. Run `chmod -h -N \(folderPlace)`, or `chmod -N \(folderPlace)` if that says Permission denied, then `chmod -h 700 \(folderPlace)`, then run `agent-balancer add pool-b` again."
            ),
        ]
        for item in cases {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            defer { clearAccessLists(cli) }
            let context = ToolContext(home: cli.home, ambient: [:])
            // A token file that an earlier account labelled pool-b left.
            _ = try TokenAccounts.install(
                context: context, label: "pool-b", token: Canary.realShapeToken())
            let file = try TokenPaths.fileURL(context: context, label: "pool-b")
            switch item.mark {
            case "file": try denyAttributes(file)
            case "search": try denyOwnerOf(file.deletingLastPathComponent(), "search")
            default: try denyAttributes(file.deletingLastPathComponent())
            }
            let refused = try cli.run(["add", "pool-b"])
            #expect(refused.status == 1, "\(item.mark)")
            let shown = said(refused.stderr)
            #expect(shown == "Error: " + item.text + "\n", "\(item.mark)")
            #expect(try ConfigStore(context: context).load()?.account("pool-b") == nil)

            if item.mark == "file" {
                let named = namedCommands(shown, "cannot be checked", home: cli.home)
                    .filter { $0.first == "chmod" }
                try #require(named.count == 2)
                let first = try runNamedCapturing(named[0])
                if first.status != 0 {
                    #expect(first.error.contains("Permission denied"), "\(first.error)")
                    #expect(try runNamedCapturing(named[1]).status == 0)
                }
            } else {
                #expect(
                    try followFolderStop(shown, cli, marker: "token folder") != nil,
                    "\(item.mark)")
                // Now it sees the file, so it refuses as it refuses one it can see.
                let seen = try cli.run(["add", "pool-b"])
                #expect(seen.status == 1, "\(item.mark)")
                #expect(
                    said(seen.stderr)
                        == "Error: A token file from an earlier account 'pool-b' is still saved. Run `agent-balancer remove pool-b` in Terminal first, then add it again.\n",
                    "\(item.mark)")
            }
            let removed = try cli.run(["remove", "pool-b"])
            #expect(removed.status == 0, "\(item.mark): \(said(removed.stderr))")
            let added = try cli.run(["add", "pool-b"])
            #expect(added.status == 0, "\(item.mark): \(said(added.stderr))")
            #expect(try ConfigStore(context: context).load()?.account("pool-b") != nil)
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(item.mark)")
        }
    }

    @Test func addRefusesALabelWhileTheFolderChecksRefuseTheTokenFolder() throws {
        // A token folder wider than 0700 may hold a token file an earlier account left, so `add`
        // stops with the writer's refusal until the command it names runs.
        let place = "~/.agent-balancer/" + TokenPaths.folderName
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        _ = try TokenAccounts.install(
            context: context, label: "pool-b", token: Canary.realShapeToken())
        let folder = try TokenPaths.fileURL(context: context, label: "pool-b")
            .deletingLastPathComponent()
        chmod(folder.path, 0o755)
        defer { chmod(folder.path, 0o700) }
        let refused = try cli.run(["add", "pool-b"])
        let shown = said(refused.stderr)
        #expect(refused.status == 1)
        #expect(
            shown
                == "Error: Refused `\(place)`: it is wider than 0700. Run `chflags nouchg,nouappnd \(place)` first if it is locked, then `chmod 700 \(place)` in Terminal.\n"
        )
        #expect(try ConfigStore(context: context).load()?.account("pool-b") == nil)

        // As written; then it sees the file and refuses as it refuses one it can see.
        let named = namedCommands(shown, "Refused", home: cli.home)
        try #require(named.count == 2)
        try followRefusal(shown, cli)
        let seen = try cli.run(["add", "pool-b"])
        #expect(seen.status == 1)
        #expect(
            said(seen.stderr)
                == "Error: A token file from an earlier account 'pool-b' is still saved. Run `agent-balancer remove pool-b` in Terminal first, then add it again.\n"
        )
        #expect(try cli.run(["remove", "pool-b"]).status == 0)
        #expect(try cli.run(["add", "pool-b"]).status == 0)
        #expect(try ConfigStore(context: context).load()?.account("pool-b") != nil)
    }
}

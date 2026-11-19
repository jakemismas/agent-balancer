import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// `login`, `pick`, `run`, `status` and `doctor` end to end when an access list lets another
/// user or group into a folder of the tool's, a token file or a launch file.
@Suite struct AccessListPrivacyCLITests {
    func setUp() throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                expectedPlanTier: "max_20x")
        ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    /// A home with the token account `lab` signed in.
    func signedIn() throws -> CLIHome {
        let cli = try setUp()
        #expect(try cli.run(["add", "lab"]).status == 0)
        try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        return cli
    }

    func runChmod(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = arguments
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func add(_ entry: String, _ url: URL) throws {
        #expect(try runChmod(["+a", entry, url.path]) == 0, "\(entry) \(url.lastPathComponent)")
    }

    /// Clears every lock flag, then every access list, under the home and on the home itself,
    /// so none outlives the test and a locked file cannot stop the clearing.
    func finish(_ cli: CLIHome) {
        _ = try? runChflags(["-R", "nouchg,nouappnd", cli.home.path])
        _ = try? runChmod(["-R", "-N", cli.home.path])
        cli.cleanup()
    }

    func tokenFile(_ cli: CLIHome) throws -> URL {
        try TokenPaths.fileURL(context: ToolContext(home: cli.home, ambient: [:]), label: "lab")
    }

    func launchFolder(_ cli: CLIHome) -> URL {
        LaunchFiles.rootURL(context: ToolContext(home: cli.home, ambient: [:]))
            .appendingPathComponent("lab")
    }

    /// The entries of `url`'s access list that allow anyone but the user, from `acl_to_text`.
    func entriesLettingOthersIn(_ url: URL) -> [String] {
        guard let list = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? [] : ["unreadable"]
        }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        var length = 0
        guard let text = acl_to_text(list, &length) else { return ["unreadable"] }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text).split(separator: "\n").map(String.init).filter { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 6, fields[4].hasPrefix("allow") else { return false }
            return !(fields[0] == "user" && fields[3] == "\(getuid())")
        }
    }

    /// The names under the data folder, the data folder included, that an access list opens.
    func sharedEntries(_ cli: CLIHome) -> [String] {
        ([cli.dataRoot] + cli.dataEntries()).filter { !entriesLettingOthersIn($0).isEmpty }
            .map(\.lastPathComponent)
    }

    func state(_ cli: CLIHome, _ label: String) throws -> String? {
        let out = try cli.run(["status", "--cached", "--json"])
        let doc = try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
        let rows = try #require(doc["accounts"] as? [[String: Any]])
        return rows.first { $0["label"] as? String == label }?["state"] as? String
    }

    /// The text of the error the status row of `label` shows, or nil.
    func errorText(_ cli: CLIHome, _ label: String) throws -> String? {
        let out = try cli.run(["status", "--cached", "--json"])
        let doc = try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
        let rows = try #require(doc["accounts"] as? [[String: Any]])
        let row = rows.first { $0["label"] as? String == label }
        return (row?["error"] as? [String: Any])?["text"] as? String
    }

    /// The `chmod` commands a text names in backticks, each as its arguments, with `~` as the
    /// home and a launch file pattern given the names it matches.
    func chmodCommands(_ said: String, _ cli: CLIHome) -> [[String]] {
        said.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            .filter { $0.hasPrefix("chmod ") }
            .map { command in
                command.split(separator: " ").dropFirst().flatMap { word -> [String] in
                    let home = cli.home.path
                    let path = word.hasPrefix("~") ? home + String(word.dropFirst()) : String(word)
                    guard path.hasSuffix("/l-*.json") else { return [path] }
                    let folder = URL(fileURLWithPath: String(path.dropLast("/l-*.json".count)))
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))
                    return (names ?? []).filter { $0.hasPrefix("l-") && $0.hasSuffix(".json") }
                        .sorted().map { folder.appendingPathComponent($0).path }
                }
            }
    }

    @Test func aTokenSaveIntoATokenFolderThatPassesOnAnAllowEntryIsRefusedAndDoctorNamesTheFix()
        throws
    {
        let cli = try signedIn()
        defer { finish(cli) }
        let folder = try tokenFile(cli).deletingLastPathComponent()
        let place = "~/.agent-balancer/" + TokenPaths.folderName
        try add("everyone allow read,file_inherit", folder)
        let again = try cli.run(["login", "lab"])
        #expect(again.status == 1)
        #expect(text(again.stderr).contains("`chmod -N \(place)`"))
        #expect(sharedEntries(cli) == [folder.lastPathComponent])
        #expect(try state(cli, "lab") != "ok")

        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        let said = text(doctor.stdout)
        #expect(
            said.contains(
                "Error: `\(place)` has an access list that lets another user or group in, or that cannot be read, so the tool refuses it. Run `chmod -N \(place)` in Terminal, then run `agent-balancer doctor` again."
            ))
        for command in chmodCommands(said, cli) {
            #expect(try runChmod(command) == 0, "\(command)")
        }
        let clean = try cli.run(["doctor"])
        #expect(clean.status == 0, "\(text(clean.stdout))")
        #expect(!text(clean.stdout).contains("access list"))
        #expect(try state(cli, "lab") == "ok")
        #expect(try cli.run(["login", "lab"]).status == 0)
        #expect(sharedEntries(cli).isEmpty)
    }

    @Test func aTokenFileWithAnAllowEntryIsNotOkPickedOrRunAndDoctorNamesTheFix() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        let file = try tokenFile(cli)
        try add("everyone allow read", file)
        #expect(try state(cli, "lab") != "ok")
        #expect(
            try errorText(cli, "lab")
                == "The token file of 'lab' may be readable by others, so its token is not used. Run `agent-balancer doctor` in Terminal."
        )
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        #expect(pick.status == 2)
        let picked = try #require(
            JSONSerialization.jsonObject(with: pick.stdout) as? [String: Any])
        #expect(picked["label"] as? String == nil)
        #expect(try cli.run(["run", "--print-command", "lab"]).status == 1)
        #expect(FileManager.default.fileExists(atPath: launchFolder(cli).path) == false)

        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        let said = text(doctor.stdout)
        let place = "~/.agent-balancer/" + TokenPaths.folderName + "/lab.json"
        #expect(
            said.contains(
                "Error: `\(place)` has an access list that lets another user or group in, or that cannot be read, so its token is not used, and another user may have read it. Run `chmod -N \(place)` in Terminal to use it again, or `agent-balancer login lab` to replace it."
            ))
        for command in chmodCommands(said, cli) {
            #expect(try runChmod(command) == 0, "\(command)")
        }
        #expect(try cli.run(["doctor"]).status == 0)
        #expect(try state(cli, "lab") == "ok")
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        #expect(sharedEntries(cli).isEmpty)
    }

    @Test func aPickIntoALaunchFolderThatPassesOnAnAllowEntryIsRefusedAndDoctorNamesTheFix()
        throws
    {
        let cli = try signedIn()
        defer { finish(cli) }
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        let folder = launchFolder(cli)
        try add("everyone allow read,file_inherit", folder)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        #expect(pick.status == 1)
        let launchPlace = "~/.agent-balancer/" + LaunchFiles.folder + "/lab"
        #expect(text(pick.stderr).contains("Run `chmod -N \(launchPlace)` in Terminal"))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(after == before)
        #expect(sharedEntries(cli) == [folder.lastPathComponent])

        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/lab"
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        let said = text(doctor.stdout)
        #expect(said.contains("Error: `\(place)` has an access list"))
        for command in chmodCommands(said, cli) {
            #expect(try runChmod(command) == 0, "\(command)")
        }
        // A launch file that took an entry before it is named by its folder, never by its name.
        let old = try #require(before.sorted().first)
        try add("everyone allow read", folder.appendingPathComponent(old))
        let files = try cli.run(["doctor"])
        #expect(files.status == 1)
        let listed = text(files.stdout)
        #expect(
            listed.contains(
                "Error: Launch files in `\(place)` have an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(place)/l-*.json` in Terminal."
            ))
        #expect(!listed.contains(old))
        for command in chmodCommands(listed, cli) {
            #expect(try runChmod(command) == 0, "\(command)")
        }
        #expect(try cli.run(["doctor"]).status == 0)
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        #expect(sharedEntries(cli).isEmpty)
    }

    @Test func entriesThatOnlyDenyOrOnlyAllowTheUserLeaveDoctorStatusAndPickAsTheyWere() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        let me = NSUserName()
        let folders = [
            cli.dataRoot, try tokenFile(cli).deletingLastPathComponent(), launchFolder(cli),
        ]
        for folder in folders {
            try add("nobody deny list,search,file_inherit", folder)
            try add("\(me) allow list,search,file_inherit", folder)
        }
        try add("daemon deny read", try tokenFile(cli))
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 0, "\(text(doctor.stdout))")
        #expect(!text(doctor.stdout).contains("access list"))
        #expect(try state(cli, "lab") == "ok")
        #expect(try cli.run(["login", "lab"]).status == 0)
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        #expect(try state(cli, "lab") == "ok")
        #expect(sharedEntries(cli).isEmpty)
    }

    @Test func aHomeThatPassesOnAnAllowEntryLeavesNoneOnTheTokenOrLaunchFiles() throws {
        let cli = try CLIHome()
        defer { finish(cli) }
        try add("everyone allow read,search,file_inherit,directory_inherit", cli.home)
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                expectedPlanTier: "max_20x")
        ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        #expect(try cli.run(["add", "lab"]).status == 0)
        try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        #expect(sharedEntries(cli) == [])
        #expect(try state(cli, "lab") == "ok")
        #expect(try cli.run(["doctor"]).status == 0)
    }

    @Test func aDataFolderWithAnAllowEntryStopsEveryCommandWithTheFixDoctorAlsoNames() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        try add("staff allow list,search", cli.dataRoot)
        let place = "~/.agent-balancer"
        let status = try cli.run(["status", "--cached", "--json"])
        #expect(status.status == 1)
        #expect(text(status.stderr).contains("Run `chmod -N \(place)` in Terminal"))
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status != 0)
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        #expect(
            text(doctor.stdout)
                == "Error: `\(place)` has an access list that lets another user or group in, or that cannot be read, so the tool refuses it. Run `chmod -N \(place)` in Terminal, then run `agent-balancer doctor` again.\n"
        )
        for command in chmodCommands(text(doctor.stdout), cli) {
            #expect(try runChmod(command) == 0, "\(command)")
        }
        #expect(try cli.run(["doctor"]).status == 0)
        #expect(try state(cli, "lab") == "ok")
    }
}

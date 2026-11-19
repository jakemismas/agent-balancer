import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// What `login`, `uninstall`, `doctor`, `status`, `pick` and `run` do when a folder or a file of
/// the tool's has an access list that lets others in, cannot be read, or a mode wider than 0700:
/// a sign-in never starts before a save it cannot finish, `uninstall` never reports success while
/// it leaves the tool's files, and `doctor` names every such folder and file with its fix.
extension AccessListPrivacyCLITests {
    var me: String { NSUserName() }

    /// The `setup-token` runs in the fake's argument log.
    func signIns(_ cli: CLIHome) -> Int {
        cli.fakeRecord("args.log").split(separator: "\n").filter { $0 == "setup-token" }.count
    }

    /// Every file under the data folder, links not followed, with its content.
    func files(_ cli: CLIHome) -> [String: Data] {
        var found: [String: Data] = [:]
        for url in cli.dataEntries() {
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &folder),
                !folder.boolValue
            else { continue }
            found[url.path] = (try? Data(contentsOf: url)) ?? Data()
        }
        return found
    }

    /// Whether `url` carries an extended access list at all, a link not followed.
    func hasList(_ url: URL) -> Bool {
        guard let list = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            return errno != ENOENT
        }
        acl_free(UnsafeMutableRawPointer(list))
        return true
    }

    /// `path` under the data folder as the person types it.
    func typed(_ path: [String]) -> String {
        (["~/.agent-balancer"] + path).joined(separator: "/")
    }

    func url(_ cli: CLIHome, _ path: [String]) -> URL {
        path.reduce(cli.dataRoot) { $0.appendingPathComponent($1) }
    }

    func folderRefusal(_ place: String) -> String {
        "Refused `\(place)`: its access list lets another user or group in, or cannot be read. Run `chmod -N \(place)` in Terminal."
    }

    func doctorFolderLine(_ place: String) -> String {
        "Error: `\(place)` has an access list that lets another user or group in, or that cannot be read, so the tool refuses it. Run `chmod -N \(place)` in Terminal, then run `agent-balancer doctor` again."
    }

    @Test func loginRefusesARefusedFolderBeforeTheSignInStartsOrThePasteIsRead() throws {
        let tokens = [TokenPaths.folderName]
        let launch = [LaunchFiles.folder, "lab"]
        let cases: [(path: [String], entry: String)] = [
            (tokens, "everyone allow read,file_inherit"), (tokens, "\(me) deny readsecurity"),
            (launch, "everyone allow read"), (launch, "\(me) deny readattr"),
        ]
        for item in cases {
            for paste in [false, true] {
                let name = "\(item.entry) on \(item.path.joined(separator: "/")) paste \(paste)"
                let cli = try signedIn()
                defer { finish(cli) }
                #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
                let before = files(cli)
                let started = signIns(cli)
                try add(item.entry, url(cli, item.path))
                let args = paste ? ["login", "lab", "--paste"] : ["login", "lab"]
                let refused = try cli.run(args, stdin: Canary.realShapeToken() + "\n")
                #expect(refused.status == 1, "\(name)")
                let said = text(refused.stderr)
                #expect(said.contains(folderRefusal(typed(item.path))), "\(name)")
                #expect(!text(refused.stdout).contains("Opening the browser"), "\(name)")
                #expect(!text(refused.stdout).contains("Paste the token"), "\(name)")
                #expect(signIns(cli) == started, "\(name)")
                #expect(try runChmod(["-N", url(cli, item.path).path]) == 0, "\(name)")
                #expect(files(cli) == before, "\(name)")
            }
        }
    }

    @Test func uninstallStopsOnAStateOrBackupFolderItWouldLeaveUntilTheNamedCommandRuns() throws {
        let cases: [(path: [String], entry: String?)] = [
            (Layout.stateFolders, "everyone allow read"),
            (Layout.backupsFolders, "everyone allow read"),
            (Layout.stateFolders, nil),
        ]
        for item in cases {
            let name = "\(item.path) \(item.entry ?? "755")"
            let cli = try signedIn()
            defer { finish(cli) }
            let context = ToolContext(home: cli.home, ambient: [:])
            let store = ConfigStore(context: context)
            try store.save(try store.loadRequired(), backup: true)
            let folder = url(cli, item.path)
            #expect(FileManager.default.fileExists(atPath: folder.path), "\(name)")
            let before = files(cli)
            if let entry = item.entry {
                #expect(try runChmod(["+ai", entry, folder.path]) == 0, "\(name)")
            } else {
                chmod(folder.path, 0o755)
            }
            let place = typed(item.path)
            let refused = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(refused.status == 1, "\(name)")
            let said = text(refused.stderr)
            let wanted =
                item.entry == nil
                ? "The folder `\(place)` is wider than 0700, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod 700 \(place)`, then run `agent-balancer uninstall` again."
                : "The folder `\(place)` has an access list that lets another user or group in, or that cannot be read, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod -N \(place)`, then run `agent-balancer uninstall` again."
            #expect(said.contains(wanted), "\(name): \(said)")
            #expect(files(cli) == before, "\(name)")
            let commands = chmodCommands(wanted, cli)
            #expect(!commands.isEmpty, "\(name)")
            for command in commands {
                #expect(try runChmod(command) == 0, "\(name): \(command)")
            }
            let done = try cli.run(["uninstall"], stdin: "uninstall\n")
            #expect(done.status == 0, "\(name): \(text(done.stderr))")
            #expect(!FileManager.default.fileExists(atPath: cli.dataRoot.path), "\(name)")
        }
    }

    @Test func doctorNamesAFolderWhoseListTheUserCannotReadUntilItsCommandRuns() throws {
        for path in [[TokenPaths.folderName], Layout.stateFolders] {
            let cli = try signedIn()
            defer { finish(cli) }
            try add("\(me) deny readsecurity", url(cli, path))
            let place = typed(path)
            let doctor = try cli.run(["doctor"])
            #expect(doctor.status == 1, "\(path)")
            let said = text(doctor.stdout)
            #expect(said.contains(doctorFolderLine(place) + "\n"), "\(path): \(said)")
            for command in chmodCommands(said, cli) {
                #expect(try runChmod(command) == 0, "\(path): \(command)")
            }
            let clean = try cli.run(["doctor"])
            #expect(clean.status == 0, "\(path): \(text(clean.stdout))")
            #expect(!text(clean.stdout).contains("access list"), "\(path)")
            #expect(try state(cli, "lab") == "ok", "\(path)")
        }
    }

    @Test func statusPickAndRunNameTheFixForATokenFolderWhoseListTheUserCannotRead() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        let folder = url(cli, [TokenPaths.folderName])
        try add("\(me) deny readsecurity", folder)
        let refusal = folderRefusal(typed([TokenPaths.folderName]))
        #expect(try state(cli, "lab") != "ok")
        #expect(try errorText(cli, "lab") == refusal)
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        #expect(pick.status == 2)
        let picked = try #require(
            JSONSerialization.jsonObject(with: pick.stdout) as? [String: Any])
        let rows = try #require(picked["candidates"] as? [[String: Any]])
        let lab = try #require(rows.first { $0["label"] as? String == "lab" })
        #expect(lab["reason"] as? String == refusal)
        let run = try cli.run(["run", "--print-command", "lab"])
        #expect(run.status == 1)
        #expect(text(run.stderr).contains(refusal))
        #expect(try runChmod(["-N", folder.path]) == 0)
        #expect(try state(cli, "lab") == "ok")
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
    }

    @Test func anInheritedAllowEntryOnATokenFileKeepsItFromUseAndDoctorNamesIt() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        let file = try tokenFile(cli)
        #expect(try runChmod(["+ai", "everyone allow read", file.path]) == 0)
        #expect(try state(cli, "lab") != "ok")
        #expect(
            try errorText(cli, "lab")
                == "The token file of 'lab' may be readable by others, so its token is not used. Run `agent-balancer doctor` in Terminal."
        )
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        let place = typed([TokenPaths.folderName, "lab.json"])
        let said = text(doctor.stdout)
        #expect(
            said.contains(
                "Error: `\(place)` has an access list that lets another user or group in, or that cannot be read, so its token is not used, and another user may have read it. Run `chmod -N \(place)` in Terminal to use it again, or `agent-balancer login lab` to replace it.\n"
            ))
        for command in chmodCommands(said, cli) {
            #expect(try runChmod(command) == 0, "\(command)")
        }
        #expect(try cli.run(["doctor"]).status == 0)
        #expect(try state(cli, "lab") == "ok")
    }

    @Test func doctorNamesEveryFileWhoseListLetsOthersInUntilTheNamedCommandsRun() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        let context = ToolContext(home: cli.home, ambient: [:])
        let store = ConfigStore(context: context)
        try store.save(try store.loadRequired(), backup: true)
        try NoFollowWriter(root: cli.dataRoot).append(
            Data("line\n".utf8), folders: Layout.logsFolders, name: Layout.logName)
        try recordEndedRejection(cli)
        // The check's own leftovers, and a writer's leftover in a launch folder.
        let leftover = ".tmp-0123456789abcdef"
        for path in [Layout.locksFolders, Layout.logsFolders, [LaunchFiles.folder, "lab"]] {
            let made = FileManager.default.createFile(
                atPath: url(cli, path + [leftover]).path, contents: Data(),
                attributes: [.posixPermissions: 0o600])
            #expect(made, "\(path)")
        }
        let all = files(cli).keys.sorted()
        #expect(all.count >= 19)
        for name in [StatusBuilder.rejectionsName, leftover] {
            #expect(all.contains { $0.hasSuffix("/" + name) }, "\(name)")
        }
        for path in all {
            #expect(try runChmod(["+ai", "everyone allow read", path]) == 0, "\(path)")
        }
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        let said = text(doctor.stdout)
        for path in all {
            let inside = path.components(separatedBy: "/.agent-balancer/").last ?? path
            let shown = "~/.agent-balancer/" + inside
            if inside.hasPrefix(LaunchFiles.folder + "/") && !inside.hasSuffix("/" + leftover) {
                let folder = shown.split(separator: "/").dropLast().joined(separator: "/")
                #expect(said.contains("`chmod -N \(folder)/l-*.json`"), "\(shown)")
                #expect(!said.contains(shown), "\(shown)")
            } else {
                #expect(said.contains("`chmod -N \(shown)`"), "\(shown)")
            }
        }
        for command in chmodCommands(said, cli) {
            #expect(try runChmod(command) == 0, "\(command)")
        }
        let clean = try cli.run(["doctor"])
        #expect(clean.status == 0, "\(text(clean.stdout))")
        // The empty leftover in the launch folder holds no token.
        #expect(!text(clean.stdout).contains("may hold a token"), "\(text(clean.stdout))")
        for path in all {
            #expect(!hasList(URL(fileURLWithPath: path)), "\(path)")
        }
        #expect(try state(cli, "lab") == "ok")
    }

    @Test func doctorNamesEachFolderOfTheToolsWhoseListLetsOthersInAndExitsOne() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        let writer = NoFollowWriter(root: cli.dataRoot)
        let probeFolder = Layout.probeFolders + [Layout.probeFolderPrefix + "0123456789abcdef"]
        let paths: [[String]] = [
            [], Layout.stateFolders, Layout.readingsFolders, ReadingHistory.folders,
            Layout.locksFolders, Layout.probeFolders, probeFolder, Layout.logsFolders,
            Layout.backupsFolders, [FolderPaths.accountsFolderName],
            Array(FolderPaths.folders(label: "spare").dropLast()),
            FolderPaths.folders(label: "spare"),
            [TokenPaths.folderName], [LaunchFiles.folder], [LaunchFiles.folder, "lab"],
        ]
        for path in paths where !path.isEmpty { try writer.prepare(folders: path) }
        #expect(try cli.run(["doctor"]).status == 0)
        for path in paths {
            let place = typed(path)
            try add("everyone allow list", url(cli, path))
            let doctor = try cli.run(["doctor"])
            #expect(doctor.status == 1, "\(place)")
            let said = text(doctor.stdout)
            #expect(said.contains(doctorFolderLine(place) + "\n"), "\(place): \(said)")
            for command in chmodCommands(said, cli) {
                #expect(try runChmod(command) == 0, "\(place): \(command)")
            }
            #expect(try cli.run(["doctor"]).status == 0, "\(place)")
        }
    }

    @Test func doctorWithNoConfigStillNamesARefusedFolderAndExitsOne() throws {
        let cli = try CLIHome()
        defer { finish(cli) }
        try NoFollowWriter(root: cli.dataRoot).prepare(folders: [TokenPaths.folderName])
        let folder = url(cli, [TokenPaths.folderName])
        try add("everyone allow list", folder)
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        let place = typed([TokenPaths.folderName])
        #expect(
            text(doctor.stdout)
                == doctorFolderLine(place) + "\n"
                + "Setup has not run. Run `agent-balancer init`.\n")
        #expect(try runChmod(["-N", folder.path]) == 0)
        let clean = try cli.run(["doctor"])
        #expect(clean.status == 0)
        #expect(text(clean.stdout) == "Setup has not run. Run `agent-balancer init`.\n")
    }
}

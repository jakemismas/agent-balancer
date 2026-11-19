import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// A folder or a file that a step of `login` after the sign-in uses, and what a test does to it.
struct LaterStep: Sendable, CustomTestStringConvertible {
    enum Change: String, Sendable {
        /// An access list entry that lets everyone list the folder.
        case allowOthers
        /// An entry that denies the user listing the folder, so it does not open.
        case denyOpening
        /// An entry that denies the user adding a file or a folder to the folder.
        case denyNewFiles
        /// An entry that denies the user writing the file.
        case denyWriting
        /// An entry that denies the user writing the folder's extended attributes, on a token
        /// folder that is not yet marked as excluded from backups.
        case denyMarking
        /// The file swapped for a link to a copy of it.
        case link
        /// A file the tool did not make, put in the folder.
        case strayFile
        /// An entry that denies the user deleting the file, which a rename over it needs.
        case denyDelete
        /// An entry that denies the user `readattr` on the file, which keeps `lstat` out.
        case denyChecking
        /// An entry that denies the user reading the file.
        case denyReading
        /// The file locked with `chflags uchg`, as Finder's Locked box does.
        case locked
        /// The file made append-only with `chflags uappnd`.
        case appendOnly
        /// An inheritable entry that keeps the user from reading the list of what is made in the
        /// folder; the entry itself only denies, so the folder passes.
        case inheritUnreadableList
        /// An inheritable entry that denies the user reading what is made in the folder.
        case inheritNoRead
        /// An inheritable entry that denies the user writing what is made in the folder.
        case inheritNoWrite
        /// An inheritable entry that denies the user deleting what is made in the folder, which
        /// the check's own file then takes.
        case inheritNoDelete
        /// An inheritable entry that denies the user adding lines to what is made in the folder.
        case inheritNoAppend
        /// The file at mode 000, which no access list entry explains.
        case noReadMode
        /// A probe's folder whose own entry denies the user `readattr`, so `lstat` cannot check it.
        case uncheckableEntry
        /// A folder where the file belongs.
        case folderInPlace
    }

    let path: [String]
    let change: Change

    var testDescription: String { "\(change.rawValue) on \(path.joined(separator: "/"))" }

    var inAccounts: Bool { path.first == FolderPaths.accountsFolderName }

    /// A launch file of the label, whose name the home picks: the path ends in `*`.
    var isLaunchFile: Bool { path.last == "*" }

    /// Every folder the steps after the sign-in check, each with an allow entry and with a deny
    /// that keeps the user out; every folder they make a file in, with the user denied adding
    /// one; and the files and marks those steps check.
    static let all: [LaterStep] = {
        let tokens = [TokenPaths.folderName]
        let lab = [LaunchFiles.folder, "lab"]
        let work = FolderPaths.folders(label: "work")
        let folders: [[String]] = [
            [], Layout.locksFolders, Layout.stateFolders, Layout.readingsFolders,
            ReadingHistory.folders, Layout.logsFolders, Layout.probeFolders, tokens,
            [LaunchFiles.folder], lab, [FolderPaths.accountsFolderName], Array(work.dropLast()),
            work,
        ]
        var all = folders.flatMap {
            [LaterStep(path: $0, change: .allowOthers), LaterStep(path: $0, change: .denyOpening)]
        }
        let written: [[String]] = [
            [], Layout.locksFolders, Layout.stateFolders, Layout.readingsFolders,
            ReadingHistory.folders, Layout.logsFolders, Layout.probeFolders, tokens, lab,
        ]
        all += written.map { LaterStep(path: $0, change: .denyNewFiles) }
        all += [
            LaterStep(path: Layout.locksFolders + [Layout.pickLockName], change: .denyWriting),
            LaterStep(path: Layout.locksFolders + ["history.lock"], change: .denyWriting),
            LaterStep(path: Layout.stateFolders + [EventLog.fileName], change: .denyWriting),
            LaterStep(path: ReadingHistory.folders + ["lab.jsonl"], change: .denyWriting),
            LaterStep(path: Layout.logsFolders + [Layout.logName], change: .denyWriting),
            LaterStep(path: tokens, change: .denyMarking),
            LaterStep(path: tokens + ["lab.json"], change: .link),
            LaterStep(path: Layout.probeFolders + ["stray"], change: .strayFile),
        ]
        // The token file, the config, the stored reading and a launch file, each with the user
        // denied deleting it or the file locked; a state file and a history file denied deleting;
        // another state file, a history file, the pick lock and the log locked.
        let replaced: [[String]] = [
            tokens + ["lab.json"], [ConfigStore.fileName], Layout.readingsFolders + ["lab.json"],
            lab + ["*"],
        ]
        all += replaced.flatMap {
            [LaterStep(path: $0, change: .denyDelete), LaterStep(path: $0, change: .locked)]
        }
        all += [
            LaterStep(path: Layout.stateFolders + [StatusBuilder.currentName], change: .denyDelete),
            LaterStep(path: ReadingHistory.folders + ["lab.jsonl"], change: .denyDelete),
            LaterStep(path: Layout.stateFolders + [StatusBuilder.statusName], change: .locked),
        ]
        // Each file a step after the sign-in reads, with the user denied reading it.
        let read: [[String]] = [
            Layout.readingsFolders + ["lab.json"], Layout.stateFolders + ["current.json"],
            Layout.stateFolders + [EventLog.fileName], ReadingHistory.folders + ["lab.jsonl"],
            Layout.stateFolders + [StatusBuilder.rejectionsName], lab + ["*"],
        ]
        all += read.map { LaterStep(path: $0, change: .denyReading) }
        all += [
            LaterStep(path: lab + ["*"], change: .denyChecking),
            LaterStep(path: tokens + ["lab.json"], change: .appendOnly),
            LaterStep(path: Layout.locksFolders + [Layout.pickLockName], change: .locked),
            LaterStep(path: ReadingHistory.folders + ["lab.jsonl"], change: .locked),
            LaterStep(path: Layout.logsFolders + [Layout.logName], change: .locked),
            LaterStep(path: Layout.readingsFolders + ["lab.json"], change: .noReadMode),
            LaterStep(
                path: Layout.probeFolders + [Layout.probeFolderPrefix + "0123456789abcdef"],
                change: .uncheckableEntry),
            LaterStep(path: Layout.locksFolders + [Layout.pickLockName], change: .folderInPlace),
        ]
        // Each folder a step after the sign-in makes a file in, and the probe folder, in which a
        // probe makes its own folder, with an entry that passes on to what is made there.
        let inherited: [LaterStep.Change] = [
            .inheritUnreadableList, .inheritNoRead, .inheritNoWrite, .inheritNoDelete,
        ]
        all += (written.filter { $0 != Layout.probeFolders } + [Layout.probeFolders]).flatMap {
            path in inherited.map { LaterStep(path: path, change: $0) }
        }
        // Each folder a step after the sign-in adds lines to a file in.
        let appended: [[String]] = [
            Layout.stateFolders, ReadingHistory.folders, Layout.logsFolders,
        ]
        all += appended.map { LaterStep(path: $0, change: .inheritNoAppend) }
        return all
    }()
}

/// `login` runs the checks of every step after the sign-in before the sign-in starts or a pasted
/// token is read; once a token is saved, nothing it says asks for a new sign-in. `doctor` names a
/// folder wider than 0700 and goes on below it, and names every file and folder whose list cannot
/// be read.
extension AccessListPrivacyCLITests {
    /// A signed-in home where every step after a sign-in has something to check: a folder account
    /// `work`, a pick of `lab`, a history line, an event record and a log line. Without the folder
    /// account, which `doctor` finds signed out, an account folder `spare` stands in its place.
    func laterStepsHome(folderAccount: Bool = true) throws -> CLIHome {
        let cli = try signedIn()
        if folderAccount {
            #expect(try cli.run(["add", "work", "--kind", "folder"]).status == 0)
        } else {
            try NoFollowWriter(root: cli.dataRoot).prepare(
                folders: FolderPaths.folders(label: "spare"))
        }
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        try NoFollowWriter(root: cli.dataRoot).append(
            Data("line\n".utf8), folders: Layout.logsFolders, name: Layout.logName)
        try recordEndedRejection(cli)
        for path in [
            ReadingHistory.folders + ["lab.jsonl"], Layout.stateFolders + [EventLog.fileName],
            Layout.locksFolders + [Layout.pickLockName], [LaunchFiles.folder, "lab"],
            Layout.stateFolders + [StatusBuilder.rejectionsName],
            Layout.stateFolders + [StatusBuilder.statusName],
        ] {
            #expect(FileManager.default.fileExists(atPath: url(cli, path).path), "\(path)")
        }
        return cli
    }

    /// The record a rejection leaves once a check ended it: the token rejections file with no
    /// entry, as the status rebuild writes it.
    func recordEndedRejection(_ cli: CLIHome) throws {
        try NoFollowWriter(root: cli.dataRoot).put(
            try EventLog.encoder().encode(StatusBuilder.RejectionsFile()) + Data([0x0A]),
            folders: Layout.stateFolders, name: StatusBuilder.rejectionsName)
    }

    /// The file or folder `step` changes, a launch file of the label resolved to the one there.
    func target(_ step: LaterStep, _ cli: CLIHome) throws -> URL {
        guard step.isLaunchFile else { return url(cli, step.path) }
        let folder = url(cli, Array(step.path.dropLast()))
        let name = try #require(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().first {
                $0.hasPrefix("l-") && $0.hasSuffix(".json")
            })
        return folder.appendingPathComponent(name)
    }

    func runChflags(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        task.arguments = arguments
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Makes `step`'s change and returns what undoes it.
    func apply(_ step: LaterStep, _ cli: CLIHome) throws -> () throws -> Void {
        let target = try target(step, cli)
        func clear() throws {
            let status = try runChmod(["-N", target.path])
            #expect(status == 0, "\(step.testDescription)")
        }
        func flag(_ name: String) throws -> () throws -> Void {
            #expect(try runChflags([name, target.path]) == 0, "\(step.testDescription)")
            return {
                let status = try self.runChflags(["no" + name, target.path])
                #expect(status == 0, "\(step.testDescription)")
            }
        }
        // A probe makes a folder in the probe folder, so its entry passes on to folders.
        let inherit = step.path == Layout.probeFolders ? "directory_inherit" : "file_inherit"
        let read = step.path == Layout.probeFolders ? "list" : "read"
        let write = step.path == Layout.probeFolders ? "add_file" : "write"
        switch step.change {
        case .denyDelete:
            try add("\(me) deny delete", target)
        case .denyChecking:
            try add("\(me) deny readattr", target)
        case .denyReading:
            try add("\(me) deny read", target)
        case .locked:
            return try flag("uchg")
        case .appendOnly:
            return try flag("uappnd")
        case .inheritUnreadableList:
            try add("\(me) deny readsecurity,\(inherit),only_inherit", target)
        case .inheritNoRead:
            try add("\(me) deny \(read),\(inherit),only_inherit", target)
        case .inheritNoWrite:
            try add("\(me) deny \(write),\(inherit),only_inherit", target)
        case .inheritNoDelete:
            try add("\(me) deny delete,\(inherit),only_inherit", target)
        case .inheritNoAppend:
            try add("\(me) deny append,\(inherit),only_inherit", target)
        case .noReadMode:
            #expect(Darwin.chmod(target.path, 0o000) == 0, "\(step.testDescription)")
            return { #expect(Darwin.chmod(target.path, 0o600) == 0, "\(step.testDescription)") }
        case .uncheckableEntry:
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try add("\(me) deny readattr", target)
            return {
                try clear()
                try FileManager.default.removeItem(at: target)
            }
        case .folderInPlace:
            let kept = cli.home.appendingPathComponent("kept-lock")
            try FileManager.default.moveItem(at: target, to: kept)
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            return {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: kept, to: target)
            }
        case .allowOthers:
            try add("everyone allow list", target)
        case .denyOpening:
            try add("\(me) deny list", target)
        case .denyNewFiles:
            try add("\(me) deny add_file,add_subdirectory", target)
        case .denyWriting:
            try add("\(me) deny write,append", target)
        case .denyMarking:
            #expect(try xattr(["-d", NoFollowWriter.backupExcludeName, target.path]) == 0)
            try add("\(me) deny writeextattr", target)
            return {
                try clear()
                try NoFollowWriter(root: cli.dataRoot).markExcludedFromBackup(folders: step.path)
            }
        case .link:
            let kept = cli.home.appendingPathComponent("kept-file")
            try FileManager.default.moveItem(at: target, to: kept)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: kept)
            return {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: kept, to: target)
            }
        case .strayFile:
            #expect(FileManager.default.createFile(atPath: target.path, contents: Data()))
            return { try FileManager.default.removeItem(at: target) }
        }
        return clear
    }

    func xattr(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = arguments
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// The refusal `login` gives for `step` before any sign-in, with its fix.
    func refusal(_ step: LaterStep) -> String {
        let place = typed(step.path)
        switch step.change {
        case .allowOthers where step.inAccounts:
            return
                "Account 'work': its folder `\(place)` has an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(place)`, or run `agent-balancer remove work`."
        case .allowOthers:
            return folderRefusal(place)
        case .denyOpening where step.inAccounts:
            return
                "Account 'work': its folder `\(place)` cannot be opened or searched. Run `chmod -N \(place)`, then `chmod 700 \(place)`, or run `agent-balancer remove work`."
        case .denyOpening:
            return
                "Refused `\(place)`: it cannot be opened or searched. Run `chmod -N \(place)`, then `chmod 700 \(place)` in Terminal."
        case .denyNewFiles, .inheritNoDelete:
            return
                "Refused `\(place)`: the tool cannot make and delete what it writes in it. Run `chmod -N \(place)`, then `chmod 700 \(place)` in Terminal, and `chflags nouchg \(place)` first if it is locked."
        case .denyWriting where step.path.last?.hasSuffix(".lock") == true:
            return
                "Refused `\(place)`: the lock file cannot be opened. Run `chmod -N \(place)`, then `chmod 600 \(place)` in Terminal."
        case .denyWriting:
            return
                "Refused `\(place)`: it cannot be opened to write. Run `chmod -N \(place)`, then `chmod 600 \(place)` in Terminal, and `chflags nouchg \(place)` first if it is locked."
        case .denyMarking:
            return
                "Refused `\(place)`: it cannot be marked as excluded from backups. Run `chmod -N \(place)` in Terminal."
        case .link, .folderInPlace:
            return
                "Refused `\(place)`: it is not a regular file of yours, so the tool does not write it. Move it out of the way."
        case .uncheckableEntry:
            return
                "Refused `\(place)`: it cannot be checked, so the tool cannot tell whether it can remove it. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, in Terminal."
        case .strayFile:
            let probe = typed(Layout.probeFolders)
            return
                "Refused `\(probe)`: it holds something that is not a probe folder. Move what the tool did not make out of it."
        case .denyDelete, .locked, .appendOnly, .denyChecking, .denyReading, .noReadMode:
            let folder = typed(Array(step.path.dropLast()))
            let subject = step.isLaunchFile ? "a launch file in `\(folder)`" : "`\(place)`"
            let path = step.isLaunchFile ? folder + "/l-*.json" : place
            let lock = step.path.last == Layout.pickLockName
            let action =
                lock
                ? "open the lock file"
                : step.path.last == Layout.logName ? "write to it" : "replace or delete it"
            switch step.change {
            case .denyDelete:
                return
                    "Refused \(subject): its access list does not let the tool \(action). Run `chmod -N \(path)` in Terminal."
            case .locked:
                return
                    "Refused \(subject): it has the `uchg` flag set, so the tool cannot \(action). Run `chflags nouchg \(path)` in Terminal."
            case .denyChecking:
                return
                    "Refused \(subject): it cannot be checked, so the tool cannot tell whether it can \(action). Run `chmod -h -N \(path)`, or `chmod -N \(path)` if that says Permission denied, in Terminal."
            case .denyReading, .noReadMode:
                return
                    "Refused \(subject): the tool cannot read it. Run `chmod -N \(path)`, then `chmod 600 \(path)` in Terminal."
            default:
                return
                    "Refused \(subject): it has the `uappnd` flag set, so the tool cannot \(action). Run `chflags nouappnd \(path)` in Terminal."
            }
        case .inheritUnreadableList, .inheritNoRead, .inheritNoWrite, .inheritNoAppend:
            return
                "Refused `\(place)`: what the tool makes in it takes an access list that keeps the tool from reading, writing or checking it. Run `chmod -N \(place)` in Terminal."
        }
    }

    @Test(arguments: LaterStep.all)
    func loginRefusesWhatAStepAfterTheSignInWouldRefuseBeforeTheSignInStarts(_ step: LaterStep)
        throws
    {
        let cli = try laterStepsHome()
        defer { finish(cli) }
        let before = files(cli)
        let started = signIns(cli)
        let undo = try apply(step, cli)
        for paste in [false, true] {
            let name = "\(step.testDescription) paste \(paste)"
            let args = paste ? ["login", "lab", "--paste"] : ["login", "lab"]
            let refused = try cli.run(args, stdin: Canary.realShapeToken() + "\n")
            #expect(refused.status == 1, "\(name)")
            let said = text(refused.stderr)
            #expect(said.contains(refusal(step)), "\(name): \(said)")
            #expect(!text(refused.stdout).contains("Opening the browser"), "\(name)")
            #expect(!text(refused.stdout).contains("Paste the token"), "\(name)")
            #expect(signIns(cli) == started, "\(name)")
        }
        try undo()
        #expect(files(cli) == before, "\(step.testDescription)")
        // With the change undone, one sign-in saves.
        let done = try cli.run(["login", "lab"])
        #expect(done.status == 0, "\(step.testDescription): \(text(done.stderr))")
        #expect(signIns(cli) == started + 1, "\(step.testDescription)")
    }

    /// What lands while the person is in the browser or at the paste prompt, which no check
    /// before could see, and which step after the save it makes fail.
    enum LateChange: String, CaseIterable {
        /// A list on the first check's folder: the first check fails.
        case probeList
        /// The same while the paste prompt waits.
        case probeListAtThePrompt
        /// A list on a folder the save's config step checks: the time is not saved.
        case accountList
        /// The label's launch file locked: its rewrite fails.
        case launchFileLocked
    }

    @Test(arguments: LateChange.allCases)
    func aFailureAfterTheTokenIsSavedSaysSoAndNamesRefreshNotASecondSignIn(_ change: LateChange)
        throws
    {
        let saved =
            "The new token for 'lab' is saved, so no new sign-in is needed. Once the above is fixed, run `agent-balancer refresh --label lab` to check it."
        let name = change.rawValue
        let cli = try laterStepsHome()
        defer { finish(cli) }
        let started = signIns(cli)
        // A time from before, which only a token save that records its own replaces.
        let time = "2026-01-02T03:04:05Z"
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "lab" })
        config.accounts[index].tokenCreatedAt = time
        try store.save(config)
        let path: [String]
        switch change {
        case .probeList, .probeListAtThePrompt: path = Layout.probeFolders
        case .accountList: path = FolderPaths.folders(label: "work")
        case .launchFileLocked: path = [LaunchFiles.folder, "lab", "*"]
        }
        let target = try self.target(LaterStep(path: path, change: .locked), cli)
        let token = Canary.realShapeToken()
        let out: Support.Output
        if change == .probeListAtThePrompt {
            out = try cli.runOnTerminal(
                ["login", "lab", "--paste"], prompt: "Paste the token, then press Enter: ",
                between: { try self.add("everyone allow list", target) },
                typing: token + "\n")
        } else {
            let late =
                change == .launchFileLocked
                ? "/usr/bin/chflags uchg '\(target.path)'\n"
                : "/bin/chmod +a 'everyone allow list' '\(target.path)'\n"
            try cli.fake("setup-token.out", "Your token is \(token)\n")
            try cli.fake("during-setup-token.sh", late)
            out = try cli.run(["login", "lab"])
        }
        #expect(out.status == 1, "\(name)")
        let said = text(out.stdout) + text(out.stderr)
        #expect(said.contains("Saved the token for 'lab'."), "\(name)")
        #expect(said.hasSuffix(saved + "\n"), "\(name): \(said)")
        switch change {
        case .probeList, .probeListAtThePrompt:
            #expect(said.contains("`chmod -N \(typed(path))`"), "\(name): \(said)")
            #expect(said.contains("First check failed."), "\(name)")
        case .accountList:
            #expect(said.contains("`chmod -N \(typed(path))`"), "\(name): \(said)")
            #expect(
                said.contains(
                    "Error: The time the new token was made could not be saved in `~/.agent-balancer/config.json`, so its estimated end still counts from the time saved before, or from the token file's last change when there is none, and may show early: Account 'work':"
                ), "\(name): \(said)")
            #expect(said.contains("First check: read"), "\(name)")
        case .launchFileLocked:
            #expect(
                said.contains(
                    "Error: Launch files of 'lab' could not all be rewritten with the new token, so a session that uses one keeps the old token until it ends: "
                ), "\(name): \(said)")
            #expect(said.contains("First check: read"), "\(name)")
        }
        // The time saved before stays until a token save records the new one.
        let after = try #require(
            JSONSerialization.jsonObject(with: Data(cli.read("config.json").utf8))
                as? [String: Any])
        let kept =
            ((after["accounts"] as? [[String: Any]])?.first {
                $0["label"] as? String == "lab"
            })?["tokenCreatedAt"] as? String
        if change == .accountList {
            #expect(kept == time, "\(name)")
        } else {
            #expect(kept != nil && kept != time, "\(name)")
        }
        #expect(!said.contains("again"), "\(name)")
        #expect(!said.contains("agent-balancer login"), "\(name)")
        let paste = change == .probeListAtThePrompt
        #expect(signIns(cli) == started + (paste ? 0 : 1), "\(name)")
        // The fix it names and `refresh` finish the job with no second sign-in.
        try? FileManager.default.removeItem(
            at: cli.home.appendingPathComponent(".ab-fake/during-setup-token.sh"))
        if change == .launchFileLocked {
            #expect(try runChflags(["nouchg", target.path]) == 0, "\(name)")
        } else {
            #expect(try runChmod(["-N", target.path]) == 0, "\(name)")
        }
        let refresh = try cli.run(["refresh", "--label", "lab"])
        #expect(refresh.status == 0, "\(name): \(text(refresh.stdout))")
        #expect(try state(cli, "lab") == "ok", "\(name)")
        #expect(signIns(cli) == started + (paste ? 0 : 1), "\(name)")
    }

    @Test func aNewTokenTheServiceRejectsNamesOneRefreshFirstThenANewSignIn() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        let rejected = try String(
            contentsOf: cli.fixtures.appendingPathComponent("probe/auth_error.jsonl"),
            encoding: .utf8)
        try cli.fake("probe-for-lab.jsonl", rejected)
        try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 1)
        let said = text(out.stdout)
        #expect(said.contains("Saved the token for 'lab'."), "\(said)")
        #expect(
            said.contains(
                "First check failed. Error login_rejected: The service rejected the new token for 'lab'. Run `agent-balancer refresh --label lab` once; if the service rejects it again, run `agent-balancer login lab` in Terminal.\n"
            ), "\(said)")
        // No closing line here: that line says no new sign-in is needed.
        #expect(!said.contains("no new sign-in is needed"), "\(said)")
    }

    /// A change made while the person signs in, which no check before could see, stops the save:
    /// the text says the new token was not saved and what to run once the fix has run.
    @Test func aChangeDuringTheSignInThatStopsTheSaveSaysTheNewTokenWasNotSaved() throws {
        let cli = try laterStepsHome()
        defer { finish(cli) }
        let started = signIns(cli)
        let tokens = url(cli, [TokenPaths.folderName])
        let file = tokens.appendingPathComponent("lab.json")
        let before = try Data(contentsOf: file)
        try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
        try cli.fake(
            "during-setup-token.sh", "/bin/chmod +a 'everyone allow read' '\(tokens.path)'\n")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 1)
        #expect(signIns(cli) == started + 1)
        let said = text(out.stderr)
        #expect(
            said.contains(
                folderRefusal(typed([TokenPaths.folderName]))
                    + " The new token for 'lab' was not saved. Once the above is fixed, run `agent-balancer login lab` again."
            ), "\(said)")
        #expect(!text(out.stdout).contains("Saved the token"))
        #expect(try Data(contentsOf: file) == before)
    }

    // MARK: doctor

    func doctorLines(_ cli: CLIHome) throws -> (status: Int32, said: String) {
        let doctor = try cli.run(["doctor"])
        return (doctor.status, text(doctor.stdout))
    }

    /// Runs `doctor`, expects exit 1 and every line of `wanted`, runs every command it names,
    /// then expects exit 0.
    func doctorNamesThenClears(_ cli: CLIHome, _ wanted: [String], _ name: String) throws {
        let (status, said) = try doctorLines(cli)
        #expect(status == 1, "\(name)")
        for line in wanted { #expect(said.contains("Error: " + line + "\n"), "\(name): \(said)") }
        // A text may name `chmod -h -N` and `chmod -N` for when the first says Permission denied.
        let commands = chmodCommands(said, cli)
        for command in commands where try runChmod(command) != 0 {
            let fallback = ["-N"] + command.dropFirst(2)
            #expect(
                command.starts(with: ["-h", "-N"]) && commands.contains(fallback),
                "\(name): \(command)")
        }
        let (again, clean) = try doctorLines(cli)
        #expect(again == 0, "\(name): \(clean)")
    }

    /// `doctorFolderLine` without its `Error: ` tag.
    func sharedLine(_ place: String) -> String {
        String(doctorFolderLine(place).dropFirst("Error: ".count))
    }

    func wideLine(_ place: String) -> String {
        "`\(place)` is wider than 0700, so the tool refuses it. Run `chmod 700 \(place)` in Terminal, then run `agent-balancer doctor` again."
    }

    @Test func doctorNamesAFolderWiderThan0700AndWhatIsInItAndExitsOne() throws {
        let cli = try laterStepsHome(folderAccount: false)
        defer { finish(cli) }
        let tokens = [TokenPaths.folderName]
        let paths: [[String]] = [
            [], Layout.locksFolders, Layout.stateFolders, Layout.readingsFolders,
            ReadingHistory.folders, Layout.logsFolders, Layout.probeFolders, tokens,
            [LaunchFiles.folder], [LaunchFiles.folder, "lab"], [FolderPaths.accountsFolderName],
            FolderPaths.folders(label: "spare"),
        ]
        // A wide folder with nothing else wrong.
        for path in paths {
            chmod(url(cli, path).path, 0o755)
            try doctorNamesThenClears(cli, [wideLine(typed(path))], typed(path))
        }
        // A wide folder and a file in it whose list lets others in: one run names both.
        let stateFolder = Layout.stateFolders
        let status = stateFolder + ["status.json"]
        try add("everyone allow read", url(cli, status))
        chmod(url(cli, stateFolder).path, 0o755)
        let file = typed(status)
        try doctorNamesThenClears(
            cli,
            [
                wideLine(typed(stateFolder)),
                "`\(file)` has an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(file)` in Terminal.",
            ], "state and status.json")
        // The same for a token file in a wide token folder, which no command uses meanwhile.
        let token = tokens + ["lab.json"]
        try add("everyone allow read", url(cli, token))
        chmod(url(cli, tokens).path, 0o755)
        #expect(try state(cli, "lab") != "ok")
        let tokenPlace = typed(token)
        try doctorNamesThenClears(
            cli,
            [
                wideLine(typed(tokens)),
                "`\(tokenPlace)` has an access list that lets another user or group in, or that cannot be read, so its token is not used, and another user may have read it. Run `chmod -N \(tokenPlace)` in Terminal to use it again, or `agent-balancer login lab` to replace it.",
            ], "tokens and lab.json")
        // A folder both wide and shared gets one line with both commands.
        try add("everyone allow read", url(cli, tokens))
        chmod(url(cli, tokens).path, 0o755)
        let place = typed(tokens)
        try doctorNamesThenClears(
            cli,
            [
                "`\(place)` is wider than 0700 and has an access list that lets another user or group in, or that cannot be read, so the tool refuses it. Run `chmod 700 \(place)` and `chmod -N \(place)` in Terminal, then run `agent-balancer doctor` again."
            ], "tokens wide and shared")
        #expect(try state(cli, "lab") == "ok")
    }

    @Test func doctorNamesAFolderOfTheToolsThatIsALinkOrAFileAndExitsOne() throws {
        let cli = try laterStepsHome(folderAccount: false)
        defer { finish(cli) }
        func link(_ place: String) -> String {
            "`\(place)` is a link, which the tool never follows, so it refuses it. Move the folder the link points to back in its place, then run `agent-balancer doctor` again."
        }
        let paths: [[String]] = [
            [TokenPaths.folderName], Layout.locksFolders, Layout.stateFolders,
            Layout.readingsFolders, ReadingHistory.folders, Layout.logsFolders,
            Layout.probeFolders, Layout.backupsFolders, [LaunchFiles.folder],
            [LaunchFiles.folder, "lab"], [FolderPaths.accountsFolderName],
            FolderPaths.folders(label: "spare"),
        ]
        let moved = cli.home.appendingPathComponent("moved-folder")
        for path in paths {
            let place = typed(path)
            let folder = url(cli, path)
            try FileManager.default.moveItem(at: folder, to: moved)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
            let (status, said) = try doctorLines(cli)
            #expect(status == 1, "\(place)")
            #expect(said.contains("Error: " + link(place) + "\n"), "\(place): \(said)")
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: moved, to: folder)
            #expect(try doctorLines(cli).status == 0, "\(place)")
        }
        // A file where a folder of the tool's belongs, and a probe folder that holds a stray file.
        let logs = url(cli, Layout.logsFolders)
        try FileManager.default.moveItem(at: logs, to: moved)
        #expect(FileManager.default.createFile(atPath: logs.path, contents: Data()))
        var (status, said) = try doctorLines(cli)
        #expect(status == 1)
        let place = typed(Layout.logsFolders)
        #expect(
            said.contains(
                "Error: `\(place)` is not a folder, so the tool refuses it. Move it out of the way, then run `agent-balancer doctor` again.\n"
            ), "\(said)")
        try FileManager.default.removeItem(at: logs)
        try FileManager.default.moveItem(at: moved, to: logs)
        let stray = url(cli, Layout.probeFolders + ["stray"])
        #expect(FileManager.default.createFile(atPath: stray.path, contents: Data()))
        (status, said) = try doctorLines(cli)
        #expect(status == 1)
        let probe = typed(Layout.probeFolders)
        #expect(
            said.contains(
                "Error: `\(probe)` holds something that is not a probe folder, so every probe refuses it. Move what the tool did not make out of it, then run `agent-balancer doctor` again.\n"
            ), "\(said)")
        try FileManager.default.removeItem(at: stray)
        #expect(try doctorLines(cli).status == 0)
    }

    @Test func doctorNamesAFolderInsideOneItRefusesForItsListInTheSameRun() throws {
        let cli = try laterStepsHome(folderAccount: false)
        defer { finish(cli) }
        let stateFolder = Layout.stateFolders
        try add("everyone allow read", url(cli, Layout.readingsFolders))
        try add("everyone allow read", url(cli, stateFolder + ["status.json"]))
        try add("everyone allow list", url(cli, stateFolder))
        let file = typed(stateFolder + ["status.json"])
        try doctorNamesThenClears(
            cli,
            [
                sharedLine(typed(stateFolder)), sharedLine(typed(Layout.readingsFolders)),
                "`\(file)` has an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(file)` in Terminal.",
            ], "state")
    }

    /// The states doctor reads through a branch of its own: a list the user cannot read on a
    /// file, a launch file, the data folder or the launch folder; a writer's temporary file in the
    /// token folder that lets others in; a folder that cannot be checked or opened.
    @Test func doctorNamesWhatItCannotReadOrOpenAndExitsOne() throws {
        let state = Layout.stateFolders
        let temporary = [
            TokenPaths.folderName,
            NoFollowWriter.temporaryPrefix + String(repeating: "0a", count: 8),
        ]
        let cases: [(path: [String], entry: String, line: (String) -> String)] = [
            (
                state + ["status.json"], "\(me) deny readsecurity",
                {
                    "`\($0)` cannot be checked, so the tool cannot tell who can read it. Run `chmod -h -N \($0)`, or `chmod -N \($0)` if that says Permission denied."
                }
            ),
            (
                temporary, "everyone allow read",
                {
                    "`\($0)` has an access list that lets another user or group in, or that cannot be read. Run `chmod -N \($0)` in Terminal."
                }
            ),
            (
                state, "\(me) deny readattr,list,search",
                {
                    "`\($0)` cannot be checked, so the tool cannot tell what it is, and what is in it is checked once it can. Run `chmod -h -N \($0)`, or `chmod -N \($0)` if that says Permission denied, then `chmod -h 700 \($0)`, then run `agent-balancer doctor` again."
                }
            ),
            (
                state, "\(me) deny list,search",
                {
                    "`\($0)` cannot be opened or searched, so the tool refuses it, and what is in it is checked once it opens. Run `chmod -N \($0)`, then `chmod 700 \($0)`, then run `agent-balancer doctor` again."
                }
            ),
            ([], "\(me) deny readsecurity", { self.sharedLine($0) }),
            ([LaunchFiles.folder], "\(me) deny readsecurity", { self.sharedLine($0) }),
        ]
        for item in cases {
            let cli = try laterStepsHome(folderAccount: false)
            defer { finish(cli) }
            let target = url(cli, item.path)
            if item.path == temporary {
                #expect(FileManager.default.createFile(atPath: target.path, contents: Data()))
            }
            try add(item.entry, target)
            let place = typed(item.path)
            try doctorNamesThenClears(cli, [item.line(place)], "\(item.entry) on \(place)")
        }
        // A launch file whose list the user cannot read is named by its folder.
        let cli = try laterStepsHome(folderAccount: false)
        defer { finish(cli) }
        let folder = url(cli, [LaunchFiles.folder, "lab"])
        let file = try #require(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).first {
                $0.hasPrefix("l-")
            })
        try add("\(me) deny readsecurity", folder.appendingPathComponent(file))
        let place = typed([LaunchFiles.folder, "lab"])
        try doctorNamesThenClears(
            cli,
            [
                "Launch files in `\(place)` have an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(place)/l-*.json` in Terminal."
            ], "launch file")
    }

    @Test func aTokenFolderRefusedForItsModeOrAsALinkGivesItsFixInStatusPickAndRun() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        let tokens = url(cli, [TokenPaths.folderName])
        let place = typed([TokenPaths.folderName])
        let elsewhere = cli.home.appendingPathComponent("moved-folder")
        let cases: [(String, () throws -> Void, () throws -> Void)] = [
            (
                "Refused `\(place)`: it is wider than 0700. Run `chmod 700 \(place)` in Terminal.",
                { chmod(tokens.path, 0o755) }, { chmod(tokens.path, 0o700) }
            ),
            (
                "Refused `\(place)`: it is a link or not a folder, and the tool never follows a link. Move what is there out of the way, or move the folder a link points to back in its place.",
                {
                    try FileManager.default.moveItem(at: tokens, to: elsewhere)
                    try FileManager.default.createSymbolicLink(
                        at: tokens, withDestinationURL: elsewhere)
                },
                {
                    try FileManager.default.removeItem(at: tokens)
                    try FileManager.default.moveItem(at: elsewhere, to: tokens)
                }
            ),
        ]
        for (refusal, make, undo) in cases {
            try make()
            #expect(try errorText(cli, "lab") == refusal)
            let pick = try cli.run(["pick", "--json", "--exclude", "main"])
            #expect(pick.status == 2)
            let picked = try #require(
                JSONSerialization.jsonObject(with: pick.stdout) as? [String: Any])
            let rows = try #require(picked["candidates"] as? [[String: Any]])
            #expect(rows.first { $0["label"] as? String == "lab" }?["reason"] as? String == refusal)
            #expect(text(try cli.run(["run", "--print-command", "lab"]).stderr).contains(refusal))
            try undo()
            #expect(try state(cli, "lab") == "ok")
        }
    }

    @Test func aProbeOfATokenFileOthersMayReadGivesItsTextAndNoProbeRuns() throws {
        let cli = try signedIn()
        defer { finish(cli) }
        let file = try tokenFile(cli)
        let probes = cli.fakeRecord("args.log").split(separator: "\n").filter {
            $0.hasPrefix("-p")
        }.count
        try add("everyone allow read", file)
        let refresh = try cli.run(["refresh", "--label", "lab"])
        #expect(refresh.status == 1)
        #expect(
            text(refresh.stdout).contains(
                "lab: Error token_missing: The token file of 'lab' may be readable by others, so its token is not used. Run `agent-balancer doctor` in Terminal."
            ))
        #expect(
            cli.fakeRecord("args.log").split(separator: "\n").filter { $0.hasPrefix("-p") }.count
                == probes)
    }

    @Test func noDoctorLineIsCutAtTheLongestLabel() throws {
        let long = "abcdefghijklmnopqrstuvwxyz012345"
        #expect(long.count == 32)
        let cli = try setUp()
        defer { finish(cli) }
        #expect(try cli.run(["add", long]).status == 0)
        try cli.fake("setup-token.out", "Your token is \(Canary.realShapeToken())\n")
        #expect(try cli.run(["login", long]).status == 0)
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        let folderLabel = "z" + long.dropFirst()
        try NoFollowWriter(root: cli.dataRoot).prepare(
            folders: FolderPaths.folders(label: folderLabel))
        let token = [TokenPaths.folderName, long + ".json"]
        let launch = [LaunchFiles.folder, long]
        let claude = FolderPaths.folders(label: folderLabel)
        try add("\(me) deny readsecurity", url(cli, token))
        try add("\(me) deny readattr,list,search", url(cli, launch))
        try add("\(me) deny readattr,list,search", url(cli, claude))
        func cannotCheck(_ place: String) -> String {
            "`\(place)` cannot be checked, so the tool cannot tell what it is, and what is in it is checked once it can. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, then `chmod -h 700 \(place)`, then run `agent-balancer doctor` again."
        }
        let tokenPlace = typed(token)
        let lines = [
            "`\(tokenPlace)` cannot be checked, so its token is not used, and another user may have read it. Run `chmod -h -N \(tokenPlace)`, or `chmod -N \(tokenPlace)` if that says Permission denied, to use it again.",
            cannotCheck(typed(launch)), cannotCheck(typed(claude)),
        ]
        #expect(lines.dropFirst().allSatisfy { $0.count > 400 })
        try doctorNamesThenClears(cli, lines, "long labels")
    }
}

/// A folder account's `login` saves the plan it finds after the sign-in, a save that checks every
/// folder account's folders: those checks run before `claude` starts, and a failure after the
/// sign-in says the sign-in is kept and names `refresh`.
extension FolderAccountsCLITests {
    @Test func aFolderLoginChecksThePlanSaveBeforeClaudeStartsAndKeepsASignInAfter() throws {
        let cli = try setUp()
        defer {
            let clear = Process()
            clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
            clear.arguments = ["-R", "-N", cli.home.path]
            try? clear.run()
            clear.waitUntilExit()
            cli.cleanup()
        }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        try cli.fake("auth-after-sign-in.json", try authJSON(cli, loggedIn: true))
        let store = ConfigStore(context: context(cli))
        var config = try store.loadRequired()
        config.accounts[1].expectedPlanTier = nil
        config.accounts.append(Account(label: "work", kind: Kind.folder, role: Role.pool))
        try store.save(config)
        try NoFollowWriter(root: cli.dataRoot).prepare(folders: FolderPaths.folders(label: "work"))
        let work = cli.dataRoot.appendingPathComponent(FolderPaths.accountsFolderName)
            .appendingPathComponent("work")
        let place = "~/.agent-balancer/" + FolderPaths.accountsFolderName + "/work"
        let refusal =
            "Account 'work': its folder `\(place)` has an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(place)`, or run `agent-balancer remove work`."
        func chmod(_ arguments: [String]) throws -> Int32 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/chmod")
            task.arguments = arguments
            task.standardError = Pipe()
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        }
        // Before the sign-in: refused with the folder's fix, and `claude` never starts, so the
        // sign-in the fake stages never takes effect.
        #expect(try chmod(["+a", "everyone allow list", work.path]) == 0)
        let before = cli.fakeRecord("auth.json")
        let refused = try cli.run(["login", "spare"])
        #expect(refused.status == 1)
        #expect(text(refused.stderr).contains(refusal), "\(text(refused.stderr))")
        #expect(!text(refused.stdout).contains("Starting claude"))
        #expect(cli.fakeRecord("auth.json") == before)
        #expect(try chmod(["-N", work.path]) == 0)
        // During the sign-in: the sign-in is kept and `refresh` records the plan.
        try cli.fake("during-sign-in.sh", "/bin/chmod +a 'everyone allow list' '\(work.path)'\n")
        let late = try cli.run(["login", "spare"])
        #expect(late.status == 1)
        let said = text(late.stdout)
        #expect(
            said.contains(
                "Error check_failed: 'spare' is signed in, but its plan could not be recorded: \(refusal) Once that is fixed, run `agent-balancer refresh --label spare`, which records it; no new sign-in is needed."
            ), "\(said)")
        #expect(!said.contains("agent-balancer login"))
        #expect(try store.loadRequired().account("spare")?.expectedPlanTier == nil)
        #expect(try chmod(["-N", work.path]) == 0)
        let refresh = try cli.run(["refresh", "--label", "spare"])
        #expect(refresh.status == 0, "\(text(refresh.stdout))")
        #expect(try store.loadRequired().account("spare")?.expectedPlanTier == "max_20x")
        // The plan save's lock too: an entry on `locks/` or a deny on the pick lock stops it
        // before `claude` starts, through the call the save's own checks use.
        let locks = cli.dataRoot.appendingPathComponent("locks")
        let pick = locks.appendingPathComponent(Layout.pickLockName)
        try store.save(config)
        try signedIn(cli, loggedIn: false)
        let me = NSUserName()
        let cases: [(URL, String, String)] = [
            (
                locks, "everyone allow list",
                "Refused `~/.agent-balancer/locks`: its access list lets another user or group in, or cannot be read. Run `chmod -N ~/.agent-balancer/locks` in Terminal."
            ),
            (
                pick, "\(me) deny write,append",
                "Refused `~/.agent-balancer/locks/pick.lock`: the lock file cannot be opened. Run `chmod -N ~/.agent-balancer/locks/pick.lock`, then `chmod 600 ~/.agent-balancer/locks/pick.lock` in Terminal."
            ),
        ]
        for (target, entry, refused) in cases {
            #expect(try chmod(["+a", entry, target.path]) == 0)
            let auth = cli.fakeRecord("auth.json")
            let stopped = try cli.run(["login", "spare"])
            #expect(stopped.status == 1, "\(entry)")
            #expect(text(stopped.stderr).contains(refused), "\(entry): \(text(stopped.stderr))")
            #expect(!text(stopped.stdout).contains("Starting claude"), "\(entry)")
            #expect(cli.fakeRecord("auth.json") == auth, "\(entry)")
            #expect(try chmod(["-N", target.path]) == 0)
        }
    }

    @Test func aFolderAccountsFolderRefusedForItsListOrModeGivesItsFixInEveryCommand() throws {
        let cli = try setUp()
        defer {
            let clear = Process()
            clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
            clear.arguments = ["-R", "-N", cli.home.path]
            try? clear.run()
            clear.waitUntilExit()
            cli.cleanup()
        }
        try linked(cli)
        let folder = try folderPath(cli)
        let place =
            "~/.agent-balancer/" + FolderPaths.folders(label: "spare").joined(separator: "/")
        let changes: [(String, () throws -> Void, () throws -> Void, String)] = [
            (
                "list",
                {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/chmod")
                    task.arguments = ["+a", "everyone allow list", folder]
                    try task.run()
                    task.waitUntilExit()
                },
                {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/chmod")
                    task.arguments = ["-N", folder]
                    try task.run()
                    task.waitUntilExit()
                },
                "Account 'spare': its folder `\(place)` has an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(place)`, or run `agent-balancer remove spare`."
            ),
            (
                "mode", { Darwin.chmod(folder, 0o755) }, { Darwin.chmod(folder, 0o700) },
                "Account 'spare': its folder `\(place)` is wider than 0700. Run `chmod 700 \(place)`, or run `agent-balancer remove spare`."
            ),
        ]
        for (name, make, undo, refusal) in changes {
            try make()
            let login = try cli.run(["login", "spare"])
            #expect(login.status == 1, "\(name)")
            #expect(text(login.stderr).contains(refusal), "\(name): \(text(login.stderr))")
            let refresh = try cli.run(["refresh", "--label", "spare"])
            #expect(text(refresh.stdout).contains(refusal), "\(name): \(text(refresh.stdout))")
            let row = try self.row(cli, "spare")
            let shown = (row["error"] as? [String: Any])?["text"] as? String
            #expect(shown == refusal, "\(name): \(shown ?? "none")")
            let pick = try cli.run(["pick", "--json", "--exclude", "main"])
            let picked = try #require(
                JSONSerialization.jsonObject(with: pick.stdout) as? [String: Any])
            let rows = try #require(picked["candidates"] as? [[String: Any]])
            let reason = rows.first { $0["label"] as? String == "spare" }?["reason"] as? String
            #expect(reason == refusal, "\(name): \(reason ?? "none")")
            let doctor = try cli.run(["doctor"])
            #expect(doctor.status == 1, "\(name)")
            #expect(
                text(doctor.stdout).contains("  Error check_failed: " + refusal + "\n"),
                "\(name): \(text(doctor.stdout))")
            for said in [login.stderr, refresh.stdout, doctor.stdout].map(text) {
                #expect(!said.contains("missing or is a link"), "\(name)")
                #expect(!said.contains("then add it again"), "\(name)")
            }
            try undo()
        }
    }

    @Test func aFolderLoginChecksTheStatusRebuildBeforeClaudeStarts() throws {
        let cli = try setUp()
        defer {
            for (tool, arguments) in [
                ("/usr/bin/chflags", ["-R", "nouchg", cli.home.path]),
                ("/bin/chmod", ["-R", "-N", cli.home.path]),
            ] {
                let clear = Process()
                clear.executableURL = URL(fileURLWithPath: tool)
                clear.arguments = arguments
                try? clear.run()
                clear.waitUntilExit()
            }
            cli.cleanup()
        }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        try cli.fake("auth-after-sign-in.json", try authJSON(cli, loggedIn: true))
        _ = try row(cli, "spare")
        let status = cli.dataRoot.appendingPathComponent("state")
            .appendingPathComponent(StatusBuilder.statusName)
        #expect(FileManager.default.fileExists(atPath: status.path))
        func chflags(_ flag: String) throws -> Int32 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
            task.arguments = [flag, status.path]
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        }
        // The rebuild that records the sign-in replaces `status.json`, so a lock on it stops it.
        #expect(try chflags("uchg") == 0)
        let auth = cli.fakeRecord("auth.json")
        let stopped = try cli.run(["login", "spare"])
        #expect(stopped.status == 1)
        let place = "~/.agent-balancer/state/" + StatusBuilder.statusName
        #expect(
            text(stopped.stderr).contains(
                "Refused `\(place)`: it has the `uchg` flag set, so the tool cannot replace or delete it. Run `chflags nouchg \(place)` in Terminal."
            ), "\(text(stopped.stderr))")
        #expect(!text(stopped.stdout).contains("Starting claude"))
        #expect(cli.fakeRecord("auth.json") == auth)
        #expect(try chflags("nouchg") == 0)
        let done = try cli.run(["login", "spare"])
        #expect(done.status == 0, "\(text(done.stdout))")
        #expect(text(done.stdout).contains("Signed in."))
    }

    /// The longest folder account text, at a 32-character label, prints whole in every command.
    /// The label repeats, so the scrubber that reads the status row's text keeps it.
    @Test func aFolderAccountsLongestRefusalPrintsWholeInEveryCommand() throws {
        let long = "long-label-long-label-long-label"
        #expect(long.count == 32)
        let cli = try setUp(folder: false)
        defer {
            let clear = Process()
            clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
            clear.arguments = ["-R", "-N", cli.home.path]
            try? clear.run()
            clear.waitUntilExit()
            cli.cleanup()
        }
        let store = ConfigStore(context: context(cli))
        var config = try store.loadRequired()
        config.accounts.append(
            Account(
                label: long, kind: Kind.folder, role: Role.pool, email: Self.email,
                expectedPlanTier: "max_20x"))
        try store.save(config)
        try NoFollowWriter(root: cli.dataRoot).prepare(folders: FolderPaths.folders(label: long))
        let folder = try FolderPaths.configDir(context: context(cli), label: long).path
        // Signed in as the expected account, so only the refusal below can stand in the row.
        try cli.fake(
            "auth.json",
            #"{"loggedIn":true,"email":"\#(Self.email)","planTier":"max_20x","configDirectory":"\#(folder)"}"#
        )
        try cli.fake("auth.exit", "0")
        let linked = try cli.runOnTerminal(["link", long], typing: long + "\n")
        #expect(linked.status == 0, "\(text(linked.stderr))")
        let place = "~/.agent-balancer/" + FolderPaths.folders(label: long).joined(separator: "/")
        let refusal =
            "Account '\(long)': its folder `\(place)` cannot be checked. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, then `chmod -h 700 \(place)`, or run `agent-balancer remove \(long)`."
        #expect(refusal.count > 400)
        let deny = Process()
        deny.executableURL = URL(fileURLWithPath: "/bin/chmod")
        // Kept out of `lstat` and of an open, so no command can tell what the folder is.
        deny.arguments = ["+a", "\(NSUserName()) deny readattr,list,search", folder]
        try deny.run()
        deny.waitUntilExit()
        #expect(deny.terminationStatus == 0)
        let login = try cli.run(["login", long])
        #expect(login.status == 1)
        #expect(text(login.stderr).contains(refusal), "\(text(login.stderr))")
        let refresh = try cli.run(["refresh", "--label", long])
        #expect(text(refresh.stdout).contains(refusal), "\(text(refresh.stdout))")
        let shown = (try row(cli, long)["error"] as? [String: Any])?["text"] as? String
        #expect(shown == refusal, "\(shown ?? "none")")
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        let picked = try #require(
            JSONSerialization.jsonObject(with: pick.stdout) as? [String: Any])
        let rows = try #require(picked["candidates"] as? [[String: Any]])
        let reason = rows.first { $0["label"] as? String == long }?["reason"] as? String
        #expect(reason == refusal, "\(reason ?? "none")")
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        #expect(
            text(doctor.stdout).contains("  Error check_failed: " + refusal + "\n"),
            "\(text(doctor.stdout))")
    }
}

import Core
import Foundation
import Testing

@testable import Core

private func output(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// The texts `uninstall` shows before and after the typed word, what `run` leaves when `claude`
/// cannot start, a settings path no reader can fix, and a sign-in that reports no email.
extension PersonCommandsCLITests {
    func lockCount(_ cli: CLIHome) -> Int {
        let locks = cli.dataRoot.appendingPathComponent("locks")
        return ((try? FileManager.default.contentsOfDirectory(atPath: locks.path)) ?? []).count
    }

    // MARK: uninstall

    @Test func uninstallListsTheLocksAndTheProbeAndSaysOrMoreWhenRecordsCannotBeRead() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        // One job record that can be read names the launch file; one session record cannot be read.
        let jobs = cli.home.appendingPathComponent(".claude/jobs/j1")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "sessionId": "s1", "state": "running", "respawnFlags": ["--settings", launch.path],
        ]
        try JSONSerialization.data(withJSONObject: record).write(
            to: jobs.appendingPathComponent("state.json"))
        try FileManager.default.createDirectory(
            at: cli.home.appendingPathComponent(".claude/sessions/999.json"),
            withIntermediateDirectories: true)
        try NoFollowWriter(root: cli.dataRoot).put(
            Data("{}".utf8), folders: ["probe", "p-0123456789abcdef"], name: "x.jsonl")
        let locks = lockCount(cli)
        #expect(locks > 0)

        let refused = try cli.run(["uninstall"], stdin: "no\n")
        #expect(refused.status == 1)
        let listing = output(refused.stdout)
        #expect(listing.contains("\n  lock files: \(locks)\n"))
        #expect(listing.contains("\n  probe files: 1\n"))
        #expect(listing.contains("\n  launch files a session record still names: 1 or more\n"))
        #expect(
            listing.contains(
                "Some session records could not be read, so every launch file is kept as a tombstone."
            ))
        #expect(!listing.contains(secret) && !listing.contains("/l-"))

        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 0, "\(output(done.stderr))")
        #expect(
            output(done.stdout).contains(
                "Kept 1 launch files as tombstones. They hold no token, and a rerun of `agent-balancer uninstall` deletes them once nothing names them and 10 minutes have passed since this run."
            ))
        #expect(!output(done.stdout).contains(secret))
        #expect(
            !FileManager.default.fileExists(
                atPath: cli.dataRoot.appendingPathComponent("probe").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: cli.dataRoot.appendingPathComponent("locks").path))
    }

    @Test func uninstallShowsAPlainCountWhenEveryRecordCanBeRead() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let listing = output(try cli.run(["uninstall"], stdin: "no\n").stdout)
        #expect(listing.contains("\n  launch files a session record still names: 0\n"))
        #expect(!listing.contains("or more") && !listing.contains("could not be read"))
        #expect(listing.contains("\n  probe files: 0\n"))
        #expect(listing.contains("\n  temporary files that may hold a token: 0\n"))
        #expect(!listing.contains("other letter case"))
        #expect(
            listing.contains(
                "\nAccount folders, every login and anything the tool did not make stay where they are. The data folder goes too when nothing is left in it.\n"
            ))
    }

    @Test func uninstallSaysWhenTheLeaseFileCannotBeRead() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        try NoFollowWriter(root: cli.dataRoot).put(
            Data("not json".utf8), folders: Layout.stateFolders, name: Layout.leasesName)
        let listing = output(try cli.run(["uninstall"], stdin: "no\n").stdout)
        #expect(
            listing.contains(
                "\nThe lease file could not be read, so every launch file is kept as a tombstone.\n"
            ))
        #expect(!listing.contains("Some session records could not be read"))
    }

    @Test func uninstallSaysWhenATokenFileStillHoldsATokenAndARerunListsIt() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        let folder = try TokenPaths.fileURL(context: context, label: "pool-a")
            .deletingLastPathComponent()
        chmod(folder.path, 0o500)
        defer { chmod(folder.path, 0o700) }
        try #require(access(folder.path, W_OK) != 0)
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        // A token file is still there, so the run is not done.
        #expect(done.status == 1, "\(output(done.stderr))")
        #expect(!output(done.stderr).contains("Error"))
        let shown = output(done.stdout)
        #expect(shown.contains("Deleted 0 token files"))
        #expect(shown.contains(TokenAccounts.undeletedTokenFilesText(1)))
        #expect(
            shown.contains(
                "1 token files could not be deleted and still hold a token. Make `~/.agent-balancer/"
                    + TokenPaths.folderName
                    + "/` writable and run `agent-balancer uninstall` again."))
        let again = output(try cli.run(["uninstall"], stdin: "no\n").stdout)
        #expect(again.contains("\n  token files: 1\n"))
    }

    @Test func uninstallListsATemporaryFileThatMayHoldATokenAndARerunStillSeesIt() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        let file = try TokenPaths.fileURL(context: context, label: "pool-a")
        let folder = file.deletingLastPathComponent()
        // What a token write stopped before its rename leaves: the whole file under a temporary name.
        try FileManager.default.moveItem(
            at: file, to: folder.appendingPathComponent(".tmp-0123456789abcdef"))
        let listing = output(try cli.run(["uninstall"], stdin: "no\n").stdout)
        #expect(listing.contains("\n  temporary files that may hold a token: 1\n"))
        chmod(folder.path, 0o500)
        defer { chmod(folder.path, 0o700) }
        try #require(access(folder.path, W_OK) != 0)
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 1, "\(output(done.stderr))")
        #expect(output(done.stdout).contains(TokenAccounts.undeletedTemporariesText(1)))
        let said =
            "1 temporary files could not be deleted and may hold a token. Make `~/.agent-balancer/"
            + TokenPaths.folderName + "/` and the launch folders writable and run "
            + "`agent-balancer uninstall` again."
        #expect(output(done.stdout).contains(said))
        let again = output(try cli.run(["uninstall"], stdin: "no\n").stdout)
        #expect(!again.contains("Nothing to remove"))
        #expect(again.contains("\n  temporary files that may hold a token: 1\n"))
    }

    @Test func aSessionThatNamesALaunchFileWhileThePromptWaitsKeepsItAsATombstone() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        // Older than the lease window with its lease ended, so only a session record keeps it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 3600)], ofItemAtPath: launch.path)
        try LeaseStore(context: ToolContext(home: cli.home, ambient: [:])).save([])
        let out = try cli.runOnTerminal(
            ["uninstall"], prompt: "Type uninstall to remove these: ",
            between: {
                let jobs = cli.home.appendingPathComponent(".claude/jobs/j1")
                try FileManager.default.createDirectory(
                    at: jobs, withIntermediateDirectories: true)
                let record: [String: Any] = [
                    "sessionId": "s1", "state": "running",
                    "respawnFlags": ["--settings", launch.path],
                ]
                try JSONSerialization.data(withJSONObject: record).write(
                    to: jobs.appendingPathComponent("state.json"))
            }, typing: "uninstall\n")
        #expect(out.status == 0, "\(output(out.stderr))")
        let shown = output(out.stdout)
        // The listing came before the session started; the removal read the records again.
        #expect(shown.contains("\n  launch files a session record still names: 0\n"))
        #expect(shown.contains("Kept 1 launch files as tombstones."))
        let kept = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: launch)) as? [String: Any])
        #expect((kept["env"] as? [String: String])?[ProtectedEnv.tokenVariable] == "invalid")
        #expect(!shown.contains(secret))
    }

    @Test func uninstallSaysARerunStartsFromTheDefaultLeaseWindowOnceTheConfigIsGone() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var config = try store.loadRequired()
        config.picker.leaseMinutes = 5
        try store.save(config)
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let listing = output(try cli.run(["uninstall"], stdin: "no\n").stdout)
        #expect(listing.contains("younger than 5 minutes"))
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 0, "\(output(done.stderr))")
        // The run deleted the config, so a rerun reads no window of 5 minutes.
        #expect(
            output(done.stdout).contains(
                "Kept 1 launch files as tombstones. They hold no token, and a rerun of `agent-balancer uninstall` deletes them once nothing names them and 10 minutes have passed since this run."
            ))
    }

    @Test func uninstallRefusesADataFolderThatIsALinkOrNotPrivateInsteadOfNothingToRemove() throws {
        // Moved elsewhere and linked back: the token file is still there, behind the link.
        let linked = try setUp(token: Canary.realShapeToken())
        defer { linked.cleanup() }
        let moved = linked.home.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: linked.dataRoot, to: moved)
        try FileManager.default.createSymbolicLink(at: linked.dataRoot, withDestinationURL: moved)
        let token = moved.appendingPathComponent(TokenPaths.folderName).appendingPathComponent(
            "pool-a.json")
        let out = try linked.run(["uninstall"], stdin: "uninstall\n")
        #expect(out.status == 1)
        #expect(output(out.stderr).contains(Messages.uninstallDataFolderIsALink))
        #expect(!output(out.stdout).contains("Nothing to remove"))
        #expect(FileManager.default.fileExists(atPath: token.path))

        let wide = try setUp(token: Canary.realShapeToken())
        defer { wide.cleanup() }
        chmod(wide.dataRoot.path, 0o755)
        defer { chmod(wide.dataRoot.path, 0o700) }
        let refused = try wide.run(["uninstall"], stdin: "uninstall\n")
        #expect(refused.status == 1)
        #expect(
            output(refused.stderr).contains(
                Messages.uninstallFolderRefused(
                    "The data folder", "~/.agent-balancer", .widerThanPrivate)))
        #expect(!output(refused.stdout).contains("Nothing to remove"))
        chmod(wide.dataRoot.path, 0o700)
        #expect(!wide.read("config.json").isEmpty)
    }

    @Test func uninstallRefusesATokenFolderThatIsNotPrivateInsteadOfNothingToRemove() throws {
        let cli = try CLIHome(installFake: false)
        defer { cli.cleanup() }
        // Only a token file, in a token folder that is not private.
        try NoFollowWriter(root: cli.dataRoot).put(
            Data("{}".utf8), folders: TokenPaths.folders, name: "pool-a.json")
        let folder = cli.dataRoot.appendingPathComponent(TokenPaths.folderName)
        chmod(folder.path, 0o755)
        defer { chmod(folder.path, 0o700) }
        let out = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(out.status == 1)
        #expect(
            output(out.stderr).contains(
                Messages.uninstallFolderRefused(
                    "The token folder", "~/.agent-balancer/" + TokenPaths.folderName,
                    .widerThanPrivate)))
        #expect(!output(out.stdout).contains("Nothing to remove"))
        #expect(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("pool-a.json").path))
    }

    @Test func uninstallRefusesATokenOrLaunchFolderThatIsALinkInsteadOfNothingToRemove() throws {
        // Only a link where the token folder belongs, with a token file behind it.
        let alone = try CLIHome(installFake: false)
        defer { alone.cleanup() }
        try NoFollowWriter(root: alone.dataRoot).prepare(folders: [])
        let elsewhere = alone.home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let behind = elsewhere.appendingPathComponent("pool-a.json")
        try Data("{}".utf8).write(to: behind)
        try FileManager.default.createSymbolicLink(
            at: alone.dataRoot.appendingPathComponent(TokenPaths.folderName),
            withDestinationURL: elsewhere)
        let out = try alone.run(["uninstall"], stdin: "uninstall\n")
        #expect(out.status == 1)
        #expect(
            output(out.stderr).contains(
                Messages.uninstallFolderIsALink(
                    "The token folder", "~/.agent-balancer/" + TokenPaths.folderName)))
        #expect(!output(out.stdout).contains("Nothing to remove"))
        #expect(FileManager.default.fileExists(atPath: behind.path))

        // A full home whose launch folder was moved and linked back: nothing goes.
        let full = try setUp(token: Canary.realShapeToken())
        defer { full.cleanup() }
        _ = try full.run(["run", "--print-command", "pool-a"])
        let context = ToolContext(home: full.home, ambient: [:])
        let root = LaunchFiles.rootURL(context: context)
        let moved = full.home.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        let refused = try full.run(["uninstall"], stdin: "uninstall\n")
        #expect(refused.status == 1)
        #expect(
            output(refused.stderr).contains(
                Messages.uninstallFolderIsALink(
                    "The launch folder", "~/.agent-balancer/" + LaunchFiles.folder)))
        let token = try TokenPaths.fileURL(context: context, label: "pool-a")
        #expect(FileManager.default.fileExists(atPath: token.path))
        #expect(!full.read("config.json").isEmpty)
    }

    @Test func uninstallSaysWhenAnEntryInOtherLetterCaseMayHoldATokenAndExits1() throws {
        let cli = try CLIHome(installFake: false)
        defer { cli.cleanup() }
        // A token file's name in other letter case, which a token save may have written into.
        try NoFollowWriter(root: cli.dataRoot).put(
            Data("{}".utf8), folders: TokenPaths.folders, name: "Pool-a.json")
        let entry = cli.dataRoot.appendingPathComponent(TokenPaths.folderName)
            .appendingPathComponent("Pool-a.json")
        let said =
            "\n1 entries in the token or launch folder are named like the tool's own in other letter case and may hold a token. They are left unopened, and the closing text says what to do.\n"
        let listing = try cli.run(["uninstall"], stdin: "no\n")
        #expect(listing.status == 1)
        #expect(!output(listing.stdout).contains("Nothing to remove"))
        #expect(output(listing.stdout).contains(said))
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        // An entry that may still hold a token means the removal is not done.
        #expect(done.status == 1, "\(output(done.stderr))")
        #expect(!output(done.stderr).contains("Error"))
        #expect(output(done.stdout).contains(TokenAccounts.otherCaseEntriesText(1)))
        #expect(
            output(done.stdout).contains(
                "1 entries in `~/.agent-balancer/" + TokenPaths.folderName
                    + "/` or the launch folder have the name of a token file or a launch folder in other letter case"
            ))
        #expect(FileManager.default.fileExists(atPath: entry.path))
        let again = try cli.run(["uninstall"], stdin: "no\n")
        #expect(output(again.stdout).contains(said))
    }

    @Test func uninstallFinishesAndExits1WhenALabelsLaunchFolderIsALink() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        _ = try cli.run(["run", "--print-command", "pool-a"])
        let launch = try #require(launchFiles(cli).first)
        let context = ToolContext(home: cli.home, ambient: [:])
        // The label's folder moved elsewhere and linked back; its launch file holds the token.
        let label = LaunchFiles.rootURL(context: context).appendingPathComponent("pool-a")
        let moved = cli.home.appendingPathComponent("moved-label")
        try FileManager.default.moveItem(at: label, to: moved)
        try FileManager.default.createSymbolicLink(at: label, withDestinationURL: moved)
        let behind = moved.appendingPathComponent(launch.lastPathComponent)
        let said =
            "\n1 entries in the launch folder where a label's folder belongs are a link, a file or another user's folder, and a launch file with a token may be behind them. They are not followed, and the closing text says what to do.\n"
        let listing = try cli.run(["uninstall"], stdin: "no\n")
        #expect(output(listing.stdout).contains(said))
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 1, "\(output(done.stderr))")
        #expect(!output(done.stderr).contains("Error"))
        #expect(output(done.stdout).contains(LaunchFiles.notFollowedEntriesText(1)))
        // Every other step ran; the link and what is behind it stay as they were.
        let token = try TokenPaths.fileURL(context: context, label: "pool-a")
        #expect(!FileManager.default.fileExists(atPath: token.path))
        #expect(cli.read("config.json").isEmpty)
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: label.path)) == moved.path)
        #expect(FileManager.default.fileExists(atPath: behind.path))
        #expect(!output(done.stdout).contains(secret))
    }

    @Test func uninstallRefusesAFolderItCannotSearchInsteadOfNothingToRemove() throws {
        // Only a token file, in a token folder that opens for reading but cannot be searched.
        let alone = try CLIHome(installFake: false)
        defer { alone.cleanup() }
        try NoFollowWriter(root: alone.dataRoot).put(
            Data("{}".utf8), folders: TokenPaths.folders, name: "pool-a.json")
        let tokens = alone.dataRoot.appendingPathComponent(TokenPaths.folderName)
        chmod(tokens.path, 0o600)
        defer { chmod(tokens.path, 0o700) }
        let out = try alone.run(["uninstall"], stdin: "uninstall\n")
        chmod(tokens.path, 0o700)
        #expect(out.status == 1)
        #expect(
            output(out.stderr).contains(
                "The token folder `~/.agent-balancer/" + TokenPaths.folderName
                    + "` cannot be opened or searched, so `uninstall` cannot check what the tool made in it."
            ))
        #expect(!output(out.stdout).contains("Nothing to remove"))
        #expect(
            FileManager.default.fileExists(
                atPath: tokens.appendingPathComponent("pool-a.json").path))

        // A full home: the data folder, the launch folder or a label's folder in it at 0600 is
        // refused by its own name, before anything goes.
        let full = try setUp(token: Canary.realShapeToken())
        defer { full.cleanup() }
        _ = try full.run(["run", "--print-command", "pool-a"])
        let context = ToolContext(home: full.home, ambient: [:])
        let launch = LaunchFiles.rootURL(context: context)
        let token = try TokenPaths.fileURL(context: context, label: "pool-a")
        let label = launch.appendingPathComponent("pool-a")
        let launchPlace = "~/.agent-balancer/" + LaunchFiles.folder
        let places: [(folder: URL, subject: String, place: String)] = [
            (full.dataRoot, "The data folder", "~/.agent-balancer"),
            (launch, "The launch folder", launchPlace),
            (label, "The launch folder", launchPlace + "/pool-a"),
        ]
        for item in places {
            chmod(item.folder.path, 0o600)
            defer { chmod(item.folder.path, 0o700) }
            let refused = try full.run(["uninstall"], stdin: "uninstall\n")
            chmod(item.folder.path, 0o700)
            #expect(refused.status == 1, "\(item.place)")
            let said = Messages.uninstallFolderRefused(item.subject, item.place, .cannotOpen)
            #expect(output(refused.stderr).contains(said), "\(item.place)")
            #expect(!output(refused.stdout).contains("a label's folder belongs"), "\(item.place)")
            #expect(FileManager.default.fileExists(atPath: token.path), "\(item.place)")
            #expect(!full.read("config.json").isEmpty, "\(item.place)")
            #expect(launchFiles(full).count == 1, "\(item.place)")
        }
    }

    @Test func uninstallListsAStateTemporaryASaveMayStillUseAndSaysWhenARunDeletesIt() throws {
        let cli = try CLIHome(installFake: false)
        defer { cli.cleanup() }
        // Only the temporary file of a save that may still be running, dated ahead of the clock so
        // that no slow run can age it past the minute.
        try NoFollowWriter(root: cli.dataRoot).put(
            Data("{}".utf8), folders: Layout.stateFolders, name: ".tmp-00000000000000aa")
        let temporary = cli.dataRoot.appendingPathComponent("state/.tmp-00000000000000aa")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(600)], ofItemAtPath: temporary.path)
        let listing = try cli.run(["uninstall"], stdin: "no\n")
        #expect(!output(listing.stdout).contains("Nothing to remove"))
        #expect(
            output(listing.stdout).contains(
                "\n1 temporary files in `~/.agent-balancer/state/` are younger than a minute or dated ahead of the clock, so a save may still be using them. They stay until a run finds them a minute old, and the closing text says what to do.\n"
            ))
        let done = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(done.status == 0, "\(output(done.stderr))")
        #expect(
            output(done.stdout).contains(
                "Kept 1 temporary files in `~/.agent-balancer/state/` that a save may still be using. Quit the menu bar app, then run `agent-balancer uninstall` again in a minute to delete them. One dated ahead of the clock goes only on a run a minute or more after that date."
            ))
        #expect(!output(done.stdout).contains("entries alone"))
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        // Once it is a minute old, a run deletes it, and the data folder with it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: temporary.path)
        let later = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(later.status == 0, "\(output(later.stderr))")
        #expect(!output(later.stdout).contains("Kept 1 temporary files"))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: cli.dataRoot.path))
    }

    // MARK: run

    @Test func runDropsItsLaunchFileAndLeaseWhenClaudeCannotStart() throws {
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        // It passes the runner's checks, but its interpreter does not exist, so it never starts.
        try "#!/nonexistent/interpreter\n".write(
            to: cli.fakePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: cli.fakePath.path)
        let out = try cli.run(["run", "pool-a"])
        #expect(out.status == 1)
        #expect(output(out.stderr).contains("Could not start claude."))
        #expect(launchFiles(cli).isEmpty)
        let context = ToolContext(home: cli.home, ambient: [:])
        #expect(TokenAccounts.openLeaseCount(context: context, leaseMinutes: 30) == 0)
        // The lease was taken and logged before the start failed.
        #expect(cli.read("state/picks.log").contains("pool-a"))
        #expect(!output(out.stdout).contains(secret) && !output(out.stderr).contains(secret))
    }

    @Test func runRefusesASettingsLinkThatGoesNowhereWithTheTextThatNamesTheFix() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let url = cli.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: cli.home.appendingPathComponent("gone.json"))
        _ = try cli.run(["doctor"])
        for args in [["run", "main"], ["run", "--print-command", "main"]] {
            let out = try cli.run(args)
            #expect(out.status == 1, "\(args)")
            #expect(output(out.stderr).contains(Messages.settingsLinkGoesNowhere), "\(args)")
            #expect(launchFiles(cli).isEmpty)
        }
        #expect(!cli.fakeRecord("args.log").contains("--settings"))
    }

    // MARK: The sign-in identity

    @Test func aSignInThatReportsNoEmailFailsTheLoginAccountEverywhere() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fake(
            "auth.json",
            #"{"loggedIn":true,"authMethod":"claude.ai","email":null,"planTier":"max_20x","subscriptionType":"max"}"#
        )
        let doctor = try cli.run(["doctor"])
        #expect(doctor.status == 1)
        #expect(
            output(doctor.stdout).contains("Error check_failed: \(Messages.signInEmailMissing)"))
        let run = try cli.run(["run", "main"])
        #expect(run.status == 1)
        #expect(output(run.stderr).contains(Messages.signInEmailMissing))
        #expect(launchFiles(cli).isEmpty)
        // The expected email back in the report clears it.
        try cli.fakeFixture("logged_in")
        #expect(!output(try cli.run(["doctor"]).stdout).contains(Messages.signInEmailMissing))
    }
}

import Core
import Foundation
import Testing

@testable import Core

private func said(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// A write that stops and cannot delete its temporary file, which may hold a token: `pick`, `run`
/// and `login` print an error that names the file by its path and the commands that let the tool
/// delete it, `doctor` names each such file the upkeep cannot delete and exits 1, and `refresh`
/// says that it left one. Once the named commands run as written, `refresh` deletes the file.
extension PersonCommandsCLITests {
    /// What a write adds about its temporary file `name` in the folder `place` that it could not
    /// delete and that may hold the token of 'pool-a'.
    static func temporaryKept(_ place: String, _ name: String) -> String {
        "Its temporary file `\(place)/\(name)` could not be deleted and may hold the token of 'pool-a'. Run `chflags -h nouchg,nouappnd` first on `\(place)` and on that file if either is locked. Then run `chmod -h -N \(place)` and `chmod -h 700 \(place)`, and on that file `chmod -h -N`, or `chmod -N` if that says Permission denied. Then run `agent-balancer refresh`, which deletes it."
    }

    /// What `doctor` says about the temporary file `name` in the folder `place` that the upkeep
    /// cannot delete.
    static func temporaryStuck(_ place: String, _ name: String) -> String {
        "1 temporary file the writer left in `\(place)` may hold a token, and `agent-balancer refresh` cannot delete it: `\(place)/\(name)`. Run `chflags -h nouchg,nouappnd` first on `\(place)` and on that file if either is locked. Then run `chmod -h -N \(place)` and `chmod -h 700 \(place)`, and on that file `chmod -h -N`, or `chmod -N` if that says Permission denied. Then run `agent-balancer refresh`, which deletes it."
    }

    static var tokenPlace: String { "~/.agent-balancer/" + TokenPaths.folderName }

    /// The token folder of the test home.
    func tokenFolder(_ cli: CLIHome) -> URL {
        cli.dataRoot.appendingPathComponent(TokenPaths.folderName)
    }

    /// Keeps `folder` from losing an entry: an append-only flag, or an access list entry that
    /// denies you `delete_child`.
    func keepEntries(in folder: URL, _ cause: String) throws {
        if cause == "append-only" {
            #expect(try runNamedCapturing(["chflags", "uappnd", folder.path]).status == 0)
        } else {
            try denyOwnerOf(folder, "delete_child")
        }
    }

    /// Clears what `keepEntries` set, and any flag a test left on what is in `folder`.
    func letEntriesGo(in folder: URL) {
        for entry in [folder] + entries(in: folder) {
            _ = try? runNamedCapturing(["chflags", "-h", "nouchg,nouappnd", entry.path])
        }
        _ = try? runChmod(["-N", folder.path])
    }

    /// The lease file name `pick` or `run` could not write, from its error.
    func leaseFileName(_ shown: String) -> String? {
        guard let range = shown.range(of: #"l-[0-9a-f]{8}\.json"#, options: .regularExpression)
        else { return nil }
        return String(shown[range])
    }

    // MARK: pick and run

    @Test func aPickOrRunWhoseWriteStopsNamesTheTemporaryFileItCouldNotDelete() throws {
        let place = Self.poolAPlace
        let pick = ["pick", "--caller", "launcher", "--exclude", "main"]
        for cause in ["append-only", "delete_child"] {
            for command in [pick, ["run", "pool-a"]] {
                let name = "\(command[0]) \(cause)"
                let secret = Canary.realShapeToken()
                let cli = try setUp(token: secret)
                defer { cli.cleanup() }
                try cli.fakeProbe("ok.jsonl")
                #expect(try cli.run(["run", "--print-command", "pool-a"]).status == 0, "\(name)")
                let folder = launchRoot(cli).appendingPathComponent("pool-a")
                defer { letEntriesGo(in: folder) }
                let before = Set(entries(in: folder))
                try keepEntries(in: folder, cause)

                let stopped = try cli.run(command)
                #expect(stopped.status == 1, "\(name)")
                let left = try #require(newEntry(in: folder, besides: before), "\(name)")
                #expect(NoFollowWriter.isTemporaryName(left.lastPathComponent), "\(name)")
                #expect(filesHolding(folder, secret) == 2, "\(name)")
                let shown = said(stopped.stderr)
                let lease = try #require(leaseFileName(shown), "\(name)")
                #expect(
                    shown
                        == "Error: Could not write \(lease). "
                        + Self.temporaryKept(place, left.lastPathComponent) + "\n", "\(name)")
                if command[0] == "run" {
                    #expect(!cli.fakeRecord("args.log").contains("--settings"), "\(name)")
                }

                // As written: the flag first, the folder's commands, then the file's.
                #expect(
                    try followNamedFiles(shown, "may hold the token of", cli) == 0, "\(name)")
                let refresh = try cli.run(["refresh"])
                #expect(refresh.status == 0, "\(name)")
                #expect(!said(refresh.stdout).contains("temporary file"), "\(name)")
                #expect(!FileManager.default.fileExists(atPath: left.path), "\(name)")
            }
        }
    }

    @Test func aPickWhoseLaunchFolderPassesOnAnEntryThatDeniesReadattrAndDeleteNamesItsTemporary()
        throws
    {
        let place = Self.poolAPlace
        let secret = Canary.realShapeToken()
        let cli = try setUp(token: secret)
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        try cli.fakeProbe("ok.jsonl")
        #expect(try cli.run(["run", "--print-command", "pool-a"]).status == 0)
        let folder = launchRoot(cli).appendingPathComponent("pool-a")
        let before = Set(entries(in: folder))
        // Each file written in the folder from now on takes the entry.
        try denyOwnerOf(folder, "readattr,delete,file_inherit,only_inherit")

        let stopped = try cli.run(["pick", "--caller", "launcher", "--exclude", "main"])
        #expect(stopped.status == 1)
        let left = try #require(newEntry(in: folder, besides: before))
        #expect(NoFollowWriter.isTemporaryName(left.lastPathComponent))
        #expect(!isCheckable(left))
        let shown = said(stopped.stderr)
        let lease = try #require(leaseFileName(shown))
        #expect(
            shown
                == "Error: Could not write \(lease). "
                + Self.temporaryKept(place, left.lastPathComponent) + "\n")

        #expect(try followNamedFiles(shown, "may hold the token of", cli) == 0)
        #expect(isCheckable(left))
        #expect(filesHolding(folder, secret) == 2)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(!FileManager.default.fileExists(atPath: left.path))
    }

    // MARK: login

    @Test func aLoginWhoseTokenFolderKeepsItsEntriesDuringTheSignInNamesTheTemporaryFile() throws {
        let place = Self.tokenPlace
        for cause in ["append-only", "delete_child"] {
            let old = Canary.realShapeToken()
            let cli = try setUp(token: old)
            defer { cli.cleanup() }
            let folder = tokenFolder(cli)
            defer { letEntriesGo(in: folder) }
            try cli.fakeProbe("ok.jsonl")
            let before = Set(entries(in: folder))
            let fresh = Canary.realShapeToken()
            try cli.fake("setup-token.out", "Your token is \(fresh)\n")
            // The flag or the entry comes while the person approves, after the checks passed.
            let hook =
                cause == "append-only"
                ? "/usr/bin/chflags uappnd '\(folder.path)'"
                : "/bin/chmod +a '\(NSUserName()) deny delete_child' '\(folder.path)'"
            try cli.fake("during-setup-token.sh", hook + "\n")

            let out = try cli.run(["login", "pool-a"])
            #expect(out.status == 1, "\(cause)")
            let left = try #require(newEntry(in: folder, besides: before), "\(cause)")
            #expect(NoFollowWriter.isTemporaryName(left.lastPathComponent), "\(cause)")
            #expect(filesHolding(folder, fresh) == 1, "\(cause)")
            let shown = said(out.stderr)
            #expect(
                shown
                    == "Error: Could not write pool-a.json. "
                    + Self.temporaryKept(place, left.lastPathComponent)
                    + " The new token for 'pool-a' was not saved. Once the above is fixed, run `agent-balancer login pool-a` again.\n",
                "\(cause)")

            #expect(try followNamedFiles(shown, "may hold the token of", cli) == 0, "\(cause)")
            try FileManager.default.removeItem(
                at: cli.home.appendingPathComponent(".ab-fake/during-setup-token.sh"))
            #expect(try cli.run(["refresh"]).status == 0, "\(cause)")
            #expect(!FileManager.default.fileExists(atPath: left.path), "\(cause)")
            // The token file keeps the old token: the save stopped before its rename.
            #expect(filesHolding(folder, old) == 1, "\(cause)")
        }
    }

    // MARK: doctor and refresh

    @Test func doctorNamesATemporaryTheUpkeepCannotDeleteAndRefreshSaysItLeftOne() throws {
        for inTokenFolder in [false, true] {
            let name = inTokenFolder ? "token folder" : "launch folder"
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            try cli.fakeProbe("ok.jsonl")
            #expect(try cli.run(["run", "--print-command", "pool-a"]).status == 0, "\(name)")
            let temporary = try leftTemporary(
                cli, inTokenFolder: inTokenFolder, name: ".tmp-0123456789abcdef")
            let folder = temporary.deletingLastPathComponent()
            defer { letEntriesGo(in: folder) }
            let place = inTokenFolder ? Self.tokenPlace : Self.poolAPlace
            #expect(try runNamedCapturing(["chflags", "uappnd", folder.path]).status == 0)

            let doctor = try cli.run(["doctor"])
            #expect(doctor.status == 1, "\(name)")
            let lines = said(doctor.stdout)
            let stuck = "Error: " + Self.temporaryStuck(place, temporary.lastPathComponent)
            #expect(lines.contains("\n" + stuck + "\n"), "\(name)")
            #expect(!lines.contains("temporary files from a write"), "\(name)")

            let refresh = try cli.run(["refresh"])
            #expect(refresh.status == 0, "\(name)")
            #expect(
                said(refresh.stdout).contains(
                    "\nWarning: " + Self.temporaryLeft(place, temporary.lastPathComponent)
                        + "\n"), "\(name)")
            #expect(FileManager.default.fileExists(atPath: temporary.path), "\(name)")

            // As written: the flag first, the folder's commands, then the file's.
            #expect(try followNamedFiles(lines, "cannot delete it", cli) == 0, "\(name)")
            let again = try cli.run(["refresh"])
            #expect(again.status == 0, "\(name)")
            #expect(!said(again.stdout).contains("temporary file"), "\(name)")
            #expect(!FileManager.default.fileExists(atPath: temporary.path), "\(name)")
            let after = try cli.run(["doctor"])
            #expect(after.status == 0, "\(name): \(said(after.stdout))")
        }
    }

    @Test func aRefreshWhoseUpkeepCannotRunSaysWhyAndNamesEachTemporaryThatMayHoldAToken() throws {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        try cli.fakeProbe("ok.jsonl")
        #expect(try cli.run(["run", "--print-command", "pool-a"]).status == 0)
        let temporary = try leftTemporary(
            cli, inTokenFolder: true, name: ".tmp-0123456789abcdef")
        let place = Self.tokenPlace
        let notRun =
            "\nWarning: The launch file upkeep did not run, so this refresh deleted no launch file or temporary file: "
        let kept =
            "\nWarning: 1 temporary file the writer left in `\(place)` may hold a token: `\(place)/\(temporary.lastPathComponent)`. `agent-balancer refresh` deletes it once its upkeep runs.\n"

        // A lease file that does not decode: the fix `pick` names for it.
        let leases = cli.dataRoot.appendingPathComponent("state/leases.json")
        #expect(FileManager.default.fileExists(atPath: leases.path))
        try Data("not json".utf8).write(to: leases)
        let unreadable = try cli.run(["refresh"])
        #expect(unreadable.status == 0)
        #expect(
            said(unreadable.stdout).contains(
                notRun
                    + "state/leases.json cannot be read, so the open picks are unknown. Fix or remove it, then try again."
                    + kept))
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        try Data(#"{"schemaVersion":1,"leases":[]}"#.utf8).write(to: leases)

        // Another command holds the pick lock past the wait.
        let lock = try #require(
            try NoFollowWriter(root: cli.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 0))
        let busy = try cli.run(["refresh"])
        lock.release()
        #expect(busy.status == 0)
        #expect(
            said(busy.stdout).contains(
                notRun
                    + "another command held the pick lock. Run `agent-balancer refresh` again once it ends."
                    + kept))
        #expect(FileManager.default.fileExists(atPath: temporary.path))

        // Once the upkeep runs, it deletes the file and says nothing of it.
        let again = try cli.run(["refresh"])
        #expect(again.status == 0)
        #expect(!said(again.stdout).contains("upkeep did not run"))
        #expect(!said(again.stdout).contains("temporary file"))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }
}

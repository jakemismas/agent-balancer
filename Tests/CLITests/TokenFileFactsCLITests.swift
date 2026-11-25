import Core
import Foundation
import Testing

@testable import Core

private func said(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// A token file the tool cannot check may hold a token: a token folder you cannot search is named
/// by `status`, `pick` and `run` with its fix instead of "No token saved", and a token file that
/// `lstat` cannot check at the save is reported as replaced, with the launch file and old token
/// lines and the `token_replaced` event. `doctor` counts the launch files of a launch folder it
/// refuses or cannot list.
extension PersonCommandsCLITests {
    /// What `status`, `pick` and `run` say about the token file of 'pool-a' while you cannot
    /// search the token folder.
    static var tokenFolderUnsearchable: String {
        let place = tokenPlace
        return
            "The token file of 'pool-a' cannot be checked: the token folder `\(place)` cannot be searched. Run `chflags nouchg,nouappnd \(place)` if it is locked, `chmod -N \(place)`, then `chmod 700 \(place)` in Terminal."
    }

    /// The `token_replaced` events of 'pool-a'.
    func poolAReplacedEvents(_ cli: CLIHome) throws -> [[String: Any]] {
        let out = try cli.run(["events", "--json", "--type", "token_replaced", "--label", "pool-a"])
        let document = try #require(
            JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
        return try #require(document["events"] as? [[String: Any]])
    }

    @Test func aTokenFolderYouCannotSearchIsNamedByStatusPickAndRunInsteadOfNoTokenSaved()
        throws
    {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        try cli.fakeProbe("ok.jsonl")
        let folder = tokenFolder(cli)
        try denyOwnerOf(folder, "search")
        let text = Self.tokenFolderUnsearchable

        let status = try cli.run(["status", "--json"])
        let document = try #require(
            JSONSerialization.jsonObject(with: status.stdout) as? [String: Any])
        let rows = try #require(document["accounts"] as? [[String: Any]])
        let row = try #require(rows.first { $0["label"] as? String == "pool-a" })
        let error = try #require(row["error"] as? [String: Any])
        #expect(error["code"] as? String == "token_missing")
        #expect(error["text"] as? String == text)
        let table = said(try cli.run(["status", "--cached"]).stdout)
        #expect(table.contains("  error token_missing: " + text + "\n"))
        #expect(!table.contains("No token saved"))

        let pick = try cli.run(["pick", "--caller", "launcher", "--exclude", "main"])
        #expect(pick.status == 2)
        #expect(said(pick.stdout).contains("\n  pool-a: skipped, " + text + "\n"))

        let run = try cli.run(["run", "pool-a"])
        #expect(run.status == 1)
        #expect(said(run.stderr) == "Error: " + text + "\n")

        // As written: the flag step, and once the list goes, the token is used again.
        #expect(try runNamedCapturing(["chflags", "nouchg,nouappnd", folder.path]).status == 0)
        #expect(try runChmod(["-N", folder.path]) == 0)
        #expect(try runChmod(["700", folder.path]) == 0)
        #expect(try cli.run(["run", "--print-command", "pool-a"]).status == 0)
    }

    @Test func aTokenFileLoginCannotCheckAtTheSaveIsReportedAsReplaced() throws {
        let old = Canary.realShapeToken()
        let cli = try setUp(token: old)
        defer { cli.cleanup() }
        defer { clearAccessLists(cli) }
        try cli.fakeProbe("ok.jsonl")
        #expect(try cli.run(["run", "--print-command", "pool-a"]).status == 0)
        let file = try TokenPaths.fileURL(
            context: ToolContext(home: cli.home, ambient: [:]), label: "pool-a")
        let fresh = Canary.realShapeToken()
        try cli.fake("setup-token.out", "Your token is \(fresh)\n")
        // The entry comes while the person approves, after the checks passed.
        try cli.fake(
            "during-setup-token.sh",
            "/bin/chmod +a '\(NSUserName()) deny readattr' '\(file.path)'\n")

        let out = try cli.run(["login", "pool-a"])
        #expect(out.status == 0, "\(said(out.stderr))")
        #expect(
            said(out.stdout).contains(
                "Saved the token for 'pool-a'.\nRewrote 1 launch files with the new token. The old token may keep working until its year ends, because no way to cancel one is documented.\n"
            ))
        #expect(launchFilesHolding(cli, fresh) == 1 && launchFilesHolding(cli, old) == 0)
        // The save replaced the file it could not check.
        #expect(isCheckable(file))
        #expect(filesHolding(file.deletingLastPathComponent(), fresh) == 1)
        let replaced = try poolAReplacedEvents(cli)
        #expect(replaced.count == 1)
    }

    @Test func doctorCountsTheLaunchFilesOfALaunchFolderItRefusesOrCannotList() throws {
        let place = "~/.agent-balancer/" + LaunchFiles.folder
        let cases = [
            (
                "list",
                "launch files: 1, 1 cannot be checked, and the launch folder `\(place)` cannot be checked or listed, so a launch file in it counts only when a session record names it"
            ),
            (
                "mode",
                "launch files: 2, 2 cannot be checked, and the launch folder `\(place)` cannot be checked, so each launch file in it counts as one that cannot be checked"
            ),
        ]
        for (cause, line) in cases {
            let cli = try setUp(token: Canary.realShapeToken())
            defer { cli.cleanup() }
            let root = launchRoot(cli)
            defer {
                chmod(root.path, 0o700)
                _ = try? runChmod(["-N", root.path])
            }
            for _ in 0..<2 {
                #expect(try cli.run(["run", "--print-command", "pool-a"]).status == 0, "\(cause)")
            }
            let named = try #require(launchFiles(cli).first, "\(cause)")
            #expect(launchFiles(cli).count == 2, "\(cause)")
            // A session record names one of the two.
            try nameLaunchFile(named, session: "s-root", in: cli)
            if cause == "list" {
                try denyOwnerOf(root, "list")
            } else {
                chmod(root.path, 0o755)
            }

            let doctor = try cli.run(["doctor"])
            #expect(doctor.status == 1, "\(cause)")
            #expect(said(doctor.stdout).contains("\n" + line + "\n"), "\(cause)")
        }
    }
}

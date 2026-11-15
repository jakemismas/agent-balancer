import Core
import Foundation
import Testing

@testable import Core

/// A probe's `login_rejected` stands until a probe works or `login` completes a new sign-in. A
/// check that sees only the old sign-in, or a probe that fails for another reason, leaves it, so
/// the window never reads "Signed in" in between, and `login <label> --browser` signs the folder
/// in again instead of refusing it. `pick` still offers such a folder while `verify` passes.
extension FolderAccountsCLITests {
    @Test @MainActor func aProbesRejectionStandsUntilLoginSignsTheFolderInAgain() async throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        var row = try statusRow(cli)
        #expect(row["planTier"] as? String == "max_20x")

        // The probe finds the sign-in rejected while `auth status` still lists it.
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        row = try statusRow(cli)
        #expect((row["error"] as? [String: Any])?["code"] as? String == "login_rejected")
        #expect(row["planTier"] is NSNull)

        // A check of the old sign-in leaves the rejection standing.
        #expect(try cli.run(["status", "--json"]).status == 0)
        row = try statusRow(cli)
        #expect((row["error"] as? [String: Any])?["code"] as? String == "login_rejected")
        #expect(row["planTier"] is NSNull && row["signInCheck"] as? String == "signed_in")
        let vm = window(cli)
        let panel = try #require(vm.panel)
        #expect(panel.signInText.hasPrefix("Signed out") && !panel.signedIn)
        #expect(panel.signIn?.title == "Sign in again..." && panel.signIn?.enabled == true)
        #expect(!cli.fakeRecord("args.log").contains("auth login"))

        // The window's Sign in signs the folder in again, and that new sign-in ends the
        // rejection.
        await vm.signIn("spare")
        let bar = try #require(vm.bar)
        #expect(bar.ok && bar.text == "Signed in. The folder holds the expected account.")
        #expect(cli.fakeRecord("args.log").contains("auth login --email \(Self.email)"))
        row = try statusRow(cli)
        #expect(row["error"] is NSNull)
        #expect(row["planTier"] as? String == "max_20x")
        vm.selection = "spare"
        #expect(vm.panel?.signInText == "Signed in" && vm.panel?.signedIn == true)
    }

    @Test func aSignInThatFailsToFinishLeavesTheProbesRejectionStanding() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)

        // Run from Terminal without --browser: a clean exit does not show a new sign-in.
        let said = "Error login_rejected: " + Messages.signInNotRenewed("spare")
        let interactive = try cli.run(["login", "spare"])
        #expect(interactive.status == 1)
        #expect(String(decoding: interactive.stdout, as: UTF8.self).contains(said))
        #expect(
            (try statusRow(cli)["error"] as? [String: Any])?["code"] as? String == "login_rejected")

        // `claude auth login` that fails leaves it too.
        try cli.fake("auth-login.exit", "1")
        let browser = try cli.run(["login", "spare", "--browser"])
        #expect(browser.status == 1)
        #expect(String(decoding: browser.stdout, as: UTF8.self).contains(said))
        let row = try statusRow(cli)
        #expect((row["error"] as? [String: Any])?["code"] as? String == "login_rejected")
        #expect(row["planTier"] is NSNull)
        #expect(cli.fakeRecord("args.log").contains("auth login"))
    }

    @Test func aSignInFromTerminalOfAFolderThatReadsSignedOutEndsTheProbesRejection() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        #expect(
            (try statusRow(cli)["error"] as? [String: Any])?["code"] as? String == "login_rejected")

        // `auth status` now reads the folder signed out, and the interactive run signs it in.
        try cli.fake("auth.json", try authJSON(cli, loggedIn: false))
        try cli.fake("auth-after-sign-in.json", try authJSON(cli, loggedIn: true))
        let out = try cli.run(["login", "spare"])
        #expect(out.status == 0)
        #expect(String(decoding: out.stdout, as: UTF8.self).contains("Signed in."))
        let row = try statusRow(cli)
        #expect(row["error"] is NSNull)
        #expect(row["planTier"] as? String == "max_20x")
    }

    @Test @MainActor func aFoldersProbeRejectionStandsOverFailedProbesUntilLoginSignsItInAgain()
        throws
    {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        #expect(errorCode(try statusRow(cli)) == "login_rejected")

        // Each plain refresh probes it again, and here each probe finds no usage event.
        try cli.fakeProbe("no_event.jsonl")
        var probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 1)
        #expect(probeRuns(cli) == probes + 1)
        #expect(errorCode(try statusRow(cli)) == "login_rejected")
        probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 1)
        #expect(probeRuns(cli) == probes + 1)
        #expect(errorCode(try statusRow(cli)) == "login_rejected")

        // The window offers Sign in again, and `login --browser` signs the folder in again.
        let vm = window(cli)
        let panel = try #require(vm.panel)
        #expect(panel.signInText.hasPrefix("Signed out") && !panel.signedIn)
        #expect(panel.signIn?.title == "Sign in again..." && panel.signIn?.enabled == true)
        #expect(!cli.fakeRecord("args.log").contains("auth login"))
        #expect(try cli.run(["login", "spare", "--browser"]).status == 0)
        #expect(cli.fakeRecord("args.log").contains("auth login --email \(Self.email)"))
        #expect(try statusRow(cli)["error"] is NSNull)
    }

    @Test func aLoginAccountsProbeRejectionStandsUntilAProbeWorks() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try ageFreshReading(cli, "main")
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "main", "--force"]).status == 1)
        #expect(errorCode(try row(cli, "main")) == "login_rejected")

        // `login` refuses a login account, so only a probe that works can end the rejection.
        try cli.fakeProbe("no_event.jsonl")
        var probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 1)
        #expect(probeRuns(cli) == probes + 1)
        #expect(errorCode(try row(cli, "main")) == "login_rejected")
        try cli.fakeProbe("ok.jsonl")
        probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes + 1)
        #expect(try row(cli, "main")["error"] is NSNull)
    }

    @Test func pickStillOffersAFolderWhoseProbesRejectionStandsWhileVerifyPasses() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        #expect(errorCode(try statusRow(cli)) == "login_rejected")
        // A folder account is judged at pick time by `verify`, which still passes.
        let probes = probeRuns(cli)
        let answer = try json(try cli.run(["pick", "--json", "--exclude", "main"]))
        #expect(answer["label"] as? String == "spare")
        #expect(probeRuns(cli) == probes)
    }
}

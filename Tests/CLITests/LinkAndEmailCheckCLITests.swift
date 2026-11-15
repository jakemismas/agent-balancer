import Core
import Foundation
import Testing

@testable import Core

/// `link <label>` and `config set <label> email <new>` record a sign-in check of the account
/// they act on, as `status` does, so the window reads what the folder holds before it offers
/// Sign in.
extension FolderAccountsCLITests {
    @Test @MainActor func aFolderAddedAgainOverItsSignedInFolderReadsSignedInRightAfterLink()
        throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        #expect(try cli.run(["remove", "spare"]).status == 0)
        let added = try cli.run(["add", "spare", "--kind", "folder", "--email", Self.email])
        #expect(added.status == 0)
        var row = try statusRow(cli)
        #expect(row["planTier"] is NSNull && row["signInCheck"] is NSNull)
        let before = cli.fakeRecord("args.log")

        // The kept folder still holds the expected account's sign-in.
        try linked(cli)
        let checked = cli.fakeRecord("args.log").dropFirst(before.count)
        #expect(checked.contains("auth status --json"))
        #expect(cli.fakeRecord("config-dir.txt") == (try folderPath(cli)) + "\n")
        row = try statusRow(cli)
        #expect(row["linked"] as? Bool == true)
        #expect(row["planTier"] as? String == "max_20x")
        #expect(row["signInCheck"] as? String == "signed_in")
        let vm = window(cli)
        let panel = try #require(vm.panel)
        #expect(panel.signInText == "Signed in" && panel.signedIn)
        // No Sign in that `login spare --browser` would refuse as already signed in.
        #expect(panel.signIn == nil)
        var draft = AddDraft()
        draft.label = "spare"
        draft.kind = Kind.folder
        draft.stage = .added
        let step = try #require(vm.addSteps(draft).first { $0.id == 3 })
        #expect(step.state == .done && !step.actionEnabled)
    }

    @Test @MainActor func aNewEmailIsCheckedRightAwayForAFolderAndALoginAccount() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        #expect(try cli.run(["status", "--json"]).status == 0)

        // The folder now holds the account of the new email: the check `config set` makes
        // places it, so the window reads it as signed in with no Sign in.
        try cli.fake("auth.json", try authJSON(cli, loggedIn: true, email: "new@example.com"))
        let before = cli.fakeRecord("args.log")
        let out = try cli.run(["config", "set", "spare", "email", "new@example.com"])
        #expect(out.status == 0)
        #expect(cli.fakeRecord("args.log").dropFirst(before.count).contains("auth status --json"))
        var row = try statusRow(cli)
        #expect(row["planTier"] as? String == "max_20x")
        #expect(row["signInCheck"] as? String == "signed_in")
        let vm = window(cli)
        #expect(vm.panel?.signInText == "Signed in" && vm.panel?.signIn == nil)

        // The folder holds the old account: the check of the new email finds another account.
        try cli.fake("auth.json", try authJSON(cli, loggedIn: true))
        #expect(try cli.run(["config", "set", "spare", "email", "third@example.com"]).status == 0)
        row = try statusRow(cli)
        #expect(row["planTier"] is NSNull)
        #expect(row["signInCheck"] as? String == "other_account")
        vm.statusMayHaveChanged()
        vm.selection = "spare"
        #expect(vm.panel?.signInText == "Signed in as another account")
        #expect(vm.panel?.signIn == nil)

        // A login account's new email is checked the same way.
        try cli.fake("auth.json", #"{"loggedIn":true,"email":"me@example.com","planTier":"pro"}"#)
        #expect(try cli.run(["config", "set", "main", "email", "me@example.com"]).status == 0)
        let main = try self.row(cli, "main")
        #expect(main["planTier"] as? String == "pro")
    }
}

import Core
import Foundation
import Testing

@testable import Core

/// A sign-in check counts only for the email it was made for. Once a folder or login account's
/// email changes, by `config set`, by a hand edit of `config.json`, or by `remove` and `add` of
/// the same label, its row keeps no plan tier, expiry or `signed_in` from a check of the old
/// email, and the window shows no green "Signed in" and no finished Add step 3.
extension FolderAccountsCLITests {
    /// A home whose folder account `spare` a check has placed: the row holds the tier and
    /// `signed_in`.
    func placedFolder() throws -> CLIHome {
        let cli = try setUp()
        try linked(cli)
        #expect(try cli.run(["status", "--json"]).status == 0)
        let row = try statusRow(cli)
        #expect(row["planTier"] as? String == "max_20x")
        #expect(row["signInCheck"] as? String == "signed_in")
        return cli
    }

    /// The window over `spare` now: no green "Signed in" in the list or the panel, and Add step 3
    /// not done.
    @MainActor func expectNotSignedInWindow(_ cli: CLIHome, _ place: String) throws {
        let vm = window(cli)
        let panel = try #require(vm.panel, "\(place)")
        #expect(panel.signInText != "Signed in" && !panel.signedIn, "\(place)")
        let list = try #require(vm.rows.first { $0.label == "spare" }, "\(place)")
        #expect(!list.signedIn && !list.subtitle.hasPrefix("Signed in"), "\(place)")
        var draft = AddDraft()
        draft.label = "spare"
        draft.kind = Kind.folder
        draft.stage = .added
        let step = try #require(vm.addSteps(draft).first { $0.id == 3 }, "\(place)")
        #expect(step.state == .todo, "\(place)")
    }

    /// Rewrites `config.json` as a person would in an editor: no command runs.
    func editConfigByHand(_ cli: CLIHome, _ old: String, _ new: String) throws {
        let text = cli.read("config.json")
        #expect(text.contains(old))
        try NoFollowWriter(root: cli.dataRoot).put(
            Data(text.replacingOccurrences(of: old, with: new).utf8), folders: [],
            name: ConfigStore.fileName)
    }

    @Test @MainActor func aFolderEmailChangedByConfigSetDropsTheCheckOfTheOldEmail() throws {
        let cli = try placedFolder()
        defer { cli.cleanup() }
        // The check `config set` makes of the new email reads no status, so only the binding can
        // take the old check's `signed_in` away.
        try cli.fake("auth.json", "not a status")
        let out = try cli.run(["config", "set", "spare", "email", "new@example.com"])
        #expect(out.status == 0)
        let row = try statusRow(cli)
        #expect(row["planTier"] is NSNull)
        #expect(row["signInCheck"] is NSNull)
        try expectNotSignedInWindow(cli, "config set")
    }

    @Test @MainActor func aFolderEmailChangedByHandDropsTheCheckOfTheOldEmail() throws {
        let cli = try placedFolder()
        defer { cli.cleanup() }
        try editConfigByHand(cli, "\"\(Self.email)\"", "\"new@example.com\"")
        // The writer sees the change at its next rebuild, which runs no check.
        #expect(try cli.run(["status", "--json", "--cached"]).status == 0)
        var row = try statusRow(cli)
        #expect(row["planTier"] is NSNull)
        #expect(row["signInCheck"] is NSNull)
        try expectNotSignedInWindow(cli, "hand edit")
        #expect(!cli.read("state/current.json").contains("new@example.com"))

        // A check of the new email that finds it in the folder places it again.
        try cli.fake("auth.json", try authJSON(cli, loggedIn: true, email: "new@example.com"))
        #expect(try cli.run(["status", "--json"]).status == 0)
        row = try statusRow(cli)
        #expect(row["planTier"] as? String == "max_20x")
        #expect(row["signInCheck"] as? String == "signed_in")
    }

    @Test @MainActor func aFolderRemovedAndAddedAgainWithAnotherEmailKeepsNoOldCheck() throws {
        let cli = try placedFolder()
        defer { cli.cleanup() }
        let before = try statusRow(cli)["accountKey"] as? String
        #expect(try cli.run(["remove", "spare"]).status == 0)
        let added = try cli.run(["add", "spare", "--kind", "folder", "--email", "new@example.com"])
        #expect(added.status == 0)
        let row = try statusRow(cli)
        #expect(row["accountKey"] as? String != before)
        #expect(row["planTier"] is NSNull)
        #expect(row["signInCheck"] is NSNull)
        try expectNotSignedInWindow(cli, "remove and add")
    }

    @Test func aLoginAccountsTierAndExpiryFollowItsEmail() throws {
        let cli = try setUp(folder: false)
        defer { cli.cleanup() }
        let main = #"{"loggedIn":true,"email":"main@example.com","planTier":"max_20x","#
        try cli.fake("auth.json", main + #""loginExpiresAt":"2099-01-01T00:00:00Z"}"#)
        try cli.fake("auth.exit", "0")
        #expect(try cli.run(["status", "--json"]).status == 0)
        var row = try self.row(cli, "main")
        #expect(row["planTier"] as? String == "max_20x")
        #expect(row["loginExpiresAt"] as? String == "2099-01-01T00:00:00Z")

        // A check of the new email that reads no status: the old check's expiry goes with it.
        try cli.fake("auth.json", "not a status")
        #expect(try cli.run(["config", "set", "main", "email", "new@example.com"]).status == 0)
        row = try self.row(cli, "main")
        #expect(row["planTier"] is NSNull)
        #expect(row["loginExpiresAt"] is NSNull)

        // Placed again for the new email, then changed by hand: nothing of that check stays.
        try cli.fake(
            "auth.json",
            #"{"loggedIn":true,"email":"new@example.com","planTier":"max_20x","#
                + #""loginExpiresAt":"2099-01-01T00:00:00Z"}"#)
        #expect(try cli.run(["status", "--json"]).status == 0)
        #expect(try self.row(cli, "main")["planTier"] as? String == "max_20x")
        try editConfigByHand(cli, "\"new@example.com\"", "\"other@example.com\"")
        row = try self.row(cli, "main")
        #expect(row["planTier"] is NSNull)
        #expect(row["loginExpiresAt"] is NSNull)
    }

    @Test func aSignInWhileTheEmailChangesRecordsNoPlanForTheNewEmail() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let store = ConfigStore(context: context(cli))
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "spare" })
        config.accounts[index].expectedPlanTier = nil
        try store.save(config)
        try cli.fake("auth.json", try authJSON(cli, loggedIn: false))
        try cli.fake("auth-after-sign-in.json", try authJSON(cli, loggedIn: true))
        // While claude runs, the email changes, as `config set` in another terminal would do.
        let staged = cli.home.appendingPathComponent(".ab-fake/config-after-edit.json")
        let text = cli.read("config.json")
        #expect(text.contains(Self.email))
        try text.replacingOccurrences(of: Self.email, with: "new@example.com")
            .write(to: staged, atomically: true, encoding: .utf8)
        let target = cli.dataRoot.appendingPathComponent(ConfigStore.fileName)
        try cli.fake("during-sign-in.sh", "cp '\(staged.path)' '\(target.path)'\n")

        let out = try cli.run(["login", "spare"])
        #expect(out.status == 0)
        // The check placed the old email, so the account on the new one keeps no recorded plan.
        let after = try #require(try store.loadRequired().account("spare"))
        #expect(after.email == "new@example.com")
        #expect(after.expectedPlanTier == nil)
    }
}

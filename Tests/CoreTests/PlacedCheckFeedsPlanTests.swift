import Foundation
import Testing

@testable import Core

/// Only a check that placed the expected account's sign-in in its own folder feeds the account's
/// plan and expiry, and a `signInCheck` of the wrong type in `status.json` reads as no check
/// while the rest of the status loads.
@Suite struct PlacedCheckFeedsPlanTests {
    /// A folder account that ends soon and is expected on `max_20x`, after one sign-in check that
    /// saw `email` on `pro`, in its own folder when `dir` is nil: the row and the entry it left.
    func afterOneCheck(email: String?, in dir: String?) throws -> (
        row: AccountStatus, entry: CurrentEntry
    ) {
        let folders = FolderAccountsTests()
        let (t, context) = try folders.setUp { $0.accounts[0].endingSoon = true }
        defer { withExtendedLifetime(t) {} }
        _ = try folders.link(context)
        let account = try #require(
            try ConfigStore(context: context).loadRequired().account("spare"))
        let folder = try FolderPaths.configDir(context: context, label: "spare")
        let status = AuthStatus(
            loggedIn: true, email: email, planTier: "pro",
            loginExpiresAt: Date().addingTimeInterval(3 * 86_400),
            configDirectory: dir ?? folder.path)
        let check = AuthObservation(
            FolderKind.evaluate(status, account: account, folder: folder, now: Date()))
        let document = try StatusBuilder.rebuild(
            context: context, observations: StatusObservations(auth: ["spare": check]))
        let row = try #require(document?.accounts.first { $0.label == "spare" })
        let data = try #require(
            try NoFollowReader(root: context.dataRoot).read(
                folders: Layout.stateFolders, name: "current.json"))
        let entry = try #require(
            try EventLog.decoder().decode(CurrentFile.self, from: data).accounts["spare"])
        return (row, entry)
    }

    @Test func onlyAPlacedCheckFeedsThePlanDropAndTheExpiry() throws {
        // Placed: the plan dropped on an account marked ending soon, so it has ended, and the
        // check's expiry shows.
        let placed = try afterOneCheck(email: "acct@example.com", in: nil)
        #expect(placed.row.state == "ended" && placed.entry.endedByPlan)
        #expect(placed.row.loginExpiresAt != nil && placed.entry.loginExpiresAt != nil)
        // Signed in in another folder, as another account, or with no email reported.
        let unplaced: [(String?, String?)] = [
            ("acct@example.com", "/elsewhere/.claude"), ("other@example.com", nil), (nil, nil),
        ]
        for (email, dir) in unplaced {
            let name = "\(email ?? "no email") in \(dir ?? "its own folder")"
            let got = try afterOneCheck(email: email, in: dir)
            #expect(got.row.state == "error" && !got.entry.endedByPlan, "\(name)")
            #expect(got.row.loginExpiresAt == nil && got.entry.loginExpiresAt == nil, "\(name)")
            #expect(got.row.planTier == nil, "\(name)")
        }
    }

    static let wrongTypeJson = """
        { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
          "accounts": [
            { "label": "fol-num", "email": "fol-num@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "linked": true, "state": "error", "planTier": "max_20x",
              "signInCheck": 5,
              "error": { "code": "settings_changed", "text": "Settings changed." } },
            { "label": "fol-obj", "email": "fol-obj@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "linked": true, "state": "ok", "planTier": "max_20x",
              "signInCheck": { "seen": "signed_in" } },
            { "label": "tok-ok", "email": "tok-ok@example.com", "role": "pool", "kind": "token",
              "state": "ok", "weekly": { "usedPercent": 12.0, "resetsAt": null, "source": "probe" } }
          ] }
        """

    @Test @MainActor func aSignInCheckOfAnotherTypeReadsAsNoCheckAndTheRestLoads() throws {
        guard case .loaded(let snapshot) = StatusSnapshot.parse(Data(Self.wrongTypeJson.utf8))
        else {
            Issue.record("the status did not load")
            return
        }
        #expect(snapshot.accounts.map(\.label) == ["fol-num", "fol-obj", "tok-ok"])
        for row in snapshot.accounts.prefix(2) {
            #expect(row.signInCheck == nil && !row.hasSignInCheck, "\(row.label)")
        }
        // Read as strictly as a row with no key: a code that can hide a doubt is no sign-in.
        #expect(ManageBuilder.signInState(snapshot.accounts[0]) == .notConfirmed)

        // The menu shows every row.
        let screen = MenuBuilder.screen(
            MenuInputs(
                configExists: true, cliFound: true, cliTried: [], status: .loaded(snapshot),
                now: ManageViewModelTests.now, backgroundMinutes: 60))
        guard case .accounts(let shown) = screen else {
            Issue.record("the menu shows no rows")
            return
        }
        #expect(shown.rows.map(\.label) == ["fol-num", "fol-obj", "tok-ok"])

        // So does the window.
        let fake = try ManageViewModelTests.Fake(statusJson: Self.wrongTypeJson)
        let vm = ManageViewModel(
            context: fake.context, runner: fake.runner, clock: { ManageViewModelTests.now })
        #expect(vm.accounts.map(\.label) == ["fol-num", "fol-obj", "tok-ok"])
        #expect(vm.notice == nil)
    }
}

import Foundation
import Testing

@testable import Core

/// A sign-in check counts only for the email it was made for, through the real status writer,
/// and `state/current.json` names that email only by a digest.
@Suite struct EmailBoundCheckTests {
    /// A linked folder account `spare` and a placed check of it, made for the account as it is.
    func home() throws -> (TestHome, ToolContext, AuthObservation) {
        let folders = FolderAccountsTests()
        let (t, context) = try folders.setUp()
        _ = try folders.link(context)
        let account = try #require(
            try ConfigStore(context: context).loadRequired().account("spare"))
        let folder = try FolderPaths.configDir(context: context, label: "spare")
        let status = AuthStatus(
            loggedIn: true, email: account.email, planTier: "max_20x",
            loginExpiresAt: Date().addingTimeInterval(30 * 86_400), configDirectory: folder.path)
        let check = AuthObservation(
            FolderKind.evaluate(status, account: account, folder: folder, now: Date()))
        return (t, context, check)
    }

    func row(_ context: ToolContext, _ observations: StatusObservations = StatusObservations())
        throws -> AccountStatus
    {
        let document = try StatusBuilder.rebuild(context: context, observations: observations)
        return try #require(document?.accounts.first { $0.label == "spare" })
    }

    func setEmail(_ context: ToolContext, _ email: String?) throws {
        let store = ConfigStore(context: context)
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "spare" })
        config.accounts[index].email = email
        try store.save(config)
    }

    func current(_ context: ToolContext) throws -> String {
        let data = try #require(
            try NoFollowReader(root: context.dataRoot).read(
                folders: Layout.stateFolders, name: "current.json"))
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aCheckMadeBeforeTheEmailChangedPlacesNothingForTheNewOne() throws {
        let (t, context, check) = try home()
        defer { withExtendedLifetime(t) {} }
        // The email changes while the check runs, so the rebuild folds in a check of the old one.
        try setEmail(context, "new@example.com")
        let got = try row(context, StatusObservations(auth: ["spare": check]))
        #expect(got.planTier == nil && got.signInCheck == nil && got.loginExpiresAt == nil)
        #expect(!(try current(context)).contains("new@example.com"))
    }

    @Test func theCurrentFileNamesTheEmailOnlyByItsDigest() throws {
        let (t, context, check) = try home()
        defer { withExtendedLifetime(t) {} }
        let got = try row(context, StatusObservations(auth: ["spare": check]))
        #expect(got.planTier == "max_20x" && got.signInCheck == "signed_in")
        let text = try current(context)
        #expect(!text.contains("acct@example.com") && !text.contains("example.com"))
        let file = try EventLog.decoder().decode(CurrentFile.self, from: Data(text.utf8))
        let digest = try #require(file.accounts["spare"]?.emailDigest)
        #expect(CurrentFile.isDigest(digest))
        let account = try #require(
            try ConfigStore(context: context).loadRequired().account("spare"))
        #expect(digest == account.emailDigest)
    }

    @Test func onlySixtyFourLowercaseHexDigitsReadAsADigest() {
        let hex = String(repeating: "0123456789abcdef", count: 4)
        let table: [(String, String, Bool)] = [
            ("64 lowercase hex digits", hex, true),
            ("63 digits", String(hex.dropLast()), false),
            ("65 digits", hex + "a", false),
            ("upper case", hex.uppercased(), false),
            ("a character that is not hex", String(hex.dropLast()) + "g", false),
        ]
        for (name, text, isDigest) in table {
            #expect(CurrentFile.isDigest(text) == isDigest, "\(name)")
        }
    }

    @Test func aChangeOfCaseOnlyKeepsTheCheckAndAnyOtherChangeDropsIt() throws {
        let (t, context, check) = try home()
        defer { withExtendedLifetime(t) {} }
        #expect(try row(context, StatusObservations(auth: ["spare": check])).planTier != nil)
        // The check compares emails without case, so the same address in capitals is the same.
        try setEmail(context, "ACCT@example.com")
        #expect(try row(context).signInCheck == "signed_in")
        try setEmail(context, nil)
        var got = try row(context)
        #expect(got.planTier == nil && got.signInCheck == nil)
        // Back to the first email: the check that was dropped does not come back.
        try setEmail(context, "acct@example.com")
        got = try row(context)
        #expect(got.planTier == nil && got.signInCheck == nil)
    }

    @Test func anEntryWithNoDigestFromAnEarlierWriterKeepsNoCheck() throws {
        let (t, context, check) = try home()
        defer { withExtendedLifetime(t) {} }
        _ = try row(context, StatusObservations(auth: ["spare": check]))
        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(try current(context).utf8))
                as? [String: Any])
        var accounts = try #require(root["accounts"] as? [String: Any])
        var entry = try #require(accounts["spare"] as? [String: Any])
        entry.removeValue(forKey: "emailDigest")
        accounts["spare"] = entry
        root["accounts"] = accounts
        try NoFollowWriter(root: context.dataRoot).put(
            try JSONSerialization.data(withJSONObject: root), folders: Layout.stateFolders,
            name: "current.json")
        let got = try row(context)
        #expect(got.planTier == nil && got.signInCheck == nil)
    }

    /// A linked folder account `spare` that ends soon and is expected on `max_20x`, and a placed
    /// check of it on `pro`, made for its email as it is.
    func endingSoonHome() throws -> (TestHome, ToolContext, AuthObservation) {
        let folders = FolderAccountsTests()
        let (t, context) = try folders.setUp { $0.accounts[0].endingSoon = true }
        _ = try folders.link(context)
        let account = try #require(
            try ConfigStore(context: context).loadRequired().account("spare"))
        let folder = try FolderPaths.configDir(context: context, label: "spare")
        let status = AuthStatus(
            loggedIn: true, email: account.email, planTier: "pro", loginExpiresAt: nil,
            configDirectory: folder.path)
        let check = AuthObservation(
            FolderKind.evaluate(status, account: account, folder: folder, now: Date()))
        return (t, context, check)
    }

    func entry(_ context: ToolContext) throws -> CurrentEntry {
        let file = try EventLog.decoder().decode(
            CurrentFile.self, from: Data(try current(context).utf8))
        return try #require(file.accounts["spare"])
    }

    @Test func aCheckOfTheOldEmailNeverEndsAnAccountByItsPlan() throws {
        // Folded in for the email it was made for, the plan drop ends the account.
        let (kept, keptContext, keptCheck) = try endingSoonHome()
        defer { withExtendedLifetime(kept) {} }
        let ended = try row(keptContext, StatusObservations(auth: ["spare": keptCheck]))
        #expect(ended.state == "ended")
        #expect(try entry(keptContext).endedByPlan)

        // Folded in after the email changed, it ends nothing.
        let (t, context, check) = try endingSoonHome()
        defer { withExtendedLifetime(t) {} }
        try setEmail(context, "new@example.com")
        let got = try row(context, StatusObservations(auth: ["spare": check]))
        #expect(got.state != "ended")
        #expect(try !entry(context).endedByPlan)
    }

    @Test func aNewSignInOfTheOldEmailLeavesTheProbesRejectionStanding() throws {
        let rejected = ProbeObservation(error: Issue(.loginRejected, .error, "Login rejected."))
        for emailChanges in [false, true] {
            let (t, context, check) = try home()
            defer { withExtendedLifetime(t) {} }
            let before = try row(context, StatusObservations(probe: ["spare": rejected]))
            #expect(before.error?.code == "login_rejected")
            // `login` completed a new sign-in of the folder, checked for the email it had then.
            var signedIn = check
            signedIn.newSignIn = true
            if emailChanges { try setEmail(context, "new@example.com") }
            let got = try row(context, StatusObservations(auth: ["spare": signedIn]))
            if emailChanges {
                #expect(got.error?.code == "login_rejected")
                #expect(try entry(context).probeError?.code == "login_rejected")
            } else {
                #expect(got.error == nil)
            }
        }
    }
}

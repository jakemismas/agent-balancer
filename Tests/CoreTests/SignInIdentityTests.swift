import Foundation
import Testing

@testable import Core

/// The sign-in identity check: a stored claude.ai sign-in reports its email in `auth status
/// --json`, so an account with an expected email fails on a different email and on none at all.
@Suite struct SignInIdentityTests {
    func login(email: String? = "main@example.com") -> Account {
        Account(
            label: "main", kind: Kind.login, role: Role.pool, email: email,
            expectedPlanTier: "max_20x")
    }

    func status(_ email: String?) -> AuthStatus {
        AuthStatus(loggedIn: true, email: email, planTier: "max_20x")
    }

    @Test func aSignInThatReportsNoEmailFailsAnAccountThatExpectsOne() {
        let check = LoginKind.evaluate(status(nil), account: login(), now: Date())
        #expect(check.issues.map(\.code) == [.checkFailed])
        #expect(check.issues.map(\.text) == [Messages.signInEmailMissing])
        #expect(check.hasError)
        #expect(
            LoginKind.evaluate(status("MAIN@example.com"), account: login(), now: Date())
                .issues.isEmpty)
        #expect(
            LoginKind.evaluate(status("other@example.com"), account: login(), now: Date())
                .issues.map(\.code) == [.wrongAccount])
        // With no recorded email the account fails closed, and the plan tier still marks a change.
        let unset = login(email: nil)
        #expect(
            LoginKind.evaluate(status(nil), account: unset, now: Date()).issues.map(\.text)
                == [Messages.emailNotRecorded])
        #expect(
            LoginKind.evaluate(
                AuthStatus(loggedIn: true, planTier: "max_5x"), account: unset, now: Date()
            ).issues.map(\.code) == [.checkFailed, .planChanged])
    }

    @Test func theShapeTheInstalledClientPrintsWithANullEmailFailsTheCheck() throws {
        // The fields `claude auth status --json` prints for a stored claude.ai sign-in, with the
        // account fields the client sets to null when it has no account record.
        let text = """
            {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",\
            "analyticsDisabled":false,"projectsDirectory":null,"configDirectory":"/home/example/.claude",\
            "loginExpiresAt":null,"email":null,"orgId":null,"orgName":null,\
            "subscriptionType":"max","storedClaudeAiLogin":true,"planTier":"max_20x"}
            """
        let parsed = try #require(AuthStatusReader.parse(text))
        #expect(parsed.email == nil && parsed.planTier == "max_20x")
        #expect(
            LoginKind.evaluate(parsed, account: login(), now: Date()).issues.map(\.code)
                == [.checkFailed])
        let named = text.replacingOccurrences(
            of: #""email":null"#, with: #""email":"main@example.com""#)
        let good = try #require(AuthStatusReader.parse(named))
        #expect(LoginKind.evaluate(good, account: login(), now: Date()).issues.isEmpty)
    }

    @Test func aFolderSignInThatReportsNoEmailFailsTooAndKeepsItsFolderCheck() {
        let folder = URL(fileURLWithPath: "/h/.agent-balancer/accounts/spare/.claude")
        let account = Account(
            label: "spare", kind: Kind.folder, role: Role.pool, email: "acct@example.com",
            expectedPlanTier: "max_20x")
        let none = AuthStatus(loggedIn: true, planTier: "max_20x", configDirectory: folder.path)
        let check = FolderKind.evaluate(none, account: account, folder: folder, now: Date())
        #expect(check.issues.map(\.code) == [.checkFailed])
        #expect(check.issues.map(\.text) == [Messages.signInEmailMissing])
        let other = AuthStatus(
            loggedIn: true, email: "acct@example.com", planTier: "max_20x",
            configDirectory: "/h/.agent-balancer/accounts/other/.claude")
        #expect(
            FolderKind.evaluate(other, account: account, folder: folder, now: Date()).issues
                .map(\.code) == [.checkFailed])
    }
}

import Foundation
import Testing

@testable import Core

@Suite struct AuthStatusReaderTests {
    func fixture(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/auth/\(name).json"), encoding: .utf8)
    }

    let account = Account(
        label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
        expectedPlanTier: "max_20x")

    @Test func mapsEveryField() throws {
        let status = try #require(AuthStatusReader.parse(try fixture("logged_in")))
        #expect(status.loggedIn)
        #expect(status.email == "main@example.com")
        #expect(status.planTier == "max_20x")
        #expect(status.subscriptionType == "max")
        #expect(status.loginExpiresAt != nil)
        #expect(status.configDirectory == "/home/example/.claude")
    }

    @Test func fixturesKeepOnlyMappedFields() throws {
        let mapped: Set<String> = [
            "loggedIn", "email", "planTier", "subscriptionType", "loginExpiresAt",
            "configDirectory",
        ]
        for name in ["logged_in", "logged_out", "wrong_account", "plan_changed"] {
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(try fixture(name).utf8))
                    as? [String: Any])
            #expect(Set(object.keys).isSubset(of: mapped), "\(name)")
        }
    }

    @Test func notJSONGivesNil() {
        #expect(AuthStatusReader.parse("not json") == nil)
        #expect(AuthStatusReader.parse("[1,2]") == nil)
        #expect(AuthStatusReader.parse("{\"email\":\"a@example.com\"}") == nil)
    }

    @Test func parsesEpochMilliseconds() {
        let status = AuthStatusReader.parse("{\"loggedIn\":true,\"loginExpiresAt\":4102444800000}")
        #expect(status?.loginExpiresAt == Date(timeIntervalSince1970: 4_102_444_800))
    }

    func read(_ t: TestHome) -> AuthReadResult { AuthStatusReader.read(runner: t.runner) }

    @Test func loggedInReads() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        guard case .status(let s) = read(t) else {
            Issue.record("expected status")
            return
        }
        #expect(s.loggedIn && s.planTier == "max_20x")
        let check = LoginKind.evaluate(s, account: account, now: Date())
        #expect(check.issues.isEmpty && check.signedIn)
    }

    @Test func exitOneWithJSONIsLoggedOutNotCheckFailed() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_out", exit: 1)
        guard case .status(let s) = read(t) else {
            Issue.record("expected status")
            return
        }
        #expect(!s.loggedIn)
        let check = LoginKind.evaluate(s, account: account, now: Date())
        #expect(check.issues.map(\.code) == [.loginRejected])
    }

    @Test func wrongAccountAndPlanChanged() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "wrong_account")
        guard case .status(let a) = read(t) else {
            Issue.record("expected status")
            return
        }
        #expect(
            LoginKind.evaluate(a, account: account, now: Date()).issues.map(\.code) == [
                .wrongAccount
            ])
        try t.fakeFixture(auth: "plan_changed")
        guard case .status(let b) = read(t) else {
            Issue.record("expected status")
            return
        }
        let issues = LoginKind.evaluate(b, account: account, now: Date()).issues
        #expect(issues.map(\.code) == [.planChanged])
        #expect(issues.first?.text == "Plan is max_5x, expected max_20x.")
    }

    @Test func loginExpiringWithinSevenDays() {
        let now = Date()
        let soon = AuthStatus(
            loggedIn: true, email: "main@example.com", planTier: "max_20x",
            loginExpiresAt: now.addingTimeInterval(6 * 86_400))
        let later = AuthStatus(
            loggedIn: true, email: "main@example.com", planTier: "max_20x",
            loginExpiresAt: now.addingTimeInterval(9 * 86_400))
        let a = LoginKind.evaluate(soon, account: account, now: now)
        #expect(a.issues.map(\.code) == [.loginExpiring])
        #expect(a.issues.first?.severity == .warning)
        #expect(LoginKind.evaluate(later, account: account, now: now).issues.isEmpty)
    }

    @Test func timeoutIsCheckFailed() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        try t.fake("delay", "10")
        guard case .failed(let issue) = AuthStatusReader.read(runner: t.runner, timeout: 1) else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .checkFailed)
    }

    @Test func missingBinaryIsCheckFailed() throws {
        let t = try TestHome()
        let runner = ClaudeRunner(context: t.context, candidates: [t.fakePath])
        guard case .failed(let issue) = AuthStatusReader.read(runner: runner) else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .checkFailed)
    }

    @Test func nonJSONOutputIsCheckFailed() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fake("auth.json", "Welcome to the thing\n")
        guard case .failed(let issue) = read(t) else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .checkFailed)
    }

    @Test func extraFieldsAreDropped() throws {
        let canary = Canaries.oauth()
        let status = AuthStatusReader.parse(
            "{\"loggedIn\":true,\"orgName\":\"\(canary)\",\"extra\":\"\(canary)\"}")
        #expect(!String(describing: status).contains(canary))
    }
}

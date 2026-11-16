import Core
import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// The command a `login_rejected` text names records a sign-in check, so running it once the
/// account is signed in again clears the error, and docs/CONTRACT.md names the same commands.
extension FolderAccountsCLITests {
    /// The arguments of the last `agent-balancer` command a text names in backticks.
    func namedCommand(_ text: String) -> [String] {
        let quoted = text.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        guard let command = quoted.last(where: { $0.hasPrefix("agent-balancer ") }) else {
            return []
        }
        return command.split(separator: " ").dropFirst().map(String.init)
    }

    func errorText(_ row: [String: Any]) -> String? {
        (row["error"] as? [String: Any])?["text"] as? String
    }

    /// Signs the login account `main` in the default folder in or out; `spare` stays as it is.
    func stageMain(_ cli: CLIHome, loggedIn: Bool) throws {
        try cli.fake(
            "auth-default.json",
            #"{"loggedIn":\#(loggedIn),"email":"main@example.com","planTier":"max_20x"}"#)
    }

    /// The row of `label` in a plain `status --json`, which runs its own sign-in check.
    func checkedRow(_ cli: CLIHome, _ label: String) throws -> [String: Any] {
        let out = try cli.run(["status", "--json"])
        #expect(out.status == 0)
        let accounts = try #require(try json(out)["accounts"] as? [[String: Any]])
        return try #require(accounts.first { $0["label"] as? String == label })
    }

    /// Collapses the line breaks and indents of a wrapped Markdown paragraph to single spaces.
    func prose(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func theCommandALoginAccountsCheckRejectionNamesClearsItOnceItIsSignedBackIn() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try stageMain(cli, loggedIn: false)
        #expect(try cli.run(["status", "--json"]).status == 0)
        let rejected = try row(cli, "main")
        #expect(errorCode(rejected) == "login_rejected")
        let command = namedCommand(try #require(errorText(rejected)))
        #expect(command == ["refresh"])

        try stageMain(cli, loggedIn: true)
        #expect(try cli.run(command).status == 0)
        let trail = try eventTrail(try eventsJSON(cli), "main")
        #expect(Array(trail.suffix(2)) == [["error", "login_rejected"], ["recovered", nil]])
        #expect(try row(cli, "main")["error"] is NSNull)
        #expect(try checkedRow(cli, "main")["error"] is NSNull)
    }

    @Test func theCommandALoginAccountsRejectionBeforeAProbeNamesClearsItOnceItIsSignedBackIn()
        throws
    {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try ageFreshReading(cli, "main")
        try stageMain(cli, loggedIn: false)
        // The check before the probe finds the sign-in gone, so the probe records the rejection.
        #expect(try cli.run(["refresh", "--label", "main", "--force"]).status == 1)
        let rejected = try row(cli, "main")
        #expect(errorCode(rejected) == "login_rejected")
        let command = namedCommand(try #require(errorText(rejected)))
        #expect(command == ["refresh"])

        try stageMain(cli, loggedIn: true)
        // A sign-in check alone leaves a probe's rejection standing; the named command probes.
        #expect(errorCode(try checkedRow(cli, "main")) == "login_rejected")
        #expect(try cli.run(command).status == 0)
        let trail = try eventTrail(try eventsJSON(cli), "main")
        #expect(Array(trail.suffix(2)) == [["error", "login_rejected"], ["recovered", nil]])
        #expect(try row(cli, "main")["error"] is NSNull)
        #expect(try checkedRow(cli, "main")["error"] is NSNull)
    }

    @Test func theCommandAFolderAccountsCheckRejectionNamesSignsItInAndClearsIt() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try signedIn(cli, loggedIn: false)
        #expect(try cli.run(["status", "--json"]).status == 0)
        let rejected = try row(cli, "spare")
        #expect(errorCode(rejected) == "login_rejected")
        let command = namedCommand(try #require(errorText(rejected)))
        #expect(command == ["login", "spare"])

        try cli.fake("auth-after-sign-in.json", try authJSON(cli, loggedIn: true))
        #expect(try cli.run(command).status == 0)
        let trail = try eventTrail(try eventsJSON(cli), "spare")
        #expect(Array(trail.suffix(2)) == [["error", "login_rejected"], ["recovered", nil]])
        #expect(try row(cli, "spare")["error"] is NSNull)
        #expect(try checkedRow(cli, "spare")["error"] is NSNull)
    }

    @Test func loginRefusesALoginAccountWithATextThatNamesRefresh() throws {
        let cli = try setUp(folder: false)
        defer { cli.cleanup() }
        let out = try cli.run(["login", "main"])
        #expect(out.status == 1)
        let said = text(out.stderr)
        #expect(
            said.contains(
                "'main' is not a token or folder account. Sign in to it with `claude`, then run `agent-balancer refresh`."
            ))
        #expect(namedCommand(said) == ["refresh"])
    }

    @Test func theSignInTextsNameTheCommandsTheContractSaysRecordACheck() throws {
        let signedOut = AuthStatus(loggedIn: false)
        let login = LoginKind.evaluate(
            signedOut,
            account: Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com"),
            now: Date())
        let folder = FolderKind.evaluate(
            signedOut,
            account: Account(label: "spare", kind: Kind.folder, role: Role.pool, email: Self.email),
            folder: URL(fileURLWithPath: "/nonexistent/spare/.claude"), now: Date())
        let loginText = try #require(login.issues.first)
        let folderText = try #require(folder.issues.first)
        #expect(loginText.code == .loginRejected && folderText.code == .loginRejected)
        #expect(
            loginText.text
                == "Login rejected. Run `claude` and sign in again, then run `agent-balancer refresh`."
        )
        #expect(namedCommand(loginText.text) == ["refresh"])
        #expect(namedCommand(folderText.text) == ["login", "spare"])
        #expect(namedCommand(Messages.probeLoginRejected) == ["refresh"])

        let contract = prose(
            try String(
                contentsOf: Support.root.appendingPathComponent("docs/CONTRACT.md"),
                encoding: .utf8))
        for phrase in [
            "These commands record a check:",
            "`refresh` (for each `login` and `folder` account whose reading did not fail, every time it runs)",
            "`login` for a folder account",
            "When a row's `login_rejected` error names an `agent-balancer` command, it is one of these, to run once the account is signed in again: `refresh`, or `login <label>` for a `folder` account, which signs the folder in itself.",
            "`doctor` shows each sign-in but records no check.",
        ] {
            #expect(contract.contains(phrase), "\(phrase)")
        }
    }
}

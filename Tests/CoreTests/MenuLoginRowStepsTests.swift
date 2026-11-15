import Foundation
import Testing

@testable import Core

/// A login account is the default folder's own sign-in: its menu row shows no folder step, no
/// "Open Manage accounts" fix action and no `agent-balancer login <label>` step, which refuses a
/// login account. A folder row with the same codes keeps them.
@Suite struct MenuLoginRowStepsTests {
    static func row(kind: String, code: String) throws -> ErrorModel {
        let json = """
            { "schemaVersion": 1, "accounts": [ { "label": "main", "role": "main",
              "kind": "\(kind)", "state": "error", "error": { "code": "\(code)", "text": "Text." } } ] }
            """
        guard case .loaded(let snapshot) = StatusSnapshot.parse(Data(json.utf8)) else {
            throw LoginRowError(text: "\(kind) \(code) did not load")
        }
        guard case .error(let model) = MenuBuilder.row(snapshot.accounts[0], staleAfter: 3600).body
        else { throw LoginRowError(text: "\(kind) \(code) is not an error row") }
        return model
    }

    struct LoginRowError: Error { var text: String }

    @Test func aLoginRowShowsOnlyStepsThatApplyToALoginAccount() throws {
        let rejected = try Self.row(kind: Kind.login, code: "login_rejected")
        #expect(!rejected.manageable)
        #expect(rejected.steps.command == nil)
        #expect(!rejected.steps.steps.joined(separator: " ").contains("agent-balancer login"))
        #expect(rejected.steps.steps.contains("Run claude and sign in again."))

        let wrong = try Self.row(kind: Kind.login, code: "wrong_account")
        #expect(!wrong.steps.steps.contains(Messages.signExpectedBackIn))
        #expect(!wrong.steps.steps.joined(separator: " ").contains("relabel"))
        #expect(wrong.steps.steps.first == Messages.signExpectedBackInLogin)

        // A folder row keeps the fix action, the login command and its folder step.
        let folder = try Self.row(kind: Kind.folder, code: "login_rejected")
        #expect(folder.manageable && folder.steps.command == "agent-balancer login main")
        let folderWrong = try Self.row(kind: Kind.folder, code: "wrong_account")
        #expect(folderWrong.steps.steps.first == Messages.signExpectedBackIn)
    }
}

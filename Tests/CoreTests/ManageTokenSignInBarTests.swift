import Foundation
import Testing

@testable import Core

/// What the bar shows after a token account's `login` in run mode: how the command ended, never
/// the opening line it prints first.
extension ManageViewModelTests {
    @Test @MainActor func aTokenSignInBarShowsHowTheCommandEndedNotItsOpeningLine() async throws {
        let fake = try Fake()
        let opening = "Opening the browser. Approve the sign-in there. The token is not shown."
        let cases: [(body: String, ok: Bool, bar: String)] = [
            (
                """
                echo "\(opening)"
                echo "Saved the token for 'tok-out'."
                echo "First check: read (5 hour 1.0%, week 2.0%)"
                exit 0
                """, true,
                "Saved the token for 'tok-out'. First check: read (5 hour 1.0%, week 2.0%)"
            ),
            (
                """
                echo "\(opening)"
                echo "Saved the token for 'tok-out'."
                echo "First check failed. Error login_rejected: Login rejected."
                exit 1
                """, false,
                "Saved the token for 'tok-out'. First check failed. Error login_rejected: Login rejected."
            ),
            (
                """
                echo "\(opening)"
                echo "Error: Could not start claude." >&2
                exit 1
                """, false, "Error: Could not start claude."
            ),
        ]
        for (body, ok, bar) in cases {
            let tool = try Self.tool(body)
            defer { try? FileManager.default.removeItem(at: tool.home) }
            let vm = ManageViewModel(
                context: fake.context,
                runner: CLIRunner(context: fake.context, candidates: [tool.exe]),
                settings: ManageSettings(tokenSignIn: .run), clock: { Self.now })
            #expect(await vm.run(.login(label: "tok-out")) == ok, "\(bar)")
            let shown = try #require(vm.bar)
            #expect(shown.command == "agent-balancer login tok-out")
            #expect(shown.ok == ok && shown.text == bar, "\(shown.text)")
            #expect(!shown.text.contains("Opening the browser"))
        }
    }
}

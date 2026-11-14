import Foundation
import Testing

@testable import Core

/// What the bar shows for `login <label> --browser`: the tool's own error line, read from
/// standard output before standard error, and nothing the run printed once it timed out.
extension ManageViewModelTests {
    @Test @MainActor func aRefusedBrowserSignInShowsTheErrorLineOnStandardOutputFirst()
        async throws
    {
        let fake = try Fake()
        // The tool prints its advice and then its own error line on standard output; the
        // sign-in it runs shares the streams and left another error line on standard error.
        let both = try Self.tool(
            """
            echo "Never sign a different account into a folder that already has chats."
            echo "Error wrong_account: Folder is logged in as another account."
            echo "Error check_failed: a line on standard error." >&2
            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: both.home) }
        let vm = ManageViewModel(
            context: fake.context, runner: CLIRunner(context: fake.context, candidates: [both.exe]),
            clock: { Self.now })
        #expect(await vm.run(.loginBrowser(label: "fol-out")) == false)
        let bar = try #require(vm.bar)
        #expect(!bar.ok && bar.command == "agent-balancer login fol-out --browser")
        #expect(bar.text == "Error wrong_account: Folder is logged in as another account.")
        // Any other failed command keeps the first line of standard error.
        let other = ManageViewModel(
            context: fake.context, runner: CLIRunner(context: fake.context, candidates: [both.exe]),
            clock: { Self.now })
        #expect(await other.run(.login(label: "tok-out")) == false)
        #expect(other.bar?.text == "Error check_failed: a line on standard error.")
    }

    @Test @MainActor func aBrowserSignInThatTimesOutSaysSoWhateverItPrintedFirst() async throws {
        let fake = try Fake()
        let slow = try Self.tool(
            """
            echo "Error check_failed: printed before the time ran out."
            exec sleep 30
            """)
        defer { try? FileManager.default.removeItem(at: slow.home) }
        let runner = CLIRunner(context: fake.context, candidates: [slow.exe])
        // What such a run leaves: a timed-out output that holds an error line.
        let output = try runner.run(["login", "fol-out", "--browser"], timeout: 1)
        #expect(output.timedOut)
        #expect(output.stdout.contains("Error check_failed: printed before the time ran out."))
        let vm = ManageViewModel(
            context: fake.context, runner: runner, clock: { Self.now }, loginTimeoutSeconds: 1)
        #expect(await vm.run(.loginBrowser(label: "fol-out")) == false)
        let bar = try #require(vm.bar)
        #expect(!bar.ok && bar.command == "agent-balancer login fol-out --browser")
        #expect(bar.text == "The command timed out.")
    }
}

import Core
import Foundation
import Testing

@testable import Core

/// The window's Remove sheet against the real tool: a remove that another remove got to first is
/// refused, the sheet closes, and the bar shows the tool's own text.
@Suite struct ManageRemoveRefusalCLITests {
    @Test @MainActor func aRemoveTheToolRefusesClosesTheSheetAndTheBarShowsWhy() async throws {
        let cli = try CLIHome()
        defer { cli.cleanup() }
        try cli.fakeFixture("logged_in")
        #expect(try cli.run(["init", "--label", "main"]).status == 0)
        #expect(try cli.run(["add", "spare", "--email", "spare@example.com"]).status == 0)
        let context = ToolContext(home: cli.home, ambient: [:])
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [cli.exe]))
        vm.windowOpened()
        vm.selection = "spare"
        vm.openRemove()
        vm.removeSheet?.typed = "spare"
        #expect(vm.removeSheet.map { vm.canConfirmRemove($0) } == true)

        // Another remove finishes first, while the window still reads the status file it read.
        let read = cli.read("state/status.json")
        let other = try cli.run(["remove", "spare"])
        #expect(other.status == 0)
        try NoFollowWriter(root: context.dataRoot).put(
            Data(read.utf8), folders: ["state"], name: "status.json")

        await vm.confirmRemove()
        let refused = try cli.run(["remove", "spare"])
        let toolText = String(decoding: refused.stderr, as: UTF8.self)
            .split(separator: "\n").first.map(String.init)
        #expect(refused.status == 1)
        #expect(vm.removeSheet == nil)
        let bar = try #require(vm.bar)
        #expect(!bar.ok)
        #expect(bar.command == "agent-balancer remove spare")
        #expect(bar.text == toolText)
        #expect(bar.text.contains("No account is labelled 'spare'."))
    }
}

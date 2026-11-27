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

    @Test @MainActor func aRemoveStopShowsItsWholeTextInTheBar() async throws {
        let cli = try CLIHome()
        defer { cli.cleanup() }
        try cli.fakeFixture("logged_in")
        #expect(try cli.run(["init", "--label", "main"]).status == 0)
        #expect(try cli.run(["add", "spare", "--kind", "token"]).status == 0)
        let context = ToolContext(home: cli.home, ambient: [:])
        _ = try TokenAccounts.install(
            context: context, label: "spare", token: Canary.realShapeToken())
        #expect(try cli.run(["run", "--print-command", "spare"]).status == 0)
        let launch = try #require(
            cli.dataEntries().first { $0.lastPathComponent.hasPrefix("l-") })
        // The remove cannot overwrite the pick's file, so it stops at its read-back.
        #expect(try changeMode(["+a", NSUserName() + " deny delete", launch.path]) == 0)
        defer { _ = try? changeMode(["-N", launch.path]) }
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [cli.exe]))
        vm.windowOpened()
        vm.selection = "spare"
        vm.openRemove()
        vm.removeSheet?.typed = "spare"

        await vm.confirmRemove()
        let stopped = try cli.run(["remove", "spare"])
        let toolText = String(decoding: stopped.stderr, as: UTF8.self)
            .split(separator: "\n").first.map(String.init)
        #expect(stopped.status == 1)
        let bar = try #require(vm.bar)
        #expect(!bar.ok)
        #expect(bar.text == toolText)
        #expect(bar.text.count > 240)
        #expect(bar.text.hasSuffix("Then run `agent-balancer remove spare` again."))
    }

    /// Runs `/bin/chmod` with `arguments` and returns its exit status.
    func changeMode(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}
